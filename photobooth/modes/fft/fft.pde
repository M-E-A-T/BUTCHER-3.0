// FFT: the pyramid's FFT cloud drawn over the live camera.
// Frequency runs left (30 Hz) to right (sr/2) across the full width of the
// frame, the newest spectrum sits on the bottom edge and the last few seconds
// recede up and back behind it, like the pyramid sketch.
//
// cloud.pde is a straight copy of pyramid/cloud.pde. It expects a few things
// from the main sketch (span helpers, metaSr / parseFftOsc fed by an OSC
// thread); they're defined here for a single screen.
//
// Data: /audio/fft and /audio/meta on UDP 9000. The audio server only sends
// /audio/fft when osc.send_fft is true (it is, in realtime/configs/main.yaml).
//
// Keys:  m  mirror on/off      c  next camera      f  show/hide fps

import processing.video.*;
import java.net.*;
import java.nio.*;

final int OSC_PORT = 9000;
DatagramSocket oscSock;

Capture cam;
String[] cams;
int camIndex = 0;
boolean mirror = true;
boolean showInfo = false;

// Single screen: no wall of screens to span (see pyramid.pde for the real thing).
int spanCols = 1, spanRows = 1, spanRow = 0, spanGapX = 0, spanGapY = 0;
float spanX = 0;
int spanWidth() { return width; }
int spanHeight() { return height; }
int spanOffsetX() { return 0; }
int spanOffsetTop() { return 0; }
int spanOffsetBottom() { return 0; }

void settings() {
  size(1280, 720, P2D);
  pixelDensity(1);   // the cloud's point sizes and rim widths are in 1x pixels
}

void setup() {
  cams = Capture.list();
  printArray(cams);
  openCamera(0);
  cloud = new FftCloud();
  startOscListener();
  swSetup();   // switcher.pde: hidden until the controller shows this mode
}

void openCamera(int i) {
  if (cam != null) cam.stop();
  if (cams == null || cams.length == 0) {
    cam = new Capture(this, 1280, 720);
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
  background(0);
  if (cam != null && cam.width > 0) {
    // Cover the window (crop, keep aspect), mirrored like a selfie camera.
    float s = max((float) width / cam.width, (float) height / cam.height);
    float w = cam.width * s, h = cam.height * s;
    pushMatrix();
    translate(width / 2.0, height / 2.0);
    if (mirror) scale(-1, 1);
    image(cam, -w / 2, -h / 2, w, h);
    popMatrix();
  }

  cloud.draw();   // cloud.pde: FFT cloud on top, low on the left, high on the right

  if (showInfo) {
    fill(255);
    text(String.format("fps %.0f", frameRate), 12, 20);
  }
}

void keyPressed() {
  if (sendSwitch()) return;   // left/right: switch mode (switcher.pde)
  if (key == 'm') mirror = !mirror;
  else if (key == 'f') showInfo = !showInfo;
  else if (key == 'c') openCamera(camIndex + 1);
}

// Background thread: hand /audio/fft and /audio/meta packets to the cloud.
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(swOscPort()));   // 9000, or the relay port under the controller
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + swOscPort() + " (" + e.getMessage() + "); no FFT cloud");
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
          parseFftOsc(buf, pkt.getLength());   // cloud.pde
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("OSC: listening for /audio/fft on UDP " + swOscPort());
}

void dispose() {
  if (oscSock != null) oscSock.close();
  if (cam != null) cam.stop();
}
