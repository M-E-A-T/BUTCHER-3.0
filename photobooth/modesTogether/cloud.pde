// FFT cloud overlay: the web UI's 3D FFT view in its "cloud" style
// (realtime/ui/src/viz/fft_3d.js + fft3d_styles/cloud.js), drawn on top of
// the pyramid every frame (see draw() in pyramid.pde).
//
// Data: /audio/fft (n bins, 0..1, log-spaced from 30 Hz to sr/2) and
// /audio/meta (sample rate + band edges) on UDP 9000, received by pyramid's
// OSC thread and handed to parseFftOsc() below. Everything is generated
// here from those numbers: same smoothing as the browser, rows placed by
// arrival time, raw OpenGL for the ~150k points a frame. No background, no
// text: the pyramid shows through.

import processing.opengl.*;
import java.util.concurrent.ConcurrentLinkedQueue;

class FftFrame {
  final double t;
  final float[] bins;
  FftFrame(double t, float[] bins) { this.t = t; this.bins = bins; }
}

final ConcurrentLinkedQueue<FftFrame> fftQueue = new ConcurrentLinkedQueue<FftFrame>();
volatile int metaSr = 48000;
// low lo/hi, mid lo/hi, high lo/hi (Hz): realtime/configs/main.yaml until /audio/meta arrives
volatile float[] metaBands = { 88, 184, 304, 1760, 2944, 13952 };
FftCloud cloud;

// Wall-clock milliseconds (Unix epoch, sub-ms). The laptops' clocks are synced
// by chrony, so rows built from this line up across spanned screens.
// NB: no decimal literals here. Processing rewrites them as floats (1000.0 →
// 1000.0f), and float math rounds an epoch time to ~2-minute steps: every FFT
// frame then lands in the same row and the history never scrolls.
static double nowMs() {
  java.time.Instant t = java.time.Instant.now();
  long micros = (t.getNano() / 1000) % 1000;   // sub-millisecond part, µs
  return (double) t.toEpochMilli() + micros / (double) 1000;
}

/** Called from the OSC thread with any packet that isn't /audio/lmh. */
void parseFftOsc(byte[] buf, int len) {
  if (len < 16) return;
  String addr = new String(buf, 0, 11, java.nio.charset.StandardCharsets.US_ASCII);
  if (addr.startsWith("/audio/fft") && buf[10] == 0) {
    int n = 0;
    while (13 + n < len && buf[13 + n] == 'f') n++;
    int p = 12 + 4 * ((n + 1) / 4 + 1);
    if (n == 0 || p + 4 * n > len) return;
    float[] bins = new float[n];
    ByteBuffer bb = ByteBuffer.wrap(buf, p, 4 * n);
    for (int i = 0; i < n; i++) bins[i] = bb.getFloat();
    fftQueue.add(new FftFrame(nowMs(), bins));
    while (fftQueue.size() > 64) fftQueue.poll();   // draw thread stalled: keep it bounded
  } else if (addr.equals("/audio/meta") && len >= 60) {
    ByteBuffer bb = ByteBuffer.wrap(buf, 24, 36);
    int sr = bb.getInt();
    bb.getInt();   // blocksize
    bb.getInt();   // n_bins
    float[] b = new float[6];
    for (int i = 0; i < 6; i++) b[i] = bb.getFloat();
    if (sr > 0) metaSr = sr;
    metaBands = b;
  }
}

class FftCloud {
  // ---- core (fft_3d.js) ----
  int maxRows = 96;                          // history rows across the full depth (one per ~52 ms slot)
  static final int RING_ROWS = 256;
  static final int MAX_COLS = 480;
  static final int T_SUB = 2;               // mesh rows per history row
  static final int MESH_COLS_MIN = 256, MESH_COLS_MAX = 384;
  static final float FREQ_SMOOTH_OCT = 0.08f, FREQ_RES_SIGMA = 0.6f, FREQ_SMOOTH_MAX_OCT = 0.35f;
  static final int TIME_PASSES = 2;
  static final float BACK_SCALE = 0.3f, AMP_FRONT = 0.4f;
  // Stacked-pyramid span (more than one row): the cloud is fitted inside the
  // pyramid's outline instead. Each level up is one screen (+ bezel gap)
  // narrower, half on each side, and one screen (+ gap) higher, so a row may
  // lose at most that much width per height it rises; PYR_NARROW adds a
  // margin on top. The front peaks are PYR_AMP screen heights tall, and the
  // PYR_HISTORY_S of history recedes up the levels and ends (faded out)
  // PYR_END_UP of the way up the top screen.
  static final float PYR_NARROW = 1.05f, PYR_AMP = 0.8f, PYR_END_UP = 0.5f, PYR_HISTORY_S = 10;
  float backScale = BACK_SCALE;   // width of the oldest row vs the front one
  static final float WORLD_HEIGHT = 0.5f, WORLD_DEPTH = 3.0f;
  float historyS = 5;                        // depth of the history (s); web UI default 5
  static final float F_MIN = 30;             // fft.f_min
  static final int WINDOW = 1024;            // fft.window_size
  static final int PAD_X = 10, PAD_T = 4, PAD_B = 0;   // PAD_B 0: front edge sits on the bottom of the screen
  static final int MAX_MESH_ROWS = (RING_ROWS - 1) * T_SUB + 1;

  // Left-edge taper (not in the web UI): the low end is still loud at 30 Hz,
  // so the sheet would stop on a cliff. Fade heights to 0 over this fraction
  // of the width (half-cosine) so the left side drops off like the right.
  static final float TAPER_LEFT = 0.08f;

  // ---- cloud style (cloud.js) ----
  static final float POINT_JITTER = 1.0f;
  static final int POINT_COPIES = 2;
  static final float RIM_PX = 1.3f;

