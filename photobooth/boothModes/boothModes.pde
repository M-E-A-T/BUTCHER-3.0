// boothModes: the photobooth (trigger -> countdown -> GIF -> playback -> QR) with the
// four modesTogether looks as the live view. The GIF records the mode as seen on screen.
//   PS Move: square = thermal, triangle = fft, cross = pixelz, circle = organism
//            (switches on the live screen only)
//   trigger = shoot / confirm. Booth flow is in booth.pde.
//
// Audio: BUTCHER audio server on UDP 9000 (/audio/lmh, /audio/onset/*, /audio/fft, /audio/meta).
//
// Keys (all modes):  left/right  switch mode     m  mirror     c  next camera     f  info readout
// plus each mode's own keys (see its tab).
// Needs the "Video Library for Processing 4".

import processing.video.*;
import java.net.*;
import java.nio.*;
import java.io.*;

String[] MODE_NAMES = { "organism", "pixelz", "thermal", "fft" };
int current = 0;

// ---- shared audio (written by the OSC thread) ----
final int OSC_PORT = 9000;
DatagramSocket oscSock;
volatile float low = 0, mid = 0, high = 0;          // 0..1, /audio/lmh
volatile int lowHits = 0, midHits = 0, highHits = 0; // onset counters per band (thermal)
// organism's onset counter + band of the latest onset are declared in organism.pde

// ---- shared camera ----
Capture cam;
String[] cams;
int camIndex = 0;
boolean mirror = true;      // pixelz / thermal / fft (organism has its own "Mirror camera" toggle)
boolean showInfo = false;

ThermalMode thermalMode;
PixelzMode pixelzMode;

// fft cloud (cloud.pde) expects these; single screen, no wall of screens to span.
int spanCols = 1, spanRows = 1, spanRow = 0, spanGapX = 0, spanGapY = 0;
float spanX = 0;
int spanWidth() { return width; }
int spanHeight() { return height; }
int spanOffsetX() { return 0; }
int spanOffsetTop() { return 0; }
int spanOffsetBottom() { return 0; }

void settings() {
  fullScreen(P2D);
  pixelDensity(1);   // the fft cloud's point sizes and rim widths are in 1x pixels
}

void setup() {
  textFont(createFont("SansSerif", 13));
  cams = Capture.list();
  printArray(cams);
  // The video library hands frames straight to the GPU texture by default
  // (GL buffer sink). On the booth machine that made the live camera jump back
  // and forth between frames; plain pixel copies keep them in order.
  try {
    java.lang.reflect.Field f = Video.class.getDeclaredField("useGLBufferSink");
    f.setAccessible(true);
    f.setBoolean(null, false);
  } catch (Exception e) {
    println("could not turn off the GL buffer sink: " + e);
  }
  openCamera(0);

  organismSetup();
  pixelzMode = new PixelzMode();
  thermalMode = new ThermalMode();
  cloud = new FftCloud();

  startOscListener();
  boothSetup();
  showMode();
}

void openCamera(int i) {
  if (cam != null) cam.stop();
  camFrames = 0;
  camCountFrom = millis();
  camFpsLogged = false;
  if (platform == LINUX && i == 0) {
    // Ask for MJPEG explicitly: the booth webcam does 1280x720 at 30 fps as
    // MJPEG but only 5 fps as raw YUY2, which GStreamer may otherwise pick.
    camIndex = 0;
    cam = new Capture(this, 1280, 720,
      "pipeline:v4l2src device=/dev/video0 ! image/jpeg,width=1280,height=720,framerate=30/1 ! jpegdec");
    println("camera: /dev/video0 MJPEG 1280x720@30");
  } else if (cams == null || cams.length == 0) {
    cam = new Capture(this, 1280, 720);   // let GStreamer pick the default device
  } else {
    camIndex = i % cams.length;
    cam = new Capture(this, 1280, 720, cams[camIndex]);
    println("camera: " + cams[camIndex]);
  }
  cam.start();
}

int camFrames = 0, camCountFrom = 0;
boolean camFpsLogged = false;

