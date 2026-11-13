// ---------- Mode: thermal ----------
// A heat-camera look for the webcam, in the spirit of Photo Booth's
// "Thermal Camera" effect. Brightness is mapped through a cold-to-hot
// gradient (navy -> blue -> cyan -> green -> yellow -> orange -> red -> white).
//
// Each band owns a colour of the gradient and makes it spread and glow when loud:
//   low -> red      mid -> blue      high -> yellow
// Each band reacts to its level relative to its own recent peak, plus a
// full-strength flash on every onset.
//
// Keys:  up/down  how hard the bands drive it (0..2)

class ThermalMode {
  // Per band, two signals are combined into what the shader sees:
  //  - rise: how far the band is above its own running average, as a fraction
  //    of the gap between that average and the recent peak. Steady music sits
  //    near 0 (plain thermal image); only pushes above the usual level light up.
  //  - flash: jumps to 1 on every onset (kick / snare / hat) and decays fast.
  final float ATTACK_S = 0.01;
  final float RELEASE_S = 0.12;
  final float AVG_S = 1.5;         // running average time constant
  final float PEAK_DECAY_S = 3;    // recent peak drifts down toward the average over this long
  final float MIN_RANGE = 0.08;    // peak is kept at least this far above the average (ignores tiny wiggles)
  final float FLASH_DECAY_S = 0.18;
  Band lowB = new Band(), midB = new Band(), highB = new Band();
  float gain = 1.0;                // how hard the bands drive the shader (up/down keys, 0..2)
  int lowSeen = 0, midSeen = 0, highSeen = 0;
  PShader sh;

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
      out = max(rise, flash) * gain;
      return out;
    }
  }

  ThermalMode() {
    sh = loadShader("thermal.glsl");
  }

  void draw() {
    int lh = lowHits, mh = midHits, hh = highHits;
    lowB.update(low, lh != lowSeen);
    midB.update(mid, mh != midSeen);
    highB.update(high, hh != highSeen);
    lowSeen = lh; midSeen = mh; highSeen = hh;

    background(0);
    if (cam == null || cam.width == 0) return;   // first frame not here yet

    sh.set("lowAmt", lowB.out);
    sh.set("midAmt", midB.out);
    sh.set("highAmt", highB.out);
    sh.set("time", millis() / 1000.0);
    shader(sh);
    drawCamera();
    resetShader();

    if (showInfo) {
      fill(255);
      text(String.format("fps %.0f   red %.2f   blue %.2f   yellow %.2f   gain %.2f   onsets L%d M%d H%d",
        frameRate, lowB.out, midB.out, highB.out, gain, lowHits, midHits, highHits), 12, 20);
    }
  }

  void key() {
    if (keyCode == UP) gain = min(2, gain + 0.05);
    else if (keyCode == DOWN) gain = max(0, gain - 0.05);
  }
}