  // classic palette
  final int BG = 0xff0a0b0d;   // fog colour
  final int[] BAND_RGB = { 0x5a8dee, 0x79d17a, 0xe8a857 };

  // ---- history ring ----
  int n = 0, cols = 0;
  float[] ring;
  final double[] rowT = new double[RING_ROWS];
  final double[] rowSeq = new double[RING_ROWS];
  double seqN = 0, rowStartT = Double.NEGATIVE_INFINITY;
  int head = -1, count = 0;
  int[] colOf;
  int meshCols = 0;
  float[] sRing, fillBuf, blurBuf;
  int[] kLo, kLen, kOff;
  float[] kW;
  String kernelKey = "";
  int[] upI;
  float[] upT;
  float[] taper;

  // ---- mesh ----
  final float[] meshH = new float[MAX_MESH_ROWS * MESH_COLS_MAX];
  final double[] meshZ = new double[MAX_MESH_ROWS];
  final double[] meshSeq = new double[MAX_MESH_ROWS];
  final int[] rowKey = new int[MAX_MESH_ROWS];
  final int[] dIdx = new int[RING_ROWS];
  final double[] dZ = new double[RING_ROWS];
  final double[] dSeq = new double[RING_ROWS];
  final float[] tA = new float[RING_ROWS * MESH_COLS_MAX];
  final float[] tB = new float[RING_ROWS * MESH_COLS_MAX];
  final float[] edgeX = new float[MESH_COLS_MAX], edgeY = new float[MESH_COLS_MAX];
  final float[] surfArr = new float[MAX_MESH_ROWS * MESH_COLS_MAX * 5];             // h z sx sz key
  final float[] stripArr = new float[4 * MESH_COLS_MAX * 4];                         // x y u v
  final float[] stopPos = new float[3];

  // ---- GL ----
  boolean glReady = false, glFailed = false;
  int surfProg, pointProg, flatProg;
  int surfVbo, stripVbo, ibo;
  int iboCols = 0;
  FloatBuffer surfBuf, stripBuf;
  IntBuffer idxBuf;

  void reset() { head = -1; count = 0; rowStartT = Double.NEGATIVE_INFINITY; finalMc = 0; }

  void configure(int nBins) {
    n = nBins;
    cols = Math.min(n, MAX_COLS);
    ring = new float[RING_ROWS * cols];
    colOf = new int[n];
    for (int i = 0; i < n; i++) colOf[i] = Math.min(cols - 1, (int) Math.floor((double) i * cols / n));
    meshCols = Math.max(MESH_COLS_MIN, Math.min(MESH_COLS_MAX, 2 * cols));
    sRing = new float[RING_ROWS * meshCols];
    fillBuf = new float[cols];
    blurBuf = new float[cols];
    kernelKey = "";
    upI = new int[meshCols];
    upT = new float[meshCols];
    taper = new float[meshCols];
    for (int m = 0; m < meshCols; m++) {
      float u = (float) m / (meshCols - 1);
      taper[m] = u >= TAPER_LEFT ? 1 : 0.5f - 0.5f * (float) Math.cos(Math.PI * u / TAPER_LEFT);
    }
    for (int m = 0; m < meshCols; m++) {
      float p = ((float) m / (meshCols - 1)) * cols - 0.5f;
      p = p < 0 ? 0 : p > cols - 1 ? cols - 1 : p;
      int i = Math.min(cols - 2, (int) Math.floor(p));
      upI[m] = Math.max(0, i);
      upT[m] = cols > 1 ? p - upI[m] : 0;
    }
    reset();
  }

  /** Per-column Gaussian across frequency, width following the FFT's real resolution. */
  void buildFreqKernel(double fMin, double fMax, double sr, double win, double smoothOct) {
    double octs = Math.max(1e-6, Math.log(fMax / fMin) / Math.log(2));
    double colsPerOct = cols / octs;
    double binHz = sr / win;
    double widthFrac = Math.pow(2, 1 / colsPerOct) - 1;
    kLo = new int[cols]; kLen = new int[cols]; kOff = new int[cols];
    double[] sig = new double[cols];
    int total = 0;
    for (int c = 0; c < cols; c++) {
      double f = fMin * Math.pow(2, ((c + 0.5) / cols) * octs);
      double rfftPerCol = (f * widthFrac) / binHz;
      double s = Math.max(smoothOct * colsPerOct, FREQ_RES_SIGMA / Math.max(1e-6, rfftPerCol));
      s = Math.min(s, FREQ_SMOOTH_MAX_OCT * colsPerOct);
      sig[c] = s;
      int r = (int) Math.ceil(3 * s);
      kLo[c] = Math.max(0, c - r);
      kLen[c] = Math.min(cols - 1, c + r) - kLo[c] + 1;
      kOff[c] = total;
      total += kLen[c];
    }
    kW = new float[total];
    for (int c = 0; c < cols; c++) {
      double sum = 0;
      for (int k = 0; k < kLen[c]; k++) {
        double d = kLo[c] + k - c;
        float w = (float) Math.exp(-(d * d) / (2 * sig[c] * sig[c]));
        kW[kOff[c] + k] = w;
        sum += w;
      }
      for (int k = 0; k < kLen[c]; k++) kW[kOff[c] + k] /= sum;
    }
  }

