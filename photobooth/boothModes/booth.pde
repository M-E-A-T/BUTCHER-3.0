// booth.pde: the photobooth sequence from ../photobooth, on top of whichever mode is live.
//   Squeeze the trigger all the way: 5-4-3-2-1 countdown (flash + controller buzz on each
//   number), then a 3 second GIF of the mode on screen is recorded and saved to photos/
//   (ffmpeg, kept under 5 MB). The GIF plays back:
//     MOVE    = redo (straight into a new countdown)
//     trigger = confirm (once saved) -> QR code screen; trigger there = back to live.
//   Square / triangle / cross / circle pick the mode, on the live screen only.

import com.google.zxing.*;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import java.util.*;

// --- controller (via ../move_bridge.py) ---
Process bridge;
PrintWriter toBridge;
volatile String held = "-";
volatile float trig = 0;
volatile String status = "starting bridge...";
volatile boolean connected = false;
volatile int flashAt = -100000;
volatile boolean flashArmed = true;
volatile boolean wantShoot = false;
volatile boolean wantRedo = false;  // MOVE pressed (redo during playback)
volatile int requestedMode = -1;    // set by a shape button, applied in draw()
boolean moveWasHeld = false;
String lastHeld = "-";
volatile String battery = "";       // "0".."5", "CHARGING", "CHARGED" or "" (unknown)
int modeShownAt = -100000;          // millis() of the last mode switch (name shown briefly)

// --- GIF ---
final int COUNTDOWN = 5;          // seconds
final float REC_SECONDS = 3;
final int GIF_FPS = 15;
final int GRAB_W = 1280;          // frames are grabbed from the screen and scaled to this width
final long GIF_MAX_BYTES = 5L * 1024 * 1024;
final int[] GIF_WIDTHS = { 640, 512, 400 };  // tried in order until the file fits
volatile int phase = 0;           // 0 live, 1 countdown, 2 recording, 3 playback, 4 QR code
int phaseStart = 0;
int framesTaken = 0;
ArrayList<PImage> gifFrames = new ArrayList<PImage>();
ArrayList<PImage> playFrames = new ArrayList<PImage>();
int lastCount = -1;
int countFlashAt = -100000;
PFont bigFont, uiFont;
// --- sharing (placeholder) ---
final String SHARE_BASE_URL = "https://example.com/gif/";   // TODO: real hosting
volatile boolean gifReady = false;
volatile boolean gifFailed = false;
volatile int encodeGen = 0;
volatile String lastGifName = "";
PImage qr;
volatile String note = "";
volatile int noteAt = -100000;

void boothSetup() {
  noCursor();
  uiFont = createFont("SansSerif", 32, true);
  bigFont = createFont("NotoSans-Bold.ttf", round(height * 0.62), true);
  startBridge();
}

// ---------------- controller ----------------

void startBridge() {
  try {
    File script = new File(sketchPath(), "../move_bridge.py").getCanonicalFile();
    ProcessBuilder pb = new ProcessBuilder("python3", "-u", script.getPath());
    pb.redirectErrorStream(true);
    bridge = pb.start();
    toBridge = new PrintWriter(bridge.getOutputStream(), true);
    final BufferedReader in = new BufferedReader(new InputStreamReader(bridge.getInputStream()));
    Thread t = new Thread(new Runnable() { public void run() {
      try {
        String line;
        while ((line = in.readLine()) != null) handle(line.trim());
        status = "bridge exited";
        connected = false;
      } catch (IOException e) { status = "bridge error: " + e.getMessage(); }
    }});
    t.setDaemon(true);
    t.start();
    Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() { public void run() { stopBridge(); }}));
  } catch (IOException e) {
    status = "could not start move_bridge.py: " + e.getMessage();
  }
}

