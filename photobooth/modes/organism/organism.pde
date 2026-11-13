// Based on "Shader_251001_2" by SamuelYAN (CC BY-NC-SA)
// https://openprocessing.org/sketch/2741733
// Processing version: landscape, live camera background, sunset palette,
// and a separate Controls window for experimenting.
//
// Starts from presets/latest.json with the Controls window hidden.
// A new pattern is generated on every low, mid or high onset from the audio server,
// colored by band: low = red, mid = orange, high = yellow (see startOscListener),
// and the pattern only moves briefly after each onset: no sound, no movement.
// Keys (sketch window): TAB/h = show/hide Controls window, s = save PNG, r = reshuffle colors, n = new random pattern.
// Needs the "Video Library for Processing 4" (Sketch > Import Library > Manage Libraries).

import processing.video.*;
import java.net.*;

// Each onset from the BUTCHER audio server (/audio/onset/low, /mid, /high on UDP 9000)
// generates the next pattern in the sequence.
final int OSC_PORT = 9000;
DatagramSocket oscSock;
volatile int lowOnsets = 0;   // any band's onset count, bumped by the OSC thread, consumed in draw()
volatile float level = 0;     // loudest of low/mid/high from /audio/lmh (0 = silence)
volatile int lastBand = 0;    // 0 = low, 1 = mid, 2 = high (band of the latest onset)

