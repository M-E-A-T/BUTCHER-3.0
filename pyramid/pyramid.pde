import java.net.*;
import java.nio.*;

// Live low-band level from the audio server: /audio/lmh ,fff on UDP 9000.
final int OSC_PORT = 9000;
volatile float low = 0;           // 0..1 (scaled L/M/H from the analyzer)
volatile float mid = 0;
volatile float high = 0;
DatagramSocket oscSock;

// Contour line count follows the low band across its recent range:
// silence -> "levels at silence", the loudest recent low -> "levels at low
// peak" (both sliders in the control window, default 10 and 20). The recent
// peak decays toward the current level over "range adapt (s)" seconds.
final float PEAK_FLOOR = 0.05;    // ignore near-silence (don't blow up noise)
float lowPeak = PEAK_FLOOR;
volatile float levelsNow = 10;
// Noise contrast follows the mid band the same way: silence -> "contrast
// at silence", the loudest recent mid -> "contrast at mid peak" (0.5 / 1.5).
float midPeak = PEAK_FLOOR;
volatile float contrastNow = 1.0;
// Noise scale x and y follow the raw low value directly (not its recent
// range): low 0 -> "noise x/y at low 0" (4), low 1 -> "noise x/y at low 1" (0).
volatile float noiseXNow = 4.0;
volatile float noiseYNow = 4.0;
int lastPrint = 0;

PShader binning;
PShader shader2;
PShader topo;
PImage img;
PGraphics pg;
// The noise buffer is EDGE px bigger than the screen on every side and drawn
// offset so the margin is off-screen. topo.glsl samples neighbours (contour
// ring + misregister shift, up to ~7 px); without the margin those samples
// fall off the texture at the edges and smear into horizontal streaks.
final int EDGE = 16;


// Show laptops (runPyramid.yml sets PYRAMID_NO_CONTROLS): full screen at the
// display's native size, no border. On the Mac: a 1280x720 window next to the
// slider window.
// Span: one picture across a wall of screens, SPAN_COLS wide × SPAN_ROWS
// high. This screen sits SPAN_X screen widths from the left (fractions allowed:
// 0.5 = centred over the gap between two screens below, as in the stacked
// pyramid) in row SPAN_ROW (0 = bottom). Each laptop renders its own slice
// of one big virtual canvas; the
// noise, the topo dots and the FFT cloud are all laid out on that canvas,
// and animation runs off the synced wall clock, so the slices line up.
// SPAN_GAP_X / SPAN_GAP_Y (px, default 0) leave out the strip hidden behind
// the bezels between screens, so lines run straight across the gaps.
// Unset = a single screen.
int spanCols = 1, spanRows = 1, spanRow = 0, spanGapX = 0, spanGapY = 0;
float spanX = 0;
int spanWidth() { return spanCols * width + (spanCols - 1) * spanGapX; }      // whole canvas
int spanHeight() { return spanRows * height + (spanRows - 1) * spanGapY; }
int spanOffsetX() { return Math.round(spanX * (width + spanGapX)); }          // slice left, from canvas left
int spanOffsetTop() { return (spanRows - 1 - spanRow) * (height + spanGapY); } // slice top, from canvas top
int spanOffsetBottom() { return spanRow * (height + spanGapY); }              // slice bottom, from canvas bottom

int envInt(String name, int def) {
  String v = System.getenv(name);
  if (v == null) return def;
  try { return Integer.parseInt(v.trim()); } catch (Exception e) { println("span: bad " + name); return def; }
}

void readSpan() {
  spanCols = Math.max(1, envInt("SPAN_COLS", 1));
  spanRows = Math.max(1, envInt("SPAN_ROWS", 1));
  try {
    String x = System.getenv("SPAN_X");
    if (x != null) spanX = constrain(Float.parseFloat(x.trim()), 0, spanCols - 1);
  } catch (Exception e) { println("span: bad SPAN_X"); }
  spanRow = constrain(envInt("SPAN_ROW", 0), 0, spanRows - 1);
  spanGapX = Math.max(0, envInt("SPAN_GAP_X", 0));
  spanGapY = Math.max(0, envInt("SPAN_GAP_Y", 0));
  if (spanCols * spanRows > 1)
    println("span: x " + spanX + " of " + spanCols + " wide, row " + (spanRow + 1) + "/" + spanRows
      + " (from bottom), gaps " + spanGapX + "x" + spanGapY + " px");
}

boolean showMode() {
  return System.getenv("PYRAMID_NO_CONTROLS") != null;
}

void settings() {
  if (showMode()) fullScreen(P2D);
  else size(1280, 720, P2D);
  pixelDensity(1);
}

