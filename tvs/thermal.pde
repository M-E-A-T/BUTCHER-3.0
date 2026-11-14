// Thermal filter: CPU port of photobooth/boothModes thermal.glsl + ThermalMode.
// Brightness (sharpened) is mapped through a cold-to-hot gradient
// (navy -> blue -> cyan -> green -> yellow -> orange -> red -> white).
// Each audio band owns a colour and makes it spread and glow when loud:
//   low -> red      mid -> blue      high -> yellow
// Each band reacts to its level relative to its own recent peak, plus a
// full-strength flash on every onset. Audio comes from onsets.pde.

float thermalGain = 1.0;   // how hard the bands drive it (0..2)

class ThermalFilter implements VisualFilter {
  // Band envelope, same constants as the photobooth.
  final float ATTACK_S = 0.01;
  final float RELEASE_S = 0.12;
  final float AVG_S = 1.5;
  final float PEAK_DECAY_S = 3;
  final float MIN_RANGE = 0.08;
  final float FLASH_DECAY_S = 0.18;

  // Gradient, same as thermal.glsl.
  final float GROW = 12.0;   // a band at 1 makes its colour's region 13x as wide
  final float GLOW = 1.0;    // and brightens it by up to 100%
  final float[][] STOPS = {
    { 0.02, 0.01, 0.20 },   // deep navy
    { 0.10, 0.05, 0.75 },   // blue
    { 0.00, 0.55, 0.95 },   // cyan
    { 0.10, 0.85, 0.35 },   // green
    { 0.95, 0.95, 0.10 },   // yellow
    { 1.00, 0.55, 0.00 },   // orange
    { 0.95, 0.10, 0.05 },   // red
    { 1.00, 0.90, 0.95 }    // white-hot
  };

  final int LUT_N = 1024;
  int[] lut = new int[LUT_N];        // t (0..1) -> colour, rebuilt every frame
  int[] contrast = new int[LUT_N];   // sharpened luma -> smoothstep(0.06, 0.95) as LUT index
  int[] luma;                        // per-pixel luma 0..255, reused between frames

  Band lowB = new Band(), midB = new Band(), highB = new Band();
  int lowSeen = lowHits, midSeen = midHits, highSeen = highHits;

  class Band {
    float env = 0, avg = 0, peak = MIN_RANGE, flash = 0, out = 0;

    float update(float target, boolean hit) {
      float fps = max(frameRate, 1);
      target = constrain(target, 0, 1);
      env += (target - env) * (1 - exp(-1.0 / (fps * (target > env ? ATTACK_S : RELEASE_S))));
      avg += (env - avg) * (1 - exp(-1.0 / (fps * AVG_S)));
      peak = env > peak ? env : peak + (avg - peak) * (1 - exp(-1.0 / (fps * PEAK_DECAY_S)));
      peak = max(peak, avg + MIN_RANGE);
      float rise = constrain((env - avg) / (peak - avg), 0, 1);
      flash = hit ? 1 : flash * exp(-1.0 / (fps * FLASH_DECAY_S));
      out = max(rise, flash) * thermalGain;
      return out;
    }
  }

  ThermalFilter() {
    for (int i = 0; i < LUT_N; i++) {
      float l = i / (float)(LUT_N - 1);
      float s = constrain((l - 0.06) / (0.95 - 0.06), 0, 1);
      contrast[i] = round(s * s * (3 - 2 * s) * (LUT_N - 1));
    }
  }

  public String getName() { return "Thermal"; }

  void buildLut(float lowAmt, float midAmt, float highAmt) {
    int n = STOPS.length;
    float[] w = new float[n];
    float[] g = new float[n];
    for (int k = 0; k < n; k++) { w[k] = 1; g[k] = 0; }
    w[1] += GROW * midAmt;  g[1] = midAmt;    // blue
    w[4] += GROW * highAmt; g[4] = highAmt;   // yellow
    w[6] += GROW * lowAmt;  g[6] = lowAmt;    // red

    float total = 0;
    for (int k = 0; k < n - 1; k++) total += 0.5 * (w[k] + w[k + 1]);

    int k = 0;
    float p = 0;
    for (int i = 0; i < LUT_N; i++) {
      float x = i / (float)(LUT_N - 1) * total;
      while (k < n - 2 && x > p + 0.5 * (w[k] + w[k + 1])) {
        p += 0.5 * (w[k] + w[k + 1]);
        k++;
      }
      float len = 0.5 * (w[k] + w[k + 1]);
      float f = constrain((x - p) / len, 0, 1);
      f = f * f * (3 - 2 * f);
      float ga = 1 + GLOW * g[k], gb = 1 + GLOW * g[k + 1];
      float r = min(1, lerp(STOPS[k][0] * ga, STOPS[k + 1][0] * gb, f));
      float gr = min(1, lerp(STOPS[k][1] * ga, STOPS[k + 1][1] * gb, f));
      float b = min(1, lerp(STOPS[k][2] * ga, STOPS[k + 1][2] * gb, f));
      lut[i] = 0xFF000000 | (int)(r * 255) << 16 | (int)(gr * 255) << 8 | (int)(b * 255);
    }
  }

  public void apply(PImage p) {
    int lh = lowHits, mh = midHits, hh = highHits;
    lowB.update(oscLow, lh != lowSeen);
    midB.update(oscMid, mh != midSeen);
    highB.update(oscHigh, hh != highSeen);
    lowSeen = lh; midSeen = mh; highSeen = hh;
    buildLut(lowB.out, midB.out, highB.out);

    int w = p.width, h = p.height;
    p.loadPixels();
    int[] px = p.pixels;
    if (luma == null || luma.length != px.length) luma = new int[px.length];
    for (int i = 0; i < px.length; i++) {
      int c = px[i];
      luma[i] = (((c >> 16) & 0xFF) * 77 + ((c >> 8) & 0xFF) * 150 + (c & 0xFF) * 29) >> 8;
    }

    float time = showTime();
    for (int y = 0; y < h; y++) {
      // Faint per-row shimmer so it isn't static, as in the shader.
      int shimmer = round(0.01 * sin(time * 3.0 + (y / (float)h) * 40.0) * (LUT_N - 1));
      int row = y * w;
      int up = (y > 0 ? y - 1 : y) * w;
      int dn = (y < h - 1 ? y + 1 : y) * w;
      for (int x = 0; x < w; x++) {
        int c = luma[row + x];
        int nb = luma[row + (x > 0 ? x - 1 : x)] + luma[row + (x < w - 1 ? x + 1 : x)]
               + luma[up + x] + luma[dn + x];
        // Unsharp mask: c + 0.8 * (c - avg of 4 neighbours), in 0..255 units.
        int s = c + ((c * 4 - nb) * 819 >> 12);
        if (s < 0) s = 0; else if (s > 255) s = 255;
        int t = contrast[(s * (LUT_N - 1)) / 255] + shimmer;
        if (t < 0) t = 0; else if (t >= LUT_N) t = LUT_N - 1;
        px[row + x] = lut[t];
      }
    }
    p.updatePixels();
  }
}
