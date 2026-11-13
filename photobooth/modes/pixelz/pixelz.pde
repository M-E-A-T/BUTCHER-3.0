// Pixelz: the webcam's resolution follows the bass.
// The low band from the BUTCHER audio server (/audio/lmh ,fff on UDP 9000) sets the
// pixel size: silence = full resolution, loud low = big chunky blocks.
//
// Keys:  m  mirror on/off      up/down  biggest block size (px)
//        c  next camera        f        show/hide the debug readout

import processing.video.*;
import java.net.*;
import java.nio.*;

final int OSC_PORT = 9000;
volatile float low = 0;          // 0..1, latest value off the wire
DatagramSocket oscSock;

final float ATTACK_S = 0.01;     // blocks grow almost instantly on a hit...
final float RELEASE_S = 0.10;    // ...and sharpen back quickly
final float CURVE = 1.5;         // >1 keeps quiet bass sharp, only loud bass gets chunky
float env = 0;
float maxBlock = 80;             // block size at full low (px), up/down keys

Capture cam;
String[] cams;
int camIndex = 0;
PShader pix;
boolean mirror = true;
boolean showInfo = false;

void settings() {
  size(1280, 720, P2D);
}

void setup() {
  surface.setTitle("Pixelz");
  pix = loadShader("pixelate.glsl");
  textFont(createFont("SansSerif", 14));
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
  float fps = max(frameRate, 1);
  float target = constrain(low, 0, 1);
  env += (target - env) * (1 - exp(-1.0 / (fps * (target > env ? ATTACK_S : RELEASE_S))));
  float block = lerp(1, maxBlock, pow(env, CURVE));   // screen pixels per block

  background(0);
  if (cam != null && cam.width > 0) {
    // cover the window, keep aspect
    float s = max((float) width / cam.width, (float) height / cam.height);
    float w = cam.width * s, h = cam.height * s;
    pix.set("u_grid", max(1, w / block), max(1, h / block));
    shader(pix);
    pushMatrix();
    translate(width / 2.0, height / 2.0);
    if (mirror) scale(-1, 1);
    imageMode(CENTER);
    image(cam, 0, 0, w, h);
    popMatrix();
    resetShader();
  }

  if (showInfo) {
    fill(255);
    text("low " + nf(low, 0, 2) + "   block " + nf(block, 0, 1) + " px   max " + (int) maxBlock
       + "   fps " + nf(frameRate, 0, 0), 12, height - 14);
  }
}

void keyPressed() {
  if (sendSwitch()) return;   // left/right: switch mode (switcher.pde)
  if (key == 'm') mirror = !mirror;
  else if (key == 'f') showInfo = !showInfo;
  else if (key == 'c') openCamera(camIndex + 1);
  else if (keyCode == UP)   maxBlock = min(maxBlock + 10, 400);
  else if (keyCode == DOWN) maxBlock = max(maxBlock - 10, 2);
}

// Background thread: read /audio/lmh packets and keep the low value.
// Packet layout: "/audio/lmh\0\0" (12 B) ",fff\0\0\0\0" (8 B) low mid high (big-endian f32).
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(swOscPort()));   // 9000, or the relay port under the controller
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + swOscPort() + " (" + e.getMessage() + "); image stays sharp");
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
            low = ByteBuffer.wrap(buf, 20, 4).getFloat();
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