void handle(String line) {
  String[] p = split(line, ' ');
  if (p[0].equals("READY")) status = "waiting for controller - press the PS button";
  else if (p[0].equals("CONNECTED")) { connected = true; status = "connected via " + (p.length > 1 && p[1].equals("bt") ? "Bluetooth" : "USB"); }
  else if (p[0].equals("DISCONNECTED")) { connected = false; held = "-"; lastHeld = "-"; trig = 0; battery = ""; status = "controller disconnected"; }
  else if (p[0].equals("BATTERY") && p.length >= 2) battery = p[1];
  else if (p[0].equals("STATE") && p.length >= 3) {
    held = p[1]; trig = float(p[2]);
    List<String> now = Arrays.asList(split(held, ','));
    List<String> before = Arrays.asList(split(lastHeld, ','));
    for (String b : now) {
      if (before.contains(b)) continue;          // only on the press
      int m = buttonMode(b);
      if (m >= 0 && phase == 0) requestedMode = m;
    }
    lastHeld = held;
    boolean moveHeld = now.contains("MOVE");
    if (moveHeld && !moveWasHeld) wantRedo = true;
    moveWasHeld = moveHeld;
    // same thresholds as move_bridge.py: fire at 0.9, re-arm below 0.3
    if (flashArmed && trig >= 0.9) { flashArmed = false; wantShoot = true; }
    else if (trig < 0.3) flashArmed = true;
  }
  else println("bridge: " + line);
}

int buttonMode(String b) {
  if (b.equals("SQUARE"))   return 2;   // thermal
  if (b.equals("TRIANGLE")) return 3;   // fft
  if (b.equals("CROSS"))    return 1;   // pixelz
  if (b.equals("CIRCLE"))   return 0;   // organism
  return -1;
}

void sendBridge(String cmd) {
  if (toBridge != null) toBridge.println(cmd);
}

void stopBridge() {
  if (bridge != null && bridge.isAlive()) bridge.destroy();
}

// ---------------- per frame ----------------

// Called at the end of draw(), after the mode drew: grab first (so the GIF has no overlays).
void boothDraw() {
  boolean haveFrame = cam != null && cam.width > 0;
  updateShoot(haveFrame);
  pushStyle();
  textFont(uiFont);
  textAlign(CENTER, CENTER);
  rectMode(CORNER);
  imageMode(CORNER);

  if (phase == 0) {
    // mode name for a moment after a switch, and the connection status until connected
    int t = millis() - modeShownAt;
    if (t < 1500) {
      float a = 255 * constrain((1500 - t) / 400.0, 0, 1);
      String m = MODE_NAMES[current];
      float bw = textWidthFor(m, 40) + 60;
      noStroke();
      fill(0, 140 * a / 255);
      rectMode(CENTER);
      rect(width/2, height * 0.12, bw, 70, 14);
      fill(255, a);
      text(m, width/2, height * 0.12);
      rectMode(CORNER);
    }
    if (!connected) {
      fill(255, 200);
      textSize(height * 0.04);
      text(status, width/2, height * 0.85);
    }
  }
  drawBattery();
  drawShootOverlay();

  if (millis() - noteAt < 4000) {
    fill(0, 140);
    rectMode(CENTER);
    rect(width/2, height * 0.9, textWidthFor(note, 28) + 40, 50, 12);
    fill(255);
    textSize(28);
    text(note, width/2, height * 0.9);
    rectMode(CORNER);
  }
  drawFlash();
  popStyle();
}