// Each band paints its generation in its own color: low = red, mid = orange, high = yellow.
int[] bandColor = { #C1121F, #F77F00, #F8FF33 };
int lowOnsetsSeen = 0;

Capture cam;
PShader fx;
Controls panel;

// ---------- Sunset palette ----------
int[] sunset = { #C1121F, #E63946, #F77F00, #F8FF33, #280137 };
float[][] palNow = new float[5][3];    // what's on screen (fades toward palTarget)
float[][] palTarget = new float[5][3];
int lastShuffle = 0;

void shufflePalette() {
  for (int i = sunset.length - 1; i > 0; i--) {
    int j = (int) random(i + 1);
    int t = sunset[i]; sunset[i] = sunset[j]; sunset[j] = t;
  }
  String order = "";
  for (int i = 0; i < 5; i++) {
    int c = sunset[i];
    palTarget[i][0] = red(c) / 255.0;
    palTarget[i][1] = green(c) / 255.0;
    palTarget[i][2] = blue(c) / 255.0;
    order += "#" + hex(c, 6) + (i < 4 ? " | " : "");
  }
  println("Palette: " + order);
  lastShuffle = millis();
}

// ---------- Blend modes ----------
String[] modeNames = { "NORMAL", "SCREEN", "ADD", "LIGHTEST", "DIFFERENCE", "EXCLUSION", "MULTIPLY", "DARKEST" };
int[]    modeConst = { BLEND,    SCREEN,   ADD,   LIGHTEST,   DIFFERENCE,   EXCLUSION,   MULTIPLY,   DARKEST };
int[]    modeGroup = { 0,        1,        1,     1,          1,            1,           2,          2 };
int modeIndex = 0;

float t = 0;            // shader time, advanced by the speed slider
float motion = 0;       // 1 right after a low onset, fades to 0 (still) in silence
int lastHit = -100000;  // millis() of the latest onset
float presence = 0;     // overlay visibility: 1 while music plays, 0 the instant it stops
int lastMillis = 0;

// Random pattern each run (and on 'n' / "New pattern"). Only picks a different
// spot in the noise field + direction, so line thickness/coverage stays the same.
float seedX, seedY, angle;
void newPattern() {
  rollPattern();
  checkCoverage = true;   // draw() re-rolls until the pattern covers enough of the screen
}
void rollPattern() {
  seedX = random(-500, 500);
  seedY = random(-500, 500);
  angle = random(TWO_PI);
  t = random(0, 1000);
}

// ---------- Minimum coverage ----------
// Some random patterns only cover a sliver of the screen and look like nothing triggered.
// Each new pattern is rendered small offscreen; if its lines cover less than
// "Min screen coverage", another one is rolled (up to 20 tries, else the best one).
boolean checkCoverage = false;
PGraphics probe;

float measureCoverage() {
  probe.beginDraw();
  probe.clear();
  probe.noStroke();
  setFxUniforms(probe.width, probe.height);
  fx.set("u_opacity", 1.0);
  fx.set("u_mode", 0.0);
  probe.shader(fx);
  probe.rect(0, 0, probe.width, probe.height);
  probe.resetShader();
  probe.endDraw();
  probe.loadPixels();
  int on = 0;
  for (int px : probe.pixels) if ((px >>> 24) > 127) on++;
  return on / (float) probe.pixels.length;
}

void ensureCoverage() {
  float want = P("minCoverage");
  float cov = measureCoverage();
  float bestCov = cov, bx = seedX, by = seedY, ba = angle, bt = t;
  int tries = 1;
  while (cov < want && tries < 20) {
    rollPattern();
    cov = measureCoverage();
    tries++;
    if (cov > bestCov) { bestCov = cov; bx = seedX; by = seedY; ba = angle; bt = t; }
  }
  seedX = bx; seedY = by; angle = ba; t = bt;
  println("Pattern: coverage " + nf(bestCov * 100, 0, 0) + "% (" + tries + (tries == 1 ? " try)" : " tries)"));
}

// Paint the next generation in one band's color, applied instantly (no fade).
// Keeps the original line texture: the dark purple stripe slot (#280137) stays in the
// palette, the band color fills the rest with light/dark shades, and sparks stay yellow.
void paintBand(int b) {
  int c = bandColor[b];
  float r = red(c) / 255.0, g = green(c) / 255.0, bl = blue(c) / 255.0;
  float[] shade = { 1.0, 0.75, 1.0, -1, 1.2 };   // -1 = dark purple stripe
  for (int i = 0; i < 5; i++) {
    if (shade[i] < 0) {
      palTarget[i][0] = 0x28 / 255.0; palTarget[i][1] = 0x01 / 255.0; palTarget[i][2] = 0x37 / 255.0;
    } else {
      palTarget[i][0] = min(1, r * shade[i]);
      palTarget[i][1] = min(1, g * shade[i]);
      palTarget[i][2] = min(1, bl * shade[i]);
    }
    palNow[i] = palTarget[i].clone();
  }
}

void settings() {
  size(1280, 880, P2D);   // 16:11 landscape
}

void setup() {
  surface.setTitle("Organism");
  noStroke();
  fx = loadShader("frag.glsl");

  newPattern();
  shufflePalette();
  loadPreset();   // start from the saved look (presets/latest.json)
  checkCoverage = false;   // keep the preset's own pattern for the first frame
  probe = createGraphics(160, 110, P2D);
  for (int i = 0; i < 5; i++) palNow[i] = palTarget[i].clone();

  String[] cams = Capture.list();
  if (cams.length == 0) {
    println("No camera found.");
  } else {
    printArray(cams);
    cam = new Capture(this, cams[0]);   // change index to pick another camera
    cam.start();
  }

  textFont(createFont("SansSerif", 12));
  panel = new Controls();
  startOscListener();
  swSetup();   // switcher.pde: hidden until the controller shows this mode
  lastMillis = millis();
}

void draw() {
  // time advances at the chosen speed, so changing speed never jumps
  int now = millis();
  float dt = (now - lastMillis) / 1000.0;
  lastMillis = now;

  // next generation on each low onset (several onsets between frames count once).
  // The sequence only moves after an onset: a burst of motion that fades to a still
  // frame over "Motion after onset" seconds, so with no sound the image holds still.
  int onsets = lowOnsets;
  if (onsets != lowOnsetsSeen) { lowOnsetsSeen = onsets; newPattern(); paintBand(lastBand); motion = 1; lastHit = now; if (level >= P("silenceLevel")) presence = 1; }
  t += dt * P("speed") * motion;
  float hold = P("onsetMotion");
  motion = hold <= 0.01 ? 0 : motion * exp(-dt / (hold / 3.0));   // ~gone after `hold` s
  // no hits for "Hide after silence" seconds: the overlay fades out (over 1 s);
  // the next hit brings it back instantly
  float silent = P("hideAfter");
  // Overlay off the instant the music stops: the audio level drops to silence,
  // or (fallback) no hits for "Hide after no hits" seconds. No fade.
  boolean quiet = level < P("silenceLevel") || (silent > 0.01 && now - lastHit > silent * 1000);
  if (quiet && presence > 0) println("Overlay off (silence)");
  if (quiet) presence = 0;

  // auto-shuffle + smooth palette fade
  float every = P("autoShuffle");
  if (every > 0.5 && millis() - lastShuffle > every * 1000) shufflePalette();
  float fade = P("paletteFade") <= 0.01 ? 1.0 : min(1.0, 1.0 / (P("paletteFade") * frameRate));
  for (int i = 0; i < 5; i++)
    for (int k = 0; k < 3; k++)
      palNow[i][k] = lerp(palNow[i][k], palTarget[i][k], fade);

  background(0);

  // ---- camera ----
  if (cam != null && cam.width > 0) {
    float s = max((float) width / cam.width, (float) height / cam.height);
    float w = cam.width * s, h = cam.height * s;
    float b = P("camBright") * 255;
    float warm = P("camWarm");
    tint(b, b * (1 - warm * 0.4), b * (1 - warm * 0.7));
    pushMatrix();
    translate(width / 2.0, height / 2.0);
    if (B("mirror")) scale(-1, 1);
    imageMode(CENTER);
    image(cam, 0, 0, w, h);
    popMatrix();
    noTint();
  }

  // ---- shader overlay ----
  if (checkCoverage) { checkCoverage = false; ensureCoverage(); }
  setFxUniforms(pixelWidth, pixelHeight);
  fx.set("u_opacity", P("opacity") * presence);

  blendMode(modeConst[modeIndex]);
  shader(fx);
  rect(0, 0, width, height);
  resetShader();
  blendMode(BLEND);

  // save before drawing the panel so PNGs are clean
  if (savePending) { saveFrame("shader_camera-####.png"); println("Saved PNG"); savePending = false; }

}

boolean savePending = false;

void setFxUniforms(float w, float h) {
  fx.set("u_resolution", (float) w, (float) h);
  fx.set("u_time", t);
  fx.set("u_seed", seedX, seedY);
  fx.set("u_angle", angle);
  fx.set("u_rotate", B("rotate") ? 1.0 : 0.0);
  fx.set("u_zoom", P("zoom"));
  fx.set("u_detail", P("detail"));
  fx.set("u_octaves", P("octaves"));
  fx.set("u_warp", P("warp"));
  fx.set("u_warpFreq", P("warpFreq"));
  fx.set("u_density", P("density"));
  fx.set("u_lineSpeed", P("lineSpeed"));
  fx.set("u_drift", P("drift"));
  fx.set("u_thick", P("thickness"));
  fx.set("u_soft", P("softness"));
  for (int i = 0; i < 5; i++) fx.set("u_c" + i, palNow[i][0], palNow[i][1], palNow[i][2]);
  fx.set("u_colorSpeed", P("colorSpeed"));
  fx.set("u_colorBands", P("colorBands"));
  fx.set("u_hardColors", B("hardColors") ? 1.0 : 0.0);
  fx.set("u_pingpong", B("pingpong") ? 1.0 : 0.0);
  fx.set("u_sparkAmt", P("sparks"));
  fx.set("u_sparkRadius", P("sparkRadius"));
  fx.set("u_sparkColor", 0.973, 1.0, 0.2);   // #F8FF33
  fx.set("u_opacity", P("opacity"));
  fx.set("u_invert", B("invert") ? 1.0 : 0.0);
  fx.set("u_mode", (float) modeGroup[modeIndex]);
}

void captureEvent(Capture c) {
  c.read();
}

void keyPressed() {
  if (sendSwitch()) return;   // left/right: switch mode (switcher.pde)
  if (key == TAB || key == 'h') {
    panel.setVisible(!panel.isVisible());
    return;
  }
  handleKey(key);
}

void handleKey(char k) {
  if (k == 's') savePending = true;
  if (k == 'r') shufflePalette();
  if (k == 'n') newPattern();
}

// Background thread: count /audio/onset/low, /mid and /high packets and remember the band.
// Packet layout: "/audio/onset/low\0\0\0\0" (20 B) ",i\0\0" (4 B) 1 (int32).
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(swOscPort()));   // 9000, or the relay port under the controller
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + swOscPort() + " (" + e.getMessage() + "); pattern won't follow low onsets");
    return;
  }
  Thread th = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[65536];   // fits any OSC packet, incl. large /audio/fft
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!oscSock.isClosed()) {
        try {
          pkt.setLength(buf.length);  // receive() shrinks it to the last packet's size
          oscSock.receive(pkt);
          int n = pkt.getLength();
          int band = -1;
          if      (n >= 17 && buf[16] == 0 && new String(buf, 0, 16, "US-ASCII").equals("/audio/onset/low"))  band = 0;
          else if (n >= 17 && buf[16] == 0 && new String(buf, 0, 16, "US-ASCII").equals("/audio/onset/mid"))  band = 1;
          else if (n >= 18 && buf[17] == 0 && new String(buf, 0, 17, "US-ASCII").equals("/audio/onset/high")) band = 2;
          if (band >= 0) { lastBand = band; lowOnsets++; }
          else if (n >= 32 && new String(buf, 0, 10, "US-ASCII").equals("/audio/lmh")) {
            java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(buf, 20, 12);
            level = max(bb.getFloat(), max(bb.getFloat(), bb.getFloat()));
          }   // every band triggers the next generation
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  th.setDaemon(true);
  th.start();
  println("OSC: listening for /audio/onset/low + /mid + /high on UDP " + swOscPort());
}

void dispose() {
  if (oscSock != null) oscSock.close();
  if (cam != null) cam.stop();
}