  /** Rebuild the smoothed copy of one ring row: fill gaps → blur → Catmull-Rom upsample. */
  void smoothRow(int idx) {
    int base = idx * cols;
    int prev = -1;
    for (int c = 0; c < cols; c++) {
      float v = ring[base + c];
      if (v != v) continue;
      if (prev < 0) java.util.Arrays.fill(fillBuf, 0, c, v);
      else if (c - prev > 1) {
        float pv = fillBuf[prev];
        for (int k = prev + 1; k < c; k++) fillBuf[k] = pv + ((v - pv) * (k - prev)) / (c - prev);
      }
      fillBuf[c] = v;
      prev = c;
    }
    if (prev < 0) java.util.Arrays.fill(fillBuf, 0);
    else java.util.Arrays.fill(fillBuf, prev + 1, cols, fillBuf[prev]);
    for (int c = 0; c < cols; c++) {
      float acc = 0;
      int o = kOff[c], l = kLo[c];
      for (int k = 0; k < kLen[c]; k++) acc += kW[o + k] * fillBuf[l + k];
      blurBuf[c] = acc;
    }
    int last = cols - 1, out = idx * meshCols;
    for (int m = 0; m < meshCols; m++) {
      int i = upI[m];
      float t = upT[m];
      float p1 = blurBuf[i];
      float p0 = blurBuf[i > 0 ? i - 1 : 0];
      float p2 = blurBuf[i + 1 <= last ? i + 1 : last];
      float p3 = blurBuf[i + 2 <= last ? i + 2 : last];
      float v = p1 + 0.5f * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
      sRing[out + m] = v < 0 ? 0 : v * taper[m];
    }
  }

  void syncSmoothing(int sr) {
    if (ring == null) return;
    String key = F_MIN + "|" + sr + "|" + WINDOW;
    if (key.equals(kernelKey)) return;
    buildFreqKernel(F_MIN, sr / 2.0, sr, WINDOW, FREQ_SMOOTH_OCT);
    kernelKey = key;
    for (int k = 0; k < count; k++) smoothRow((head - k + RING_ROWS) % RING_ROWS);
    finalMc = 0;   // carried mesh rows are stale
  }

  /**
   * Record one FFT frame. Rows are fixed wall-clock slots (depth / maxRows
   * long, numbered from the Unix epoch); frames in the same slot merge by
   * element-wise max. Every screen derives the same rows and row numbers
   * (which key the dust jitter) from the synced clock, so spanned screens
   * match at their seams.
   */
  void push(float[] bins, double t) {
    if (bins.length != n) configure(bins.length);
    syncSmoothing(metaSr);
    double slotMs = (historyS * 1000.0) / maxRows;
    double slot = Math.floor(t / slotMs);
    boolean open = count > 0 && slot == rowSeq[head];
    if (!open) {
      if (count > 0 && slot < rowSeq[head]) return;   // late frame for a closed row (clock step): drop
      head = (head + 1) % RING_ROWS;
      if (count < RING_ROWS) count++;
      rowStartT = slot * slotMs;
      rowT[head] = (slot + 1) * slotMs;   // when the slot closes
      rowSeq[head] = slot;
      java.util.Arrays.fill(ring, head * cols, head * cols + cols, Float.NaN);
    }
    int base = head * cols;
    for (int i = 0; i < n; i++) {
      float v = bins[i];
      if (v < -500) continue;                     // raw-dB empty-bin sentinel
      v = v < 0 ? 0 : v > 1 ? 1 : v;
      int j = base + colOf[i];
      float cur = ring[j];
      if (!(cur >= v)) ring[j] = v;               // NaN-aware max
    }
    smoothRow(head);
  }

  /** Peak-preserving [¼ ½ ¼] blur across history rows lo..hi. */
  float[] blurTime(int N, int lo, int hi) {
    int mc = meshCols;
    int a = Math.max(0, lo - TIME_PASSES), b = Math.min(N - 1, hi + TIME_PASSES);
    for (int i = a; i <= b; i++) System.arraycopy(sRing, dIdx[i] * mc, tA, i * mc, mc);
    float[] src = tA, dst = tB;
    for (int pass = 0; pass < TIME_PASSES; pass++) {
      int grow = TIME_PASSES - 1 - pass;
      int pa = Math.max(0, lo - grow), pb = Math.min(N - 1, hi + grow);
      for (int i = pa; i <= pb; i++) {
        int o = i * mc, op = (i > 0 ? i - 1 : 0) * mc, on = (i < N - 1 ? i + 1 : N - 1) * mc;
        for (int m = 0; m < mc; m++) {
          float v = src[o + m];
          float bl = 0.5f * v + 0.25f * (src[op + m] + src[on + m]);
          dst[o + m] = bl > v ? bl : v;
        }
      }
      float[] tmp = src; src = dst; dst = tmp;
    }
    return src;
  }

  /** Mesh heights for rows ra..rb: Catmull-Rom across the time-blurred history rows. */
  void buildHeights(int N, int ra, int rb) {
    int mc = meshCols;
    int iA = Math.min(N - 2, ra / T_SUB), iB = Math.min(N - 2, rb / T_SUB);
    float[] rows = blurTime(N, Math.max(0, iA - 1), Math.min(N - 1, iB + 2));
    for (int r = ra; r <= rb; r++) {
      int i = Math.min(N - 2, r / T_SUB);
      float t = (float) r / T_SUB - i;
      int i0 = i > 0 ? i - 1 : 0, i2 = i + 1, i3 = i + 2 < N ? i + 2 : N - 1;
      float t2 = t * t, t3 = t2 * t;
      float w0 = 0.5f * (-t3 + 2 * t2 - t);
      float w1 = 0.5f * (3 * t3 - 5 * t2 + 2);
      float w2 = 0.5f * (-3 * t3 + 4 * t2 + t);
      float w3 = 0.5f * (t3 - t2);
      int a0 = i0 * mc, a1 = i * mc, a2 = i2 * mc, a3 = i3 * mc, o = r * mc;
      for (int m = 0; m < mc; m++) {
        float v = w0 * rows[a0 + m] + w1 * rows[a1 + m] + w2 * rows[a2 + m] + w3 * rows[a3 + m];
        meshH[o + m] = v < 0 ? 0 : v > 1.25f ? 1.25f : v;
      }
    }
  }