// battery icon at the top right; big warning when nearly empty
void drawBattery() {
  if (!connected || battery.equals("")) return;
  boolean charging = battery.equals("CHARGING"), charged = battery.equals("CHARGED");
  int level = charging || charged ? 5 : int(battery);
  color c = charging || charged ? color(60, 220, 100)
          : level <= 1 ? color(240, 60, 60)
          : level == 2 ? color(240, 200, 60) : color(60, 220, 100);
  float x = width - 110, y = 10, w = 50, h = 20;
  noFill();
  stroke(220);
  strokeWeight(2);
  rectMode(CORNER);
  rect(x, y, w, h, 3);
  noStroke();
  fill(220);
  rect(x + w + 2, y + 6, 4, h - 12, 1);
  fill(c);
  boolean blink = level <= 1 && !charging && (millis() / 400) % 2 == 0;
  int segs = max(level, 1);
  if (!blink) for (int i = 0; i < segs; i++) rect(x + 3 + i * (w - 6) / 5.0, y + 3, (w - 6) / 5.0 - 2, h - 6);
  fill(220);
  textSize(16);
  textAlign(LEFT, CENTER);
  String label = charging ? "chg" : charged ? "full" : level == 0 ? "<20%" : (level * 20) + "%";
  text(label, x + w + 10, y + h / 2.0);
  textAlign(CENTER, CENTER);
  if (level <= 1 && !charging && !charged) {
    String msg = level == 0 ? "controller battery almost empty - plug it in" : "controller battery low";
    float bw = textWidthFor(msg, 24) + 40;
    fill(240, 60, 60, 200);
    rect(width/2 - bw/2, 50, bw, 44, 10);
    fill(255);
    text(msg, width/2, 71);
  }
}

float textWidthFor(String t, float size) { textSize(size); return textWidth(t); }

// ---------------- GIF capture ----------------

void updateShoot(boolean haveFrame) {
  int t = millis() - phaseStart;
  if (phase != 3) wantRedo = false;        // MOVE only means "redo" during playback
  if (phase == 0 && wantShoot) {
    wantShoot = false;
    if (haveFrame) startCountdown();
  } else if (phase == 1) {
    wantShoot = false;
    int n = COUNTDOWN - t / 1000;
    if (n != lastCount && n >= 1) {
      lastCount = n;
      countFlashAt = millis();
      sendBridge("PULSE 180");
    }
    if (t >= COUNTDOWN * 1000) {
      phase = 2; phaseStart = millis(); framesTaken = 0;
      gifFrames.clear();
      flashAt = millis();
      sendBridge("PULSE 400");
    }
  } else if (phase == 2) {
    wantShoot = false;
    // grab the screen (the mode as drawn, before any overlay) every 1/GIF_FPS seconds
    int due = min(int(t * GIF_FPS / 1000.0) + 1, int(REC_SECONDS * GIF_FPS));
    if (framesTaken < due) {
      PImage f = get(0, 0, width, height);
      if (f.width > GRAB_W) f.resize(GRAB_W, 0);
      gifFrames.add(f);
      framesTaken++;
    }
    if (framesTaken >= int(REC_SECONDS * GIF_FPS)) {
      playFrames = new ArrayList<PImage>(gifFrames);
      encodeGif(playFrames);
      gifFrames = new ArrayList<PImage>();
      phase = 3; phaseStart = millis();
      sendBridge("QUIET 0");
    }
  } else if (phase == 3 && wantRedo) {
    wantRedo = false;
    wantShoot = false;
    playFrames = new ArrayList<PImage>();
    startCountdown();
  } else if (phase == 3 && wantShoot) {
    wantShoot = false;
    if (gifFailed) {
      phase = 0;
      playFrames = new ArrayList<PImage>();
    } else if (gifReady) {
      qr = makeQr(SHARE_BASE_URL + lastGifName + ".gif", round(min(height * 0.55, 600)));
      phase = 4; phaseStart = millis();
      sendBridge("PULSE 150");
    }
  } else if (phase == 4) {
    wantRedo = false;
    if (wantShoot) {
      wantShoot = false;
      phase = 0;
      playFrames = new ArrayList<PImage>();
      qr = null;
    }
  }
}

void startCountdown() {
  phase = 1; phaseStart = millis(); lastCount = -1;
  requestedMode = -1;
  if (panel != null) panel.setVisible(false);   // organism's Controls window must not end up in the GIF
  sendBridge("QUIET 1");
}

