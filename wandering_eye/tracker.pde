// Person tracking for the eye, cheap: webcam -> 80x60 brightness grid ->
// compare to a slowly learned background -> centroid of what's different.
// The eye looks at (lookX, lookY) in screen pixels. No camera frames yet ->
// it follows the mouse instead.
import processing.video.*;

Capture cam;
int GW = 80, GH = 60;                 // tracking grid
float[] bg = new float[GW * GH];      // learned background brightness
boolean bgReady = false;
float BG_LEARN = 0.004;   // per frame; lower = a still person stays tracked longer
float DIFF = 28;          // brightness difference (0..255) that counts as "person"
float MIN_FILL = 0.01;    // need this fraction of the grid to count as someone
float RESET_FILL = 0.6;   // more than this changed = lights changed, relearn
int LOST_MS = 3000;       // nobody for this long -> eye drifts back to center
float LOOK_GAIN_X = 1.2;  // >1 = eye turns further for the same sideways move
float LOOK_GAIN_Y = 2.0;  // up/down: the upper body moves less in the frame, so more gain
float Y_CENTER = 0.35;    // where the upper body sits (0 top..1 bottom of camera) when the eye looks straight ahead
float TARGET_EASE = 0.35; // 0..1 per camera frame, smooths the detected position
float LOOK_EASE = 0.06;   // 0..1 per frame, how fast the eye catches up

float lookX = 640, lookY = 360;       // smoothed, used by updatePupil()
float targetX = 640, targetY = 360;
int lastSeenMs = -100000;
float lastCy = 0;   // for the log, to tune Y_CENTER
boolean camFrames = false;
boolean newFrame = false;

// ---- YOLO mode: eye_yolo.py owns the camera, detects everyone, chooses who
// to watch, and sends OSC to UDP 9000, the same port and listener as the
// audio feed (see startOscListener in wandering_eye.pde):
//   /eye/look ,fff  x y n   head of the chosen person, 0..1 in the mirrored
//                           camera image; n = people in view
//   /eye/none ,f    n       nobody chosen
// The sketch then doesn't open the camera itself.
boolean USE_YOLO = true;
float YOLO_Y_CENTER = 0.30;    // head height (0 top..1 bottom) that means "looking straight ahead"
float YOLO_DEADZONE = 0.025;   // ignore moves of the person smaller than this (0..1 of the camera image)
float YOLO_TARGET_EASE = 0.08; // per frame
float YOLO_LOOK_EASE = 0.035;  // per frame; the pupil's own glide
float yoloHoldX = 0.5, yoloHoldY = 0.5;
volatile float yoloX = 0.5, yoloY = 0.5;
volatile int yoloSeenMs = -100000;    // last /eye/look
volatile int yoloAliveMs = -100000;   // last /eye/look or /eye/none

void updateYolo() {
  if (millis() - yoloAliveMs > 2000) {   // detector not running: mouse
    lookX = mouseX;
    lookY = mouseY;
    return;
  }
  if (millis() - yoloSeenMs < LOST_MS) {
    // dead zone: small wobbles of the detection don't move the eye at all
    if (abs(yoloX - yoloHoldX) > YOLO_DEADZONE || abs(yoloY - yoloHoldY) > YOLO_DEADZONE) {
      yoloHoldX += (yoloX - yoloHoldX) - Math.signum(yoloX - yoloHoldX) * min(abs(yoloX - yoloHoldX), YOLO_DEADZONE);
      yoloHoldY += (yoloY - yoloHoldY) - Math.signum(yoloY - yoloHoldY) * min(abs(yoloY - yoloHoldY), YOLO_DEADZONE);
    }
    float nx = constrain((yoloHoldX - 0.5) * 2 * LOOK_GAIN_X, -1, 1);
    float ny = constrain((yoloHoldY - YOLO_Y_CENTER) * 2 * LOOK_GAIN_Y, -1, 1);
    targetX += (width / 2.0 + nx * width / 2.0 - targetX) * YOLO_TARGET_EASE;
    targetY += (height / 2.0 + ny * height / 2.0 - targetY) * YOLO_TARGET_EASE;
  } else {
    targetX = width / 2.0;
    targetY = height / 2.0;
  }
  lookX += (targetX - lookX) * YOLO_LOOK_EASE;
  lookY += (targetY - lookY) * YOLO_LOOK_EASE;
}