void setup() {
  readSpan();
  defineParams();   // controls.pde
  loadParams();
  //img = loadImage("2.png");
  //shader2 = loadShader("skysetshader.glsl.txt");
  binning = loadShader("waterNoisepluswhite.glsl");



  topo  = loadShader("topo.glsl");

  // Colours
  setColor(topo, "paperColor", color(0.968*255, 0.498*255, 0.0*255));  // lavender
  setColor(topo, "accentColor", color(0.988*255, 0.749*255, 0.286*255));    // red
  setColor(topo, "shadowColor", color(0.945*255, 0.356*255, 0.709*255));   // yellow
  setColor(topo, "inkColor", color(0.756*255, 0.070*255, 0.121*255));     // near black

  // Fixed settings. Everything else (contour, fill, noise) comes from the
  // sliders in the control window: see defineParams() in controls.pde.
  topo.set("lineWidth", 1.0);      // pixels


  pg = createGraphics(width + 2 * EDGE, height + 2 * EDGE, P2D);   // screen + margin

  cloud = new FftCloud();   // cloud.pde: FFT cloud drawn over the pyramid
  startOscListener();
  // Slider window (controls.pde). Skipped on the show laptops, where
  // runPyramid.yml sets PYRAMID_NO_CONTROLS; they use the saved params.json.
  if (showMode()) noCursor();   // hide the mouse pointer on the show screens
  else openControls();
}



void draw() {



  // Audio -> parameters: low band -> contour levels + noise scale x/y,
  // mid band -> contrast.
  float l = max(0, low);
  float k = 1.0 - exp(-1.0 / (frameRate * P("peakDecay")));
  lowPeak = max(PEAK_FLOOR, l > lowPeak ? l : lowPeak + (l - lowPeak) * k);
  levelsNow = lerp(P("levelsMin"), P("levelsMax"), constrain(l / lowPeak, 0, 1));
  topo.set("levels", levelsNow);
  float m = max(0, mid);
  midPeak = max(PEAK_FLOOR, m > midPeak ? m : midPeak + (m - midPeak) * k);
  contrastNow = lerp(P("contrastMin"), P("contrastMax"), constrain(m / midPeak, 0, 1));
  noiseXNow = lerp(P("noiseXLow0"), P("noiseXLow1"), constrain(l, 0, 1));
  noiseYNow = lerp(P("noiseYLow0"), P("noiseYLow1"), constrain(l, 0, 1));
  if (millis() - lastPrint > 1000) {
    lastPrint = millis();
    println(String.format("fps %.1f  low %.3f  peak %.3f  levels %.1f  noiseX %.2f  noiseY %.2f   mid %.3f  peak %.3f  contrast %.2f",
      frameRate, low, lowPeak, levelsNow, noiseXNow, noiseYNow, mid, midPeak, contrastNow));
  }

  binning.set("time", syncedSeconds());   // shared clock: same frame on every screen
  // Noise is laid out on the whole span canvas (+ margin); this slice's
  // pixels sit at its offset into it (gl_FragCoord y runs bottom-up).
  binning.set("resolution", (float)(spanWidth() + 2 * EDGE), (float)(spanHeight() + 2 * EDGE));
  binning.set("fragOffset", (float)spanOffsetX(), (float)spanOffsetBottom());
  topo.set("fragOffset", (float)spanOffsetX(), (float)spanOffsetBottom());
  applyParams();     // slider values -> shaders (controls.pde)
  //image(img, 0, 0);


  pg.beginDraw();
  pg.shader(binning);
  pg.rect(0, 0, pg.width, pg.height);
  pg.endDraw();





  // No background clear: the noise buffer is bigger than the screen and
  // covers every pixel, so a full-screen fill would only cost GPU time.
  shader(topo);

  image(pg, -EDGE, -EDGE);   // margin hangs off-screen
  resetShader();

  cloud.draw();   // FFT cloud on top (cloud.pde)
}

void setColor(PShader s, String name, color c) {
  s.set(name, red(c)/255.0, green(c)/255.0 , blue(c)/255.0);
}

// Background thread: read /audio/lmh packets and keep the low value.
// Packet layout: "/audio/lmh\0\0" (12 B) ",fff\0\0\0\0" (8 B) low mid high (big-endian f32).
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(OSC_PORT));
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + OSC_PORT + " (" + e.getMessage() + "); levels stay at the silence value");
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[65536];  // fits any OSC packet, incl. large /audio/fft
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!oscSock.isClosed()) {
        try {
          pkt.setLength(buf.length);  // receive() shrinks it to the last packet's size
          oscSock.receive(pkt);
          if (pkt.getLength() >= 32 && new String(buf, 0, 10, "US-ASCII").equals("/audio/lmh")) {
            ByteBuffer bb = ByteBuffer.wrap(buf, 20, 12);
            low = bb.getFloat();
            mid = bb.getFloat();
            high = bb.getFloat();
          } else {
            parseFftOsc(buf, pkt.getLength());   // /audio/fft, /audio/meta (cloud.pde)
          }
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("OSC: listening for /audio/lmh on UDP " + OSC_PORT);
}

void dispose() {
  if (oscSock != null) oscSock.close();
}

// Animation time from the wall clock instead of millis() (which counts from
// when this copy of the sketch started). The laptops' clocks are synced to the
// Mac by chrony (ansible/clockSync.yml), so every screen computes the same
// noise frame at the same moment. Wrapped every 6 hours to keep float
// precision in the shader (~2 ms steps); all screens wrap together at
// 00/06/12/18:00 UTC, which shows as one simultaneous jump in the pattern.
final long SYNC_WRAP_MS = 6L * 60 * 60 * 1000;

float syncedSeconds() {
  return (float) ((System.currentTimeMillis() % SYNC_WRAP_MS) / 1000.0);
}