  void buildRowTimes(int N, int R) {
    for (int r = 0; r < R; r++) {
      int i = Math.min(N - 2, r / T_SUB);
      double t = (double) r / T_SUB - i;
      meshZ[r] = dZ[i] + (dZ[i + 1] - dZ[i]) * t;
      meshSeq[r] = dSeq[i] + (dSeq[i + 1] - dSeq[i]) * t;
      rowKey[r] = (int) (Math.round(meshSeq[r] * T_SUB) % 65536);
    }
  }

  /**
   * Mesh vertices (h, z, slope x, slope z, row key). u comes from the vertex
   * index in the shaders, and the dust points are derived on the GPU from
   * these same vertices (hash of column, row key and copy), like the web UI.
   */
  void fillVertices(int R, int ra, int rb) {
    int mc = meshCols;
    float sxScale = WORLD_HEIGHT / (2 * (2f / (mc - 1)));
    int o = ra * mc * VERT_FLOATS;
    for (int r = ra; r <= rb; r++) {
      int rp = r > 0 ? r - 1 : 0, rn = r < R - 1 ? r + 1 : R - 1;
      float z = (float) meshZ[r];
      double dZw = (meshZ[rp] - meshZ[rn]) * WORLD_DEPTH;
      float invDz = dZw > 1e-6 ? (float) (WORLD_HEIGHT / dZw) : 0;
      int key = rowKey[r];
      int row = r * mc, rowP = rp * mc, rowN = rn * mc;
      for (int m = 0; m < mc; m++) {
        int ml = m > 0 ? m - 1 : 0, mr = m < mc - 1 ? m + 1 : mc - 1;
        surfArr[o++] = meshH[row + m];
        surfArr[o++] = z;
        surfArr[o++] = (meshH[row + mr] - meshH[row + ml]) * (mr - ml == 2 ? sxScale : 2 * sxScale);
        surfArr[o++] = (meshH[rowP + m] - meshH[rowN + m]) * invDz;
        surfArr[o++] = key;
      }
    }
  }

  // Incremental mesh (fft_3d.js buildMesh). The history rows in view are a
  // contiguous run of row numbers, so last frame's mesh maps onto this
  // frame's by a shift of whole rows. A mesh row depends on the history rows
  // from reachBack before to reachFwd after its own (time blur ±passes,
  // Catmull-Rom −1..+2, slopes ±1 mesh row). Once all of those are closed
  // and none is clamped at the back edge, its heights and slopes are final:
  // they are carried over (shifted) and only z is rewritten. Per frame that
  // leaves a few rows at the live front edge and at the horizon to
  // recompute instead of the whole ~190 × 384 mesh.
  static final int VERT_FLOATS = 5;   // h, z, slope x, slope z, row key
  double finalSeq0 = Double.NaN, finalDepth = Double.NaN;
  int finalLo = 0, finalHi = -1, finalMc = 0;

  /** Build meshH / meshZ / vertices from the N (≥ 2) history rows in view. Returns the mesh row count. */
  int buildMesh(int N, boolean headOpen, double depthMs) {
    int mc = meshCols;
    int R = (N - 1) * T_SUB + 1;
    buildRowTimes(N, R);
    // History rows final this frame: back neighbours in view, forward neighbours closed.
    int lastClosed = headOpen ? N - 2 : N - 1;
    int nowLo = TIME_PASSES + 2, nowHi = lastClosed - (TIME_PASSES + 3);
    int lo = 1, hi = 0;
    double shiftD = dSeq[0] - finalSeq0;
    // Carry-over needs consecutive row numbers (a slot with no packets leaves a gap).
    boolean contiguous = dSeq[N - 1] - dSeq[0] == N - 1;
    if (contiguous && mc == finalMc && depthMs == finalDepth && shiftD >= 0) {
      int shift = (int) shiftD;
      lo = Math.max(nowLo, finalLo - shift);
      hi = Math.min(nowHi, finalHi - shift);
    }
    if (lo <= hi) {
      int shift = (int) shiftD;
      int ra = lo * T_SUB, rb = hi * T_SUB + T_SUB - 1;   // carried mesh rows
      int dr = shift * T_SUB;
      if (dr > 0) {
        System.arraycopy(meshH, (ra + dr) * mc, meshH, ra * mc, (rb - ra + 1) * mc);
        System.arraycopy(surfArr, (ra + dr) * mc * VERT_FLOATS, surfArr, ra * mc * VERT_FLOATS, (rb - ra + 1) * mc * VERT_FLOATS);
      }
      // Recompute both sides; heights one row past each side feed the slopes.
      if (ra > 0) { buildHeights(N, 0, ra); fillVertices(R, 0, ra - 1); }
      if (rb < R - 1) { buildHeights(N, rb, R - 1); fillVertices(R, rb + 1, R - 1); }
      // Carried rows: new depth only.
      for (int r = ra, o = ra * mc * VERT_FLOATS + 1; r <= rb; r++) {
        float z = (float) meshZ[r];
        for (int m = 0; m < mc; m++, o += VERT_FLOATS) surfArr[o] = z;
      }
    } else {
      buildHeights(N, 0, R - 1);
      fillVertices(R, 0, R - 1);
    }
    finalSeq0 = dSeq[0]; finalLo = nowLo; finalHi = nowHi;
    finalMc = mc; finalDepth = depthMs;
    return R;
  }