void startTracker() {
  if (USE_YOLO) return;   // eye_yolo.py has the camera; its OSC arrives on the audio listener
  String[] cams = Capture.list();
  if (cams == null || cams.length == 0) {
    println("tracker: no camera, following the mouse");
    return;
  }
  // Get frames as plain pixels (not straight to a GPU texture) so we can read them.
  try {
    java.lang.reflect.Field f = Video.class.getDeclaredField("useGLBufferSink");
    f.setAccessible(true);
    f.setBoolean(null, false);
  } catch (Exception e) {
    println("tracker: could not turn off the GL buffer sink: " + e);
  }
  println("tracker: camera " + cams[0]);
  cam = new Capture(this, 640, 480, cams[0]);
  cam.start();
}

void captureEvent(Capture c) {
  c.read();
  newFrame = true;
  camFrames = true;
}

void updateTracker() {
  if (USE_YOLO) { updateYolo(); return; }
  if (!camFrames) {                    // no camera: mouse
    lookX = mouseX;
    lookY = mouseY;
    return;
  }
  if (newFrame) {
    newFrame = false;
    trackFrame();
  }
  if (millis() - lastSeenMs > LOST_MS) {
    targetX = width / 2.0;
    targetY = height / 2.0;
  }
  lookX += (targetX - lookX) * LOOK_EASE;
  lookY += (targetY - lookY) * LOOK_EASE;
}

void trackFrame() {
  cam.loadPixels();
  int cw = cam.width, ch = cam.height;
  if (cw == 0 || cam.pixels == null || cam.pixels.length < cw * ch) return;

  float sx = 0, sy = 0, wsum = 0, lumSum = 0;
  float[] rowW = new float[GH];
  int n = 0;
  for (int gy = 0; gy < GH; gy++) {
    int py = gy * ch / GH;
    for (int gx = 0; gx < GW; gx++) {
      int c = cam.pixels[py * cw + gx * cw / GW];
      float lum = ((c >> 16 & 0xff) * 77 + (c >> 8 & 0xff) * 150 + (c & 0xff) * 29) >> 8;
      int i = gy * GW + gx;
      lumSum += lum;
      if (!bgReady) { bg[i] = lum; continue; }
      float d = abs(lum - bg[i]);
      if (d > DIFF) {               // weight by how different, so faint noise counts less
        float w = d - DIFF;
        sx += gx * w; sy += gy * w; wsum += w; n++;
        rowW[gy] += w;
      }
      bg[i] += (lum - bg[i]) * BG_LEARN;
    }
  }
  if (!bgReady) { bgReady = true; return; }

  int total = GW * GH;
  if (frameCount % 30 == 0) println("tracker: lum " + int(lumSum / (GW * GH)) + "  upperY " + nf(lastCy, 0, 2) + "  fill " + nf(100.0 * n / total, 0, 1) + "%  target " + int(targetX) + "," + int(targetY) + "  look " + int(lookX) + "," + int(lookY));
  if (n > total * RESET_FILL) { bgReady = false; return; }   // lights changed
  if (n < total * MIN_FILL) return;

  float cx = sx / wsum / (GW - 1);     // 0..1 in camera image
  // Up/down: centroid of the rows above the body's middle (head + shoulders),
  // so crouching, standing up and leaning move it a lot.
  float mid = sy / wsum, uy = 0, uw = 0;
  for (int gy = 0; gy <= (int)mid; gy++) { uy += gy * rowW[gy]; uw += rowW[gy]; }
  float cy = (uw > 0 ? uy / uw : mid) / (GH - 1);
  lastCy = cy;
  // Mirror X: someone on the camera's left is on the screen's right as they see it.
  float nx = constrain((0.5 - cx) * 2 * LOOK_GAIN_X, -1, 1);
  float ny = constrain((cy - Y_CENTER) * 2 * LOOK_GAIN_Y, -1, 1);
  targetX += (width / 2.0 + nx * width / 2.0 - targetX) * TARGET_EASE;
  targetY += (height / 2.0 + ny * height / 2.0 - targetY) * TARGET_EASE;
  lastSeenMs = millis();
}
