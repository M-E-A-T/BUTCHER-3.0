
import java.net.DatagramSocket;
import java.net.DatagramPacket;
import java.net.InetAddress;

PShader binning;
PShader shader2;
PShader topo;
PImage img;
PGraphics pg;
PGraphics pg2;
float pupilX;
float pupilY;
float pupilX2;
float pupilY2;

// ---- OSC on UDP 9000, same as the pyramid wall ----
// Listens on every interface with address reuse, so it hears the audio
// server whether it sends to 127.0.0.1 or broadcasts to the show network
// (e.g. 10.10.10.255:9000, osc.destinations in realtime/configs/main.yaml):
//   /audio/fft  n floats, 0..1, low -> high freq   -> the outline
//   /eye/look, /eye/none from eye_yolo.py           -> the pupil (tracker.pde)
int OSC_PORT = 9000;
volatile float[] fftIn = new float[0];   // latest packet (network thread)
float[] fftSmooth = new float[0];        // smoothed, used for drawing
volatile int fftLastMs = -100000;
float fftAttack = 0.6;    // 0..1, how fast the outline jumps out
float fftRelease = 0.15;  // 0..1, how fast it falls back
float fftAmp = 90.0;      // pixels the outline pushes out at full level

// Whole eye is scaled so the outline at full peak (eye radius + fftAmp)
// always stays `frameMargin` px inside the window. Set in setup().
float EYE_RADIUS = 300.0;  // design size; everything below is relative to it
float frameMargin = 20.0;  // a little extra: the smooth curve can overshoot a point slightly
float eyeScale = 1.0;


void setup() {
  fullScreen(P2D);
  //img = loadImage("2.png");
  //shader2 = loadShader("skysetshader.glsl.txt");  // file missing; shader2 unused
  binning = loadShader("waterNoisepluswhite.glsl");
  
  pupilX = width / 2.0;
  pupilY = height / 2.0;

  pupilX2 = width / 2.0;
  pupilY2 = height / 2.0;


  topo  = loadShader("topo.glsl");

  // Colours
  setColor(topo, "paperColor", color(0.968*255, 0.498*255, 0.0*255));  // lavender
  setColor(topo, "accentColor", color(0.988*255, 0.749*255, 0.286*255));    // red
  setColor(topo, "shadowColor", color(0.945*255, 0.356*255, 0.709*255));   // yellow
  setColor(topo, "inkColor", color(0.756*255, 0.070*255, 0.121*255));     // near black

  // Contour lines
  topo.set("levels", 10.0);        // number of contour lines
  topo.set("majorEvery", 5.0);     // every 6th line is thicker, 0 = off
  topo.set("lineWidth", 1.0);      // pixels
  topo.set("misregister", 1.5, -1.0); // lines shifted vs. fill, 0,0 = aligned

  // Fill
  topo.set("accentBand", 0.57, 0.60); // height range painted accentColor
  topo.set("shadowLevel", 0.12);   // below this is shadowColor, 0 = off
  topo.set("halftoneSize", 1.0);   // dot spacing in pixels
  topo.set("halftoneAngle", 0.26); // ~15 degrees
  topo.set("inkLow", 0.1);         // low ground: half covered in dots
  topo.set("inkHigh", 0.0);        // high ground: bare paper
  topo.set("bandMix", 0.0);        // 0 = smooth, 1 = density steps per band
  topo.set("gritMix", 1.0);        // 0 = clean dots and edges


  startOscListener();
  startTracker();

  eyeScale = (min(width, height) / 2.0 - frameMargin - fftAmp) / EYE_RADIUS;

  pg = createGraphics(width, height, P2D);
  pg2 = createGraphics(width, height, P2D);
  pixelDensity(1);
}