  // ---------------------------------------------------------------- draw

  void draw() {
    if (spanRows > 1 && historyS != PYR_HISTORY_S) {
      // Stacked pyramid: deeper history, same row length (~52 ms).
      maxRows = Math.round(maxRows * PYR_HISTORY_S / historyS);
      historyS = PYR_HISTORY_S;
      reset();
    }
    FftFrame fr;
    while ((fr = fftQueue.poll()) != null) push(fr.bins, fr.t);

    int W = width, H = height;
    int sr = metaSr;
    syncSmoothing(sr);
    double fMin = F_MIN, fMax = sr / 2.0;
    double depthMs = historyS * 1000.0;

    if (count == 0 || glFailed) return;   // no data yet (or GL failed: see console)

    // Geometry (fft_3d.js geometry()).
    // Laid out on the whole span canvas (just this screen when not spanning),
    // then shifted so this screen shows its slice: everything below is
    // positioned from cx, y0 and yBack.
    float plotX = PAD_X, plotW = Math.max(1, spanWidth() - 2 * PAD_X);
    float y0 = spanHeight() - PAD_B;
    float ampFront, yBack;
    if (spanRows > 1) {
      // Pyramid fit: the row width shrinks linearly with height (perspective),
      // by PYR_NARROW screen widths per screen height, so both ends of every
      // row are already on the next level up when the row reaches it.
      // Width lost per pixel of rise: one level step, with margin.
      float narrowPerPx = PYR_NARROW * (width + spanGapX) / (float) (height + spanGapY);
      // The far end of the history: PYR_END_UP of the way up the top screen.
      float rise = (spanRows - 1) * (height + spanGapY) + PYR_END_UP * height;
      backScale = Math.max(0.02f, 1 - rise * narrowPerPx / plotW);
      yBack = y0 - rise;
      ampFront = PYR_AMP * height;
    } else {
      backScale = BACK_SCALE;
      float plotH = Math.max(1, y0 - PAD_T);
      ampFront = AMP_FRONT * plotH;
      yBack = PAD_T + ampFront * backScale + 6;
    }
    float cx = plotX + plotW / 2 - spanOffsetX();
    y0 -= spanOffsetTop();
    yBack -= spanOffsetTop();


    // History rows in the depth window, oldest first.
    double now = nowMs();
    int N = 0;
    for (int k = count - 1; k >= 0; k--) {
      int idx = (head - k + RING_ROWS) % RING_ROWS;
      double z = (now - rowT[idx]) / depthMs;
      if (z > 1) continue;
      dIdx[N] = idx; dZ[N] = z < 0 ? 0 : z; dSeq[N] = rowSeq[idx]; N++;
    }
    if (N == 0) return;
    // Pin the newest row to the front so the waveform always sits on the
    // bottom edge. Between FFT frames its slot closes and its depth creeps
    // above 0 until the next frame opens a new row, which made the bottom
    // jump up and snap back.
    dZ[N - 1] = 0;

    // Band colour stops at each band's geometric centre.
    double logFmin = Math.log10(fMin), logSpan = Math.max(1e-6, Math.log10(fMax) - logFmin);
    float[] b = metaBands;
    for (int k = 0; k < 3; k++) {
      double p = (Math.log10(Math.sqrt(b[2 * k] * b[2 * k + 1])) - logFmin) / logSpan;
      stopPos[k] = (float) (p < 0 ? 0 : p > 1 ? 1 : p);
    }

    int mc = meshCols;
    int R = 1;
    if (N >= 2) {
      R = buildMesh(N, now < rowT[head], depthMs);
    } else {
      System.arraycopy(sRing, dIdx[0] * mc, meshH, 0, mc);
      meshZ[0] = dZ[0];
    }

    // Front edge (newest mesh row) in px.
    float K = 1 / backScale - 1;
    float sF = (float) (1 / (1 + K * meshZ[R - 1]));
    float yBaseF = y0 - ((1 - sF) / (1 - backScale)) * (y0 - yBack);
    float ampF = ampFront * sF;
    int front = (R - 1) * mc;
    for (int m = 0; m < mc; m++) {
      float u = (float) m / (mc - 1);
      edgeX[m] = cx + (u - 0.5f) * plotW * sF;
      edgeY[m] = yBaseF - Math.min(1, meshH[front + m]) * ampF;
    }
    // Curtain (2·mc verts) then rim (2·mc verts).
    int o = 0;
    for (int m = 0; m < mc; m++) {
      float u = (float) m / (mc - 1), hv = Math.min(1, meshH[front + m]);
      stripArr[o++] = edgeX[m]; stripArr[o++] = edgeY[m]; stripArr[o++] = u; stripArr[o++] = hv;
      stripArr[o++] = edgeX[m]; stripArr[o++] = yBaseF;   stripArr[o++] = u; stripArr[o++] = 0;
    }
    float rimHalf = RIM_PX / 2 + 1;   // + 1 px of AA falloff
    for (int m = 0; m < mc; m++) {
      int ml = m > 0 ? m - 1 : 0, mr = m < mc - 1 ? m + 1 : mc - 1;
      float tx = edgeX[mr] - edgeX[ml], ty = edgeY[mr] - edgeY[ml];
      float len = (float) Math.hypot(tx, ty);
      float inv = rimHalf / (len > 0 ? len : 1);
      float nx = -ty * inv, ny = tx * inv;
      float u = (float) m / (mc - 1);
      stripArr[o++] = edgeX[m] + nx; stripArr[o++] = edgeY[m] + ny; stripArr[o++] = u; stripArr[o++] = 1;
      stripArr[o++] = edgeX[m] - nx; stripArr[o++] = edgeY[m] - ny; stripArr[o++] = u; stripArr[o++] = -1;
    }

    PGL pgl = beginPGL();
    try {
      if (!glReady) initGL(pgl);
      float[] geo = { W, H, cx, plotW / 2, y0, yBack, ampFront, K };
      renderGL(pgl, R, mc, geo, rimHalf, o);
    } catch (RuntimeException e) {
      glFailed = true;
      println("fftcloud: " + e.getMessage());
    } finally {
      endPGL();
    }
  }

