// ---------- Mode: pixelz ----------
// The webcam's resolution follows the bass: the low band (/audio/lmh) sets the
// pixel size. Silence = full resolution, loud low = big chunky blocks.
//
// Keys:  up/down  biggest block size (px)

class PixelzMode {
  final float ATTACK_S = 0.01;     // blocks grow almost instantly on a hit...
  final float RELEASE_S = 0.10;    // ...and sharpen back quickly
  final float CURVE = 1.5;         // >1 keeps quiet bass sharp, only loud bass gets chunky
  float env = 0;
  float maxBlock = 80;             // block size at full low (px), up/down keys
  PShader pix;

  PixelzMode() {
    pix = loadShader("pixelate.glsl");
  }

  void draw() {
    float fps = max(frameRate, 1);
    float target = constrain(low, 0, 1);
    env += (target - env) * (1 - exp(-1.0 / (fps * (target > env ? ATTACK_S : RELEASE_S))));
    float block = lerp(1, maxBlock, pow(env, CURVE));   // screen pixels per block

    background(0);
    if (cam != null && cam.width > 0) {
      float s = max((float) width / cam.width, (float) height / cam.height);
      pix.set("u_grid", max(1, cam.width * s / block), max(1, cam.height * s / block));
      shader(pix);
      drawCamera();
      resetShader();
    }

    if (showInfo) {
      fill(255);
      text("low " + nf(low, 0, 2) + "   block " + nf(block, 0, 1) + " px   max " + (int) maxBlock
         + "   fps " + nf(frameRate, 0, 0), 12, height - 14);
    }
  }

  void key() {
    if (keyCode == UP)   maxBlock = min(maxBlock + 10, 400);
    else if (keyCode == DOWN) maxBlock = max(maxBlock - 10, 2);
  }
}