void drawShootOverlay() {
  int t = millis() - phaseStart;
  if (phase == 1) {
    int ft = millis() - countFlashAt;
    if (ft < 350) {
      noStroke();
      fill(255, 255, 250, 200 * pow(1 - ft / 350.0, 2));
      rectMode(CORNER);
      rect(0, 0, width, height);
    }
    int n = max(1, COUNTDOWN - t / 1000);
    float f = (t % 1000) / 1000.0;
    float sz = bigFont.getSize() * (1 - 0.12 * f);
    textFont(bigFont);
    textSize(sz);
    textAlign(CENTER, CENTER);
    fill(0, 90);
    text(n, width/2 + sz * 0.02, height/2 + sz * 0.02 - sz * 0.08);
    fill(255);
    text(n, width/2, height/2 - sz * 0.08);
    textFont(uiFont);
  } else if (phase == 2) {
    float p = constrain(t / (REC_SECONDS * 1000), 0, 1);
    noStroke();
    fill(60, 220, 100);
    rectMode(CORNER);
    rect(0, height - 12, width * p, 12);
  } else if (phase == 3) {
    String hint = gifReady ? "trigger: get your GIF     MOVE: redo"
                : gifFailed ? "couldn't save - trigger: start over     MOVE: redo" : "saving...     MOVE: redo";
    float bw = textWidthFor(hint, 26) + 40;
    noStroke();
    fill(0, 140);
    rectMode(CENTER);
    rect(width/2, 80, bw, 46, 12);
    fill(255);
    text(hint, width/2, 80);
    rectMode(CORNER);
  } else if (phase == 4) {
    drawQrScreen();
  }
}

// loop the recorded frames full screen, exactly as the mode looked
void drawPlayback() {
  if (playFrames.isEmpty()) return;
  int i = ((millis() - phaseStart) * GIF_FPS / 1000) % playFrames.size();
  PImage f = playFrames.get(i);
  float sc = max((float) width / f.width, (float) height / f.height);
  imageMode(CENTER);
  image(f, width/2, height/2, f.width * sc, f.height * sc);
  imageMode(CORNER);
}

// Encode in the background: frames piped raw into ffmpeg; the biggest width under 5 MB is kept.
void encodeGif(final ArrayList<PImage> frames) {
  final String name = "gif-" + year() + nf(month(), 2) + nf(day(), 2) + "-" + nf(hour(), 2) + nf(minute(), 2) + nf(second(), 2);
  note = "saving gif...";
  noteAt = millis() + 600000;
  gifReady = false;
  gifFailed = false;
  final int gen = ++encodeGen;
  Thread th = new Thread(new Runnable() { public void run() {
    long t0 = System.currentTimeMillis();
    final File dir = new File(sketchPath("photos"));
    File out = new File(dir, name + ".gif");
    try {
      dir.mkdirs();
      for (PImage f : frames) f.loadPixels();
      int n = GIF_WIDTHS.length - 1;
      final File[] parts = new File[GIF_WIDTHS.length];
      final Exception[] errs = new Exception[GIF_WIDTHS.length];
      Thread[] ts = new Thread[n];
      for (int i = 0; i < n; i++) {
        final int k = i;
        parts[k] = new File(dir, "." + name + "-" + GIF_WIDTHS[k] + ".gif");
        ts[k] = new Thread(new Runnable() { public void run() {
          try { encodeWidth(frames, GIF_WIDTHS[k], parts[k]); } catch (Exception e) { errs[k] = e; }
        }});
        ts[k].start();
      }
      for (Thread t : ts) t.join();
      File best = null;
      for (int i = 0; i < n; i++) {
        if (errs[i] != null) throw errs[i];
        println("gif " + name + " at " + GIF_WIDTHS[i] + "px: " + parts[i].length() / 1024 + " KB");
        if (best == null && parts[i].length() <= GIF_MAX_BYTES) best = parts[i];
      }
      if (best == null) {
        parts[n] = new File(dir, "." + name + "-" + GIF_WIDTHS[n] + ".gif");
        encodeWidth(frames, GIF_WIDTHS[n], parts[n]);
        println("gif " + name + " at " + GIF_WIDTHS[n] + "px: " + parts[n].length() / 1024 + " KB");
        best = parts[n];
      }
      best.renameTo(out);
      for (File f : parts) if (f != null && f.exists()) f.delete();
      println("gif saved in " + (System.currentTimeMillis() - t0) + " ms");
      note = "saved " + out.getName() + " (" + nf(out.length() / 1048576.0, 1, 1) + " MB)" + (out.length() <= GIF_MAX_BYTES ? "" : " - over 5 MB");
      if (gen == encodeGen) { lastGifName = name; gifReady = true; }
    } catch (Exception e) {
      note = "gif failed: " + e.getMessage();
      println(note);
      if (gen == encodeGen) gifFailed = true;
    } finally {
      noteAt = millis();
    }
  }});
  th.setDaemon(false);
  th.start();
}