  // ---------------------------------------------------------------- GL

  String vsHead, fsHead;

  void initGL(PGL pgl) {
    String ver = pgl.getString(PGL.SHADING_LANGUAGE_VERSION);
    // GLSL 1.50 (GL 3.2) for gl_VertexID and unsigned ints: the Mac (4.1
    // core) and the laptops (Mesa 4.5 core) both have it.
    vsHead = "#version 150\n#define IN in\n#define VOUT out\n";
    fsHead = "#version 150\n#define FIN in\nout vec4 fragColor;\n#define FRAG fragColor\n";
    println("cloud: GL " + pgl.getString(PGL.VERSION) + ", GLSL " + ver);

    String[] meshAttribs = { "aH", "aZ", "aSlope", "aKey" };
    surfProg = link(pgl, SURF_VS, SURF_FS, meshAttribs);
    pointProg = link(pgl, POINT_VS, POINT_FS, meshAttribs);
    flatProg = link(pgl, FLAT_VS, FLAT_FS, new String[] { "aPos", "aUV" });

    IntBuffer ids = IntBuffer.allocate(3);
    pgl.genBuffers(3, ids);
    surfVbo = ids.get(0); stripVbo = ids.get(1); ibo = ids.get(2);
    surfBuf = directFloats(surfArr.length);
    stripBuf = directFloats(stripArr.length);
    glReady = true;
  }

  FloatBuffer directFloats(int n) {
    return ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
  }

  int compile(PGL pgl, int type, String src) {
    int sh = pgl.createShader(type);
    pgl.shaderSource(sh, src);
    pgl.compileShader(sh);
    IntBuffer ok = IntBuffer.allocate(1);
    pgl.getShaderiv(sh, PGL.COMPILE_STATUS, ok);
    if (ok.get(0) == 0) throw new RuntimeException("shader compile failed:\n" + pgl.getShaderInfoLog(sh) + "\n" + src);
    return sh;
  }

  int link(PGL pgl, String vs, String fs, String[] attribs) {
    int prog = pgl.createProgram();
    pgl.attachShader(prog, compile(pgl, PGL.VERTEX_SHADER, vsHead + vs));
    pgl.attachShader(prog, compile(pgl, PGL.FRAGMENT_SHADER, fsHead + fs));
    for (int i = 0; i < attribs.length; i++) pgl.bindAttribLocation(prog, i, attribs[i]);
    pgl.linkProgram(prog);
    IntBuffer ok = IntBuffer.allocate(1);
    pgl.getProgramiv(prog, PGL.LINK_STATUS, ok);
    if (ok.get(0) == 0) throw new RuntimeException("program link failed:\n" + pgl.getProgramInfoLog(prog));
    return prog;
  }

  void buildIndices(PGL pgl, int mc) {
    int quads = (MAX_MESH_ROWS - 1) * (mc - 1);
    idxBuf = ByteBuffer.allocateDirect(quads * 6 * 4).order(ByteOrder.nativeOrder()).asIntBuffer();
    // Row order = oldest (far) first, so the sheet draws back to front.
    for (int r = 0; r < MAX_MESH_ROWS - 1; r++) {
      for (int m = 0; m < mc - 1; m++) {
        int a = r * mc + m, b = a + 1, c = a + mc, d = c + 1;
        idxBuf.put(a).put(c).put(b).put(b).put(c).put(d);
      }
    }
    idxBuf.rewind();
    pgl.bindBuffer(PGL.ELEMENT_ARRAY_BUFFER, ibo);
    pgl.bufferData(PGL.ELEMENT_ARRAY_BUFFER, quads * 6 * 4, idxBuf, PGL.STATIC_DRAW);
    iboCols = mc;
  }