void captureEvent(Capture c) {
  c.read();
  camFrames++;
  // Log the real camera rate once, 5 s after it opens (lag check).
  int dt = millis() - camCountFrom;
  if (!camFpsLogged && dt > 5000) {
    camFpsLogged = true;
    println(String.format("camera fps: %.1f", camFrames * 1000.0 / dt));
  }
}

// Camera covering the window (crop, keep aspect), mirrored like a selfie camera.
void drawCamera() {
  float s = max((float) width / cam.width, (float) height / cam.height);
  float w = cam.width * s, h = cam.height * s;
  pushMatrix();
  translate(width / 2.0, height / 2.0);
  if (mirror) scale(-1, 1);
  image(cam, -w / 2, -h / 2, w, h);
  popMatrix();
}

void draw() {
  int r = requestedMode;
  if (r >= 0) {
    requestedMode = -1;
    if (r != current && phase == 0) { current = r; showMode(); }
  }
  if (phase == 3 || phase == 4) {
    background(12);
    drawPlayback();
  } else {
    switch (current) {
      case 0: organismDraw(); break;
      case 1: pixelzMode.draw(); break;
      case 2: thermalMode.draw(); break;
      case 3: fftDraw(); break;
    }
  }
  // leave shared drawing state clean for whichever mode draws next
  imageMode(CORNER);
  blendMode(BLEND);
  noTint();
  resetShader();
  boothDraw();   // booth.pde: grabs GIF frames from the mode image, then draws the booth overlays
}

void fftDraw() {
  background(0);
  if (cam != null && cam.width > 0) drawCamera();
  cloud.draw();   // cloud.pde: FFT cloud on top, low on the left, high on the right
  if (showInfo) {
    fill(255);
    text(String.format("fps %.0f", frameRate), 12, 20);
  }
}

void showMode() {
  surface.setTitle("boothModes: " + MODE_NAMES[current]);
  modeShownAt = millis();
  println("Mode: " + MODE_NAMES[current]);
  if (current != 0 && panel != null) panel.setVisible(false);   // organism's Controls window
}

void keyPressed() {
  if (key == ' ') { wantShoot = true; return; }   // spacebar = trigger squeeze
  if (key == CODED && (keyCode == LEFT || keyCode == RIGHT)) {
    if (phase != 0) return;
    current = (current + (keyCode == RIGHT ? 1 : -1) + MODE_NAMES.length) % MODE_NAMES.length;
    showMode();
    return;
  }
  if (key == ESC) return;
  if (current == 0) { organismKey(); return; }   // organism uses its own key set
  if (key == 'm') mirror = !mirror;
  else if (key == 'f') showInfo = !showInfo;
  else if (key == 'c') openCamera(camIndex + 1);
  else if (current == 1) pixelzMode.key();
  else if (current == 2) thermalMode.key();
}

// Background thread: one listener for every mode.
//   /audio/lmh ,fff             -> low mid high
//   /audio/onset/low|mid|high   -> onset counters (thermal + organism)
//   /audio/fft, /audio/meta     -> fft cloud (cloud.pde)
void startOscListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(OSC_PORT));
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + OSC_PORT + " (" + e.getMessage() + "); running without audio");
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
          int n = pkt.getLength();
          if (n >= 32 && new String(buf, 0, 10, "US-ASCII").equals("/audio/lmh")) {
            ByteBuffer bb = ByteBuffer.wrap(buf, 20, 12);
            low = bb.getFloat();
            mid = bb.getFloat();
            high = bb.getFloat();
          } else if (n >= 16 && new String(buf, 0, 13, "US-ASCII").equals("/audio/onset/")) {
            int band = buf[13] == 'l' ? 0 : buf[13] == 'm' ? 1 : buf[13] == 'h' ? 2 : -1;
            if (band == 0) lowHits++;
            else if (band == 1) midHits++;
            else if (band == 2) highHits++;
            if (band >= 0) { lastBand = band; lowOnsets++; }   // organism
          } else {
            parseFftOsc(buf, n);   // cloud.pde
          }
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("OSC: listening on UDP " + OSC_PORT);
}

void dispose() {
  stopBridge();
  if (oscSock != null) oscSock.close();
  if (cam != null) cam.stop();
}