void draw() {
  background(0);     // black; clear each frame so the moving wave doesn't smear
  updateTracker();
  updatePupil();
  updatePupil2();
  noStroke();

  binning.set("time", millis()/1000.0);
  binning.set("resolution", (float)pg.width, (float)pg.height);
  binning.set("noiseFactor", 0.5, 1.0);
  binning.set("noiseFactorTime", 0.3);
  binning.set("contastfactor", 1.5);
  //image(img, 0, 0);
 
  push();
  pg.beginDraw();
  pg.shader(binning);
  
  //pg.shader(topo);
  push();
  fill(255,255,255);
  //translate(-360,0);
  scale(1.0,1.0);
  updateFft();
  if (millis() - fftLastMs < 1000) {
    fftCircle((width / 2.0), (height / 2.0), EYE_RADIUS * eyeScale, fftAmp);
  } else {
    // no audio for a second: plain circle eye
    sineCircle((width / 2.0), (height / 2.0), EYE_RADIUS * eyeScale, 0.0, 10, millis()/1000.0);
  }
  push();
  pg.clear();
  pg.fill(255);
  pg.circle(pupilX,pupilY,270.0 * eyeScale);
  
  pop();

  pg.endDraw();
  
  pg2.beginDraw();
  pg2.clear();

  pg2.shader(topo);
  pg2.image(pg, 0, 0);

  pg2.resetShader();
  pg2.endDraw();
  pop();
 
  pop();
  

  fill(0);
  image(pg2, 0, 0);
  resetShader();
  fill(0,0,0);
  circle(pupilX2,pupilY2,120.0 * eyeScale);
}

// Outline of the eye: a circle whose radius follows a sine wave.
//   r(theta) = radius + amp * sin(waves * theta + phase)
// amp   = how far the wave pushes in/out (pixels)
// waves = number of wave peaks around the circle
// t     = time in seconds, makes the wave travel around the edge
void sineCircle(float cx, float cy, float radius, float amp, int waves, float t) {
  float speed = 1.5;
  int steps = 360;
  beginShape();
  for (int i = 0; i < steps; i++) {
    float a = TWO_PI * i / steps;
    float r = radius + amp * sin(waves * a + t * speed);
    vertex(cx + cos(a) * r, cy + sin(a) * r);
  }
  endShape(CLOSE);
}

// Outline of the eye driven by the FFT: the full spectrum once around,
// clockwise from the top (lows) back to the top (highs). The spectrum is
// averaged down to RING_POINTS, blurred around the ring (which also joins
// the seam at the top), then drawn as a smooth curve through those points.
int RING_POINTS = 48;   // fewer = rounder, broader bumps
int RING_BLUR = 2;      // blur passes around the ring; more = softer
float[] ring = new float[0];
float[] ringTmp = new float[0];
void fftCircle(float cx, float cy, float radius, float amp) {
  int n = fftSmooth.length;
  if (n < 2) return;
  int k = RING_POINTS;
  if (ring.length != k) { ring = new float[k]; ringTmp = new float[k]; }
  for (int j = 0; j < k; j++) {             // average the bins in each slice
    int b0 = j * n / k, b1 = max(b0 + 1, (j + 1) * n / k);
    float sum = 0;
    for (int b = b0; b < b1; b++) sum += fftSmooth[b];
    ring[j] = sum / (b1 - b0);
  }
  for (int p = 0; p < RING_BLUR; p++) {     // [1 4 6 4 1] blur, wrapping
    for (int j = 0; j < k; j++) {
      ringTmp[j] = (ring[(j - 2 + k) % k] + 4 * ring[(j - 1 + k) % k] + 6 * ring[j]
                  + 4 * ring[(j + 1) % k] + ring[(j + 2) % k]) / 16.0;
    }
    float[] t = ring; ring = ringTmp; ringTmp = t;
  }
  beginShape();
  for (int j = 0; j < k + 3; j++) {         // curveVertex needs the loop closed by 3 extra points
    int q = j % k;
    float a = TWO_PI * q / k;               // 0 = top, clockwise
    float r = radius + amp * ring[q];
    curveVertex(cx + sin(a) * r, cy - cos(a) * r);
  }
  endShape();
}

// Linear interpolation between bins.
float fftAt(float x) {
  int i0 = constrain(floor(x), 0, fftSmooth.length - 1);
  int i1 = min(i0 + 1, fftSmooth.length - 1);
  return lerp(fftSmooth[i0], fftSmooth[i1], x - i0);
}

void updateFft() {
  float[] in = fftIn;
  if (in.length == 0) return;
  if (fftSmooth.length != in.length) fftSmooth = new float[in.length];
  for (int i = 0; i < in.length; i++) {
    float t = constrain(in[i], 0, 1);
    float k = (t > fftSmooth[i]) ? fftAttack : fftRelease;
    fftSmooth[i] += (t - fftSmooth[i]) * k;
  }
}

