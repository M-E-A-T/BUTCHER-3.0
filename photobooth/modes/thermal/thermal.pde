// Thermal: a heat-camera look for the webcam, in the spirit of Photo Booth's
// "Thermal Camera" effect. Brightness is mapped through a cold-to-hot
// gradient (navy -> blue -> cyan -> green -> yellow -> orange -> red -> white).
//
// Audio: /audio/lmh ,fff on UDP 9000 (same packets pyramid reads). Each band
// owns a colour of the gradient and makes it spread and glow when loud:
//   low -> red      mid -> blue      high -> yellow
// Each band reacts to its level relative to its own recent peak, plus a
// full-strength flash on every onset (/audio/onset/low|mid|high).
//
// Keys:  m  mirror on/off      up/down  how hard the bands drive it (0..2)
//        c  next camera        f        show/hide the debug readout

import processing.video.*;
import java.net.*;
import java.nio.*;

final int OSC_PORT = 9000;
volatile float low = 0, mid = 0, high = 0;   // 0..1, latest values off the wire
// Onset counters, bumped by the OSC thread on /audio/onset/low|mid|high.
volatile int lowHits = 0, midHits = 0, highHits = 0;
int lowSeen = 0, midSeen = 0, highSeen = 0;
DatagramSocket oscSock;

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

Capture cam;
String[] cams;
int camIndex = 0;
PShader thermal;
boolean mirror = true;
boolean showInfo = false;

void settings() {
  size(1280, 720, P2D);
}

void setup() {
  thermal = loadShader("thermal.glsl");
  cams = Capture.list();
  printArray(cams);
  openCamera(0);
  startOscListener();
  swSetup();   // switcher.pde: hidden until the controller shows this mode
}

void openCamera(int i) {
  if (cam != null) cam.stop();
  if (cams == null || cams.length == 0) {
    cam = new Capture(this, 1280, 720);   // let GStreamer pick the default device
  } else {
    camIndex = i % cams.length;
    cam = new Capture(this, 1280, 720, cams[camIndex]);
    println("camera: " + cams[camIndex]);
  }
  cam.start();
}

void captureEvent(Capture c) {
  c.read();
}

void draw() {
  int lh = lowHits, mh = midHits, hh = highHits;
  lowB.update(low, lh != lowSeen);
  midB.update(mid, mh != midSeen);
  highB.update(high, hh != highSeen);
  lowSeen = lh; midSeen = mh; highSeen = hh;

  background(0);
  if (cam == null || cam.width == 0) return;   // first frame not here yet

  thermal.set("lowAmt", lowB.out);
  thermal.set("midAmt", midB.out);
  thermal.set("highAmt", highB.out);
  thermal.set("time", millis() / 1000.0);
  shader(thermal);

  // Cover the window (crop, keep aspect), mirrored like a selfie camera.
  float s = max((float) width / cam.width, (float) height / cam.height);
  float w = cam.width * s, h = cam.height * s;
  pushMatrix();
  translate(width / 2.0, height / 2.0);
  if (mirror) scale(-1, 1);
  image(cam, -w / 2, -h / 2, w, h);
  popMatrix();
  resetShader();

  if (showInfo) {
    fill(255);
    text(String.format("fps %.0f   red %.2f   blue %.2f   yellow %.2f   gain %.2f   onsets L%d M%d H%d",
      frameRate, lowB.out, midB.out, highB.out, gain, lowHits, midHits, highHits), 12, 20);
  }
}

void keyPressed() {
  if (sendSwitch()) return;   // left/right: switch mode (switcher.pde)
  if (key == 'm') mirror = !mirror;
  else if (key == 'f') showInfo = !showInfo;
  else if (key == 'c') openCamera(camIndex + 1);
  else if (keyCode == UP) gain = min(2, gain + 0.05);
  else if (keyCode == DOWN) gain = max(0, gain - 0.05);
}

// Background thread: read /audio/lmh and keep the low value.
// Packet layout: "/audio/lmh\0\0" (12 B) ",fff\0\0\0\0" (8 B) low mid high (big-endian f32).
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(swOscPort()));   // 9000, or the relay port under the controller
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + swOscPort() + " (" + e.getMessage() + "); running without audio");
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[65536];   // fits any OSC packet, incl. large /audio/fft
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!oscSock.isClosed()) {
        try {
          pkt.setLength(buf.length);
          oscSock.receive(pkt);
          if (pkt.getLength() >= 32 && new String(buf, 0, 10, "US-ASCII").equals("/audio/lmh")) {
            ByteBuffer bb = ByteBuffer.wrap(buf, 20, 12);
            low = bb.getFloat();
            mid = bb.getFloat();
            high = bb.getFloat();
          } else if (pkt.getLength() >= 16 && new String(buf, 0, 13, "US-ASCII").equals("/audio/onset/")) {
            if (buf[13] == 'l') lowHits++;
            else if (buf[13] == 'm') midHits++;
            else if (buf[13] == 'h') highHits++;
          }
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("OSC: listening for /audio/lmh on UDP " + swOscPort());
}

void dispose() {
  if (oscSock != null) oscSock.close();
  if (cam != null) cam.stop();
}