  void common(PGL pgl, int prog, float[] geo) {
    pgl.useProgram(prog);
    pgl.uniform2f(pgl.getUniformLocation(prog, "uRes"), geo[0], geo[1]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uCx"), geo[2]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uHalfW"), geo[3]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uY0"), geo[4]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uYBack"), geo[5]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uAmp"), geo[6]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uK"), geo[7]);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uBackScale"), backScale);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uDpr"), 1);
    pgl.uniform1i(pgl.getUniformLocation(prog, "uCols"), meshCols);
    pgl.uniform1f(pgl.getUniformLocation(prog, "uRowDz"), 1f / (maxRows * T_SUB));
    pgl.uniform3f(pgl.getUniformLocation(prog, "uBg"), ((BG >> 16) & 255) / 255f, ((BG >> 8) & 255) / 255f, (BG & 255) / 255f);
    pgl.uniform3f(pgl.getUniformLocation(prog, "uStopPos"), stopPos[0], stopPos[1], stopPos[2]);
    for (int k = 0; k < 3; k++) {
      int c = BAND_RGB[k];
      pgl.uniform3f(pgl.getUniformLocation(prog, "uC" + k), ((c >> 16) & 255) / 255f, ((c >> 8) & 255) / 255f, (c & 255) / 255f);
    }
  }

  void upload(PGL pgl, int vbo, FloatBuffer fb, float[] src, int floats) {
    fb.clear();
    fb.put(src, 0, floats);
    fb.flip();
    pgl.bindBuffer(PGL.ARRAY_BUFFER, vbo);
    pgl.bufferData(PGL.ARRAY_BUFFER, floats * 4, fb, PGL.STREAM_DRAW);
  }

  void attrib(PGL pgl, int loc, int size, int strideFloats, int offFloats) {
    pgl.enableVertexAttribArray(loc);
    pgl.vertexAttribPointer(loc, size, PGL.FLOAT, false, strideFloats * 4, offFloats * 4);
  }

  void renderGL(PGL pgl, int R, int mc, float[] geo, float rimHalf, int stripFloats) {
    pgl.enable(PGL.BLEND);
    if (R >= 2) {
      if (iboCols != mc) buildIndices(pgl, mc);
      pgl.enable(PGL.DEPTH_TEST);
      pgl.depthFunc(PGL.LEQUAL);
      pgl.depthMask(true);
      pgl.clearDepth(1);
      pgl.clear(PGL.DEPTH_BUFFER_BIT);

      // Matte body, back to front, writing depth so points behind nearer swells are culled.
      upload(pgl, surfVbo, surfBuf, surfArr, R * mc * 5);
      common(pgl, surfProg, geo);
      attrib(pgl, 0, 1, 5, 0);   // aH
      attrib(pgl, 1, 1, 5, 1);   // aZ
      attrib(pgl, 2, 2, 5, 2);   // aSlope
      attrib(pgl, 3, 1, 5, 4);   // aKey
      pgl.bindBuffer(PGL.ELEMENT_ARRAY_BUFFER, ibo);
      pgl.blendFunc(PGL.ONE, PGL.ONE_MINUS_SRC_ALPHA);   // premultiplied
      pgl.drawElements(PGL.TRIANGLES, (R - 1) * (mc - 1) * 6, PGL.UNSIGNED_INT, 0);
      pgl.bindBuffer(PGL.ELEMENT_ARRAY_BUFFER, 0);

      // Dust: additive points on every mesh vertex (same vertex buffer),
      // one pass per copy; the shader jitters each copy differently.
      common(pgl, pointProg, geo);
      pgl.enable(0x8642);                                // GL_PROGRAM_POINT_SIZE
      pgl.blendFunc(PGL.ONE, PGL.ONE);
      pgl.depthMask(false);
      int copyLoc = pgl.getUniformLocation(pointProg, "uCopy");
      for (int c = 0; c < POINT_COPIES; c++) {
        pgl.uniform1i(copyLoc, c);
        pgl.drawArrays(PGL.POINTS, 0, R * mc);
      }
      pgl.depthMask(true);
      pgl.disable(PGL.DEPTH_TEST);
    }

    // Front edge: curtain down to its baseline + rim.
    for (int i = 0; i < 4; i++) pgl.disableVertexAttribArray(i);
    upload(pgl, stripVbo, stripBuf, stripArr, stripFloats);
    common(pgl, flatProg, geo);
    attrib(pgl, 0, 2, 4, 0);
    attrib(pgl, 1, 2, 4, 2);
    pgl.blendFunc(PGL.ONE, PGL.ONE_MINUS_SRC_ALPHA);
    pgl.uniform1f(pgl.getUniformLocation(flatProg, "uCore"), Math.max(0, 1 - 1 / rimHalf));
    pgl.uniform1f(pgl.getUniformLocation(flatProg, "uMode"), 0);
    pgl.drawArrays(PGL.TRIANGLE_STRIP, 0, 2 * mc);
    pgl.uniform1f(pgl.getUniformLocation(flatProg, "uMode"), 1);
    pgl.drawArrays(PGL.TRIANGLE_STRIP, 2 * mc, 2 * mc);

    // Leave the state Processing expects.
    for (int i = 0; i < 4; i++) pgl.disableVertexAttribArray(i);
    pgl.bindBuffer(PGL.ARRAY_BUFFER, 0);
    pgl.useProgram(0);
  }

  // ---------------------------------------------------------------- shaders (cloud.js / common.js)

  final String PROJ =
    "uniform vec2 uRes;\n" +
    "uniform float uCx, uHalfW, uY0, uYBack, uAmp, uDpr, uK, uBackScale;\n" +
    "float persp(float z) { return 1.0 / (1.0 + uK * z); }\n" +
    "vec2 toPx(float u, float h, float z, out float s) {\n" +
    "  s = persp(z);\n" +
    "  float yBase = uY0 - (1.0 - s) / (1.0 - uBackScale) * (uY0 - uYBack);\n" +
    "  return vec2(uCx + (u - 0.5) * 2.0 * uHalfW * s, yBase - h * uAmp * s);\n" +
    "}\n" +
    "vec4 clipPos(vec2 px, float s) {\n" +
    "  float w = 1.0 / s;\n" +
    "  return vec4((px.x / uRes.x * 2.0 - 1.0) * w, (1.0 - px.y / uRes.y * 2.0) * w, (0.9 - 1.8 * s) * w, w);\n" +
    "}\n";

  // band(u): palette L/M/H at their band centres, faded 30% toward grey.
  final String BAND =
    "uniform vec3 uStopPos;\n" +
    "uniform vec3 uC0, uC1, uC2;\n" +
    "vec3 band(float u) {\n" +
    "  vec3 c;\n" +
    "  if (u <= uStopPos.x) c = uC0;\n" +
    "  else if (u <= uStopPos.y) c = mix(uC0, uC1, (u - uStopPos.x) / max(1e-4, uStopPos.y - uStopPos.x));\n" +
    "  else if (u <= uStopPos.z) c = mix(uC1, uC2, (u - uStopPos.y) / max(1e-4, uStopPos.z - uStopPos.y));\n" +
    "  else c = uC2;\n" +
    "  return mix(c, vec3(dot(c, vec3(0.299, 0.587, 0.114))), 0.3);\n" +
    "}\n";

  final String FOG =
    "uniform vec3 uBg;\n" +
    "float fog(float z) { return smoothstep(0.2, 1.0, z) * 0.9; }\n" +
    "float fade(float z) { return 1.0 - smoothstep(0.65, 1.0, z); }\n";

  final String SURF_VS =
    "IN float aH; IN float aZ; IN vec2 aSlope;\n" +
    "uniform int uCols;\n" +
    PROJ +
    "VOUT float vU; VOUT float vH; VOUT float vZ; VOUT vec3 vN;\n" +
    "void main() {\n" +
    "  float u = float(gl_VertexID % uCols) / float(uCols - 1);\n" +
    "  float s;\n" +
    "  vec2 px = toPx(u, aH, aZ, s);\n" +
    "  gl_Position = clipPos(px, s);\n" +
    "  vU = u; vH = aH; vZ = aZ;\n" +
    "  vN = vec3(-aSlope.x, 1.0, -aSlope.y);\n" +
    "}\n";

  final String SURF_FS =
    "FIN float vU; FIN float vH; FIN float vZ; FIN vec3 vN;\n" +
    BAND + FOG +
    "void main() {\n" +
    "  vec3 base = band(vU);\n" +
    "  float h = clamp(vH, 0.0, 1.0);\n" +
    "  vec3 n = normalize(vN);\n" +
    "  float diff = 0.55 + 0.45 * max(dot(n, normalize(vec3(-0.4, 0.9, -0.35))), 0.0);\n" +
    "  vec3 col = base * (0.06 + 0.6 * smoothstep(0.0, 0.9, h)) * diff;\n" +
    "  col = mix(col, uBg, fog(vZ));\n" +
    "  float a = 0.5 * fade(vZ) * (0.5 + 0.5 * smoothstep(0.0, 0.4, h));\n" +
    "  FRAG = vec4(col * a, a);\n" +
    "}\n";

  // Points ride the mesh vertices, jittered by a stable hash keyed on
  // (column, row key, copy) so the noise travels with the data.
  final String POINT_VS =
    "IN float aH; IN float aZ; IN float aKey;\n" +
    "uniform int uCols;\n" +
    "uniform int uCopy;\n" +
    "uniform float uRowDz;\n" +
    PROJ +
    "uint hash(uint x) {\n" +
    "  x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;\n" +
    "  return x;\n" +
    "}\n" +
    "VOUT float vU; VOUT float vH; VOUT float vZ; VOUT float vRand;\n" +
    "void main() {\n" +
    "  int col = gl_VertexID % uCols;\n" +
    "  float u = float(col) / float(uCols - 1);\n" +
    "  uint k = hash(uint(col) * 0x9E3779B1u ^ hash(uint(aKey) * 4u + uint(uCopy) + 0x632BE5ABu));\n" +
    "  float r1 = float(k & 0xFFFFu) / 65535.0, r2 = float(k >> 16) / 65535.0;\n" +
    "  u += (r1 - 0.5) * 1.0 / float(uCols - 1);\n" +
    "  float zz = max(0.0, aZ + (r2 - 0.5) * 1.0 * uRowDz);\n" +
    "  vRand = float(hash(k) & 0xFFFFu) / 65535.0;\n" +
    "  float s;\n" +
    "  vec2 px = toPx(u, aH, zz, s);\n" +
    "  gl_Position = clipPos(px, s);\n" +
    "  gl_Position.z -= 0.004 * gl_Position.w;\n" +
    "  gl_PointSize = max(1.0, 1.4 * uDpr * sqrt(s));\n" +
    "  vU = u; vH = aH; vZ = zz;\n" +
    "}\n";

  final String POINT_FS =
    "FIN float vU; FIN float vH; FIN float vZ; FIN float vRand;\n" +
    BAND + FOG +
    "void main() {\n" +
    "  float h = clamp(vH, 0.0, 1.0);\n" +
    "  vec3 col = mix(band(vU), vec3(1.0), 0.3 * h);\n" +
    "  float a = 0.9 * (0.12 + 0.88 * h) * (0.25 + 0.75 * vRand) * fade(vZ) * (1.0 - fog(vZ));\n" +
    "  FRAG = vec4(col * a, a);\n" +
    "}\n";

  final String FLAT_VS =
    "IN vec2 aPos; IN vec2 aUV;\n" +
    "uniform vec2 uRes;\n" +
    "VOUT vec2 vUV;\n" +
    "void main() {\n" +
    "  vUV = aUV;\n" +
    "  gl_Position = vec4(aPos.x / uRes.x * 2.0 - 1.0, 1.0 - aPos.y / uRes.y * 2.0, 0.0, 1.0);\n" +
    "}\n";

  final String FLAT_FS =
    "FIN vec2 vUV;\n" +
    "uniform float uMode;   // 0 = curtain (v = height, 0 at baseline), 1 = rim (v = side, -1..1)\n" +
    "uniform float uCore;\n" +
    BAND +
    "void main() {\n" +
    "  vec3 base = band(vUV.x);\n" +
    "  if (uMode < 0.5) {\n" +
    "    float v = clamp(vUV.y, 0.0, 1.0);\n" +
    "    float a = 0.35 + 0.4 * v;\n" +
    "    FRAG = vec4(base * (0.04 + 0.25 * v * v) * a, a);\n" +
    "  } else {\n" +
    "    float a = 0.8 * (1.0 - smoothstep(uCore, 1.0, abs(vUV.y)));\n" +
    "    FRAG = vec4(mix(base, vec3(1.0), 0.15) * a, a);\n" +
    "  }\n" +
    "}\n";
}