void encodeWidth(ArrayList<PImage> frames, int w, File out) throws Exception {
  int fw = frames.get(0).width, fh = frames.get(0).height;
  String vf = "scale=" + w + ":-2:flags=lanczos,split[a][b];" +
              "[a]scale=320:-2,select='not(mod(n\\,3))',palettegen=stats_mode=full[p];" +
              "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle";
  ProcessBuilder pb = new ProcessBuilder("ffmpeg", "-y", "-loglevel", "error",
    "-f", "rawvideo", "-pix_fmt", "0rgb", "-s", fw + "x" + fh, "-framerate", str(GIF_FPS), "-i", "-",
    "-vf", vf, "-loop", "0", "-f", "gif", out.getPath());
  pb.redirectErrorStream(true);
  pb.redirectOutput(ProcessBuilder.Redirect.DISCARD);
  Process pr = pb.start();
  byte[] buf = new byte[fw * fh * 4];
  OutputStream os = new BufferedOutputStream(pr.getOutputStream(), 1 << 20);
  for (PImage f : frames) {
    java.nio.ByteBuffer.wrap(buf).asIntBuffer().put(f.pixels);
    os.write(buf);
  }
  os.close();
  if (pr.waitFor() != 0) throw new IOException("ffmpeg exited with " + pr.exitValue() + " at " + w + "px");
}

PImage makeQr(String text, int size) {
  try {
    Map<EncodeHintType, Object> hints = new HashMap<EncodeHintType, Object>();
    hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);
    hints.put(EncodeHintType.MARGIN, 2);
    BitMatrix m = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints);
    PImage img = createImage(m.getWidth(), m.getHeight(), RGB);
    img.loadPixels();
    for (int y = 0; y < m.getHeight(); y++)
      for (int x = 0; x < m.getWidth(); x++)
        img.pixels[y * m.getWidth() + x] = m.get(x, y) ? color(0) : color(255);
    img.updatePixels();
    return img;
  } catch (Exception e) {
    println("qr failed: " + e.getMessage());
    return null;
  }
}

void drawQrScreen() {
  noStroke();
  fill(0, 170);
  rectMode(CORNER);
  rect(0, 0, width, height);
  float qs = min(height * 0.55, 600);
  float cw = qs + 80, ch = qs + 190;
  float cx = width/2, cy = height/2;
  fill(255);
  rectMode(CENTER);
  rect(cx, cy, cw, ch, 28);
  fill(20);
  textSize(34);
  text("scan to get your GIF", cx, cy - ch/2 + 50);
  if (qr != null) {
    imageMode(CENTER);
    image(qr, round(cx), round(cy + 5));
    imageMode(CORNER);
  }
  fill(120);
  textSize(18);
  text(SHARE_BASE_URL + lastGifName + ".gif", cx, cy + ch/2 - 52);
  fill(255);
  textSize(26);
  text("squeeze the trigger when you're done", cx, cy + ch/2 + 40);
  rectMode(CORNER);
}

void drawFlash() {
  int t = millis() - flashAt;
  if (t > 700) return;
  float a = t < 60 ? 255 : 255 * pow(1 - (t - 60) / 640.0, 2.5);
  noStroke();
  fill(255, 255, 250, a);
  rectMode(CORNER);
  rect(0, 0, width, height);
}