// Minimal OSC receiver on a background thread: only reads "/audio/fft".
void startOscListener() {
  Thread th = new Thread(new Runnable() {
    public void run() {
      try {
        DatagramSocket sock = new DatagramSocket(null);
        sock.setReuseAddress(true);
        sock.bind(new java.net.InetSocketAddress(OSC_PORT));
        byte[] buf = new byte[65536];   // fits any OSC packet, incl. large /audio/fft
        DatagramPacket pk = new DatagramPacket(buf, buf.length);
        println("listening for OSC (/audio/fft, /eye/*) on UDP " + OSC_PORT);
        while (true) {
          pk.setLength(buf.length);     // receive() shrinks it to the last packet's size
          sock.receive(pk);
          parseOsc(buf, pk.getLength());
        }
      } catch (Exception e) {
        println("OSC listener stopped: " + e);
      }
    }
  });
  th.setDaemon(true);
  th.start();
}

void parseOsc(byte[] b, int len) {
  // address (NUL padded to 4)
  int z = 0;
  while (z < len && b[z] != 0) z++;
  String addr = new String(b, 0, z);
  boolean fft = addr.equals("/audio/fft");
  if (!fft && !addr.startsWith("/eye/")) return;
  int t = (z / 4 + 1) * 4;                       // start of ",fff..."
  if (t >= len || b[t] != ',') return;
  int e = t;
  while (e < len && b[e] != 0) e++;
  int n = e - t - 1;                             // number of 'f' tags
  int p = t + ((e - t) / 4 + 1) * 4;             // start of payload
  if (n <= 0 || p + 4 * n > len) return;
  float[] out = new float[n];
  for (int i = 0; i < n; i++) {
    int q = p + 4 * i;
    int bits = ((b[q] & 0xff) << 24) | ((b[q+1] & 0xff) << 16) | ((b[q+2] & 0xff) << 8) | (b[q+3] & 0xff);
    out[i] = Float.intBitsToFloat(bits);
  }
  if (fft) {
    fftIn = out;
    fftLastMs = millis();
  } else if (addr.equals("/eye/look") && n >= 2) {
    yoloX = out[0];
    yoloY = out[1];
    yoloSeenMs = millis();
    yoloAliveMs = millis();
  } else if (addr.equals("/eye/none")) {
    yoloAliveMs = millis();
  }
}

void updatePupil() {

  float dx = lookX - (width / 2.0);
  float dy = lookY - (height / 2.0);


  float maxX = 150 * eyeScale;
  float maxY = 150 * eyeScale;

  float nx = dx / maxX;
  float ny = dy / maxY;


  float d = sqrt(nx * nx + ny * ny);

  if (d > 1.0) {
    nx /= d;
    ny /= d;
  }

  pupilX = (width / 2.0) + nx * maxX;
  pupilY = (height / 2.0) + ny * maxY;
}

void updatePupil2() {

  float dx = lookX - (width / 2.0);
  float dy = lookY - (height / 2.0);


  float maxX = 200 * eyeScale;
  float maxY = 200 * eyeScale;

  float nx = dx / maxX;
  float ny = dy / maxY;


  float d = sqrt(nx * nx + ny * ny);

  if (d > 1.0) {
    nx /= d;
    ny /= d;
  }

  pupilX2 = (width / 2.0) + nx * maxX;
  pupilY2 = (height / 2.0) + ny * maxY;
}
  

void setColor(PShader s, String name, color c) {
  s.set(name, red(c)/255.0, green(c)/255.0 , blue(c)/255.0);
}

// M.E.A.T. logo, bottom-left, white, from the vector file
// (data/meat_logo.svg, copied from ~/Downloads/meatlogo-white.svg).
// Rendered once into an offscreen image at exactly its on-screen size so
// it's sharp, then just drawn each frame.
PGraphics meatLogo;
float LOGO_WIDTH = 0.28;    // fraction of the screen width
float LOGO_MARGIN = 0.03;   // fraction of the screen height

void loadLogo() {
  PShape svg = loadShape("meat_logo.svg");
  if (svg == null) return;
  int w = round(width * LOGO_WIDTH);
  int h = round(w * svg.height / svg.width);
  meatLogo = createGraphics(w, h, JAVA2D);   // Java2D: accurate, antialiased curves
  meatLogo.beginDraw();
  meatLogo.clear();
  svg.disableStyle();                         // ignore the file's colours
  meatLogo.fill(255);
  meatLogo.noStroke();
  meatLogo.shape(svg, 0, 0, w, h);
  meatLogo.endDraw();
}

void drawLogo() {
  if (meatLogo == null) return;
  float m = height * LOGO_MARGIN;
  resetShader();
  image(meatLogo, round(m), round(height - m - meatLogo.height));
}
