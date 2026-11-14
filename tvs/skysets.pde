/**
 * skysets.pde — masked effects slideshow for Processing 4 (Java mode).
 *
 * Pairing: img_raw/name.jpg + img_mask/name.png
 * White mask pixels (brightness >= 128) are zone A; black pixels are zone B.
 *
 * Keyboard controls:
 * 1–6       Select titlecard text
 * `         Toggle titlecards on/off (on at startup)
 * N         Next slide
 * SPACE     Pause/resume contour animation
 * D         Toggle uphill/downhill contour movement
 * UP/DOWN   Change contour movement speed
 * +/-       Change contour count
 * R         Reset contour animation
 * C         Choose a new sunset contour gradient
 * ESC       Exit
 */

import java.io.File;
import java.awt.BasicStroke;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Shape;
import java.awt.font.GlyphVector;
import java.awt.geom.AffineTransform;
import java.awt.geom.Path2D;
import java.awt.geom.Area;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;
import processing.awt.PGraphicsJava2D;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;

// ------------------------------------------------------------------
// SETTINGS
// ------------------------------------------------------------------

int slideMs = 20000;
final int FILTER_PICK_MS = 10000;
final int FILTER_SHOW_MS = 20000;
//final int TITLE_ROTATE_MS = 5000;
int titlecardVisibleMs = 60000;
int titlecardHiddenMs = 0;       // 0 = titlecard always visible
final int RAMP_SIZE = 1024;

final color[] SUNSET_PALETTE = {
  #9D0208, #D00000, #E85D04, #F48C06,
  #FFBA08, #F9844A, #F15BB5, #FF6B6B
};

final String[] titlecardNames = {
  "TATSMIXES", "IVY", "SUNSCRN", "GRILLMASTER", "KINGKILO", "HIMMA"
};

ArrayList<Slide> slides = new ArrayList<Slide>();
ArrayList<RunningFilter> runningFilters = new ArrayList<RunningFilter>();

int slideIndex = 0;
int slideStarted = 0;
int lastFilterPick = 0;
//int lastTitleRotate = 0;

// Which zone shows the plain photo; the effect is masked into the other one.
// true = photo in the lower zone (A), effect in the upper zone (B).
boolean photoInA = true;
boolean titlecardsEnabled = true;
int titlecardSelection = 1;
PFont titleFont;

boolean filtersEnabled = true;
// Manual by default: nothing switches on its own. Auto restores timed switching.
boolean autoMode = false;
int manualFilterChoice = 0; // 0 = none, 1 = posterize, 2 = scanlines, 3 = thermal
VisualFilter manualFilter = null;
final String[] FILTER_NAMES = { "None", "Posterize", "Scanlines", "Thermal" };
// One effect, masked into whichever zone is not showing the plain photo.
// 0 = random (one of the three, re-picked each slide).
int effectChoice = 2; // Contours
final String[] EFFECT_NAMES = { "Random", "Signal Glitch", "Contours", "Kaleido Geometry" };
final int[] EFFECT_IDS = { 5, 3, 6 }; // randomEffect() indices for the names above

// Requests from the keyboard, applied in draw().
volatile boolean requestNextSlide = false;
volatile boolean requestResetContours = false;
volatile boolean requestNewColors = false;

//boolean titlecardsEnabled = false;
//int titlecardSelection = 1;
int titlecardCycleStarted = 0;
boolean titlecardVisible = false;

// Everything except the titlecard and kaleido is rendered at 1/RS of the
// screen size into one reusable frame, then scaled up once per frame.
// The show laptops (AMD A6-1450) can't push full-resolution pixel work.
final int RS = 2;
int W, H;            // render size
PImage frame;        // reused every frame
BufferedImage frameImg;
Graphics2D frameG;

PGraphics upperVisual, lowerVisual;

SkyEffect effectA, effectB;

// Mask-derived visual boundaries.
// The upper visual ends at the lowest B/black pixel.
// The lower visual begins at the highest A/white pixel.
int upperVisualBottom = 1;
int lowerVisualTop = 0;

// Contour settings and state.
float minElevation = 0.0;
float elevationDelta = 5.0;
int contourSteps = 15;
float secondsPerStep = 4.0;
boolean uphill = true;
boolean contoursPaused = false;
float contourAnimationOffset = 0;
float contourPreviousTime = 0;

color minContourColor, maxContourColor;
color[] contourColorRamp = new color[RAMP_SIZE];

// ------------------------------------------------------------------
// PROCESSING LIFECYCLE
// ------------------------------------------------------------------

void settings() {
  //size(1280, 720); //test
  //size(1920, 1080); //prod
  fullScreen(); // fit current display
  pixelDensity(1);
}

void setup() {
  surface.setTitle("skysets");
  frameRate(60);

  // Same noise seed on every screen, so the contour terrain is identical.
  noiseSeed(20261114);

  W = max(1, width / RS);
  H = max(1, height / RS);
  frame = createImage(W, H, RGB);
  // Back the frame with a BufferedImage so Java2D can draw kaleido into it.
  frameImg = new BufferedImage(W, H, BufferedImage.TYPE_INT_RGB);
  frame.pixels = ((DataBufferInt) frameImg.getRaster().getDataBuffer()).getData();
  frameG = frameImg.createGraphics();
  frameG.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);

  loadSlides();
  if (slides.size() == 0) {
    println("No matching image/mask pairs. Add JPGs to img_raw and matching PNGs to img_mask.");
    exit();
    return;
  }

  // Arial Bold from its font file on the Mac; on the Linux laptops (no Arial)
  // Liberation Sans Bold, which has the same letter widths as Arial.
  String[] titleFontFiles = {
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
  };
  String titleFontSource = "Arial Bold";
  for (String f : titleFontFiles) {
    if (new File(f).exists()) { titleFontSource = f; break; }
  }
  titleFont = createFont(titleFontSource, 48, true);

  startOnsetListener();
  startSync();
  rollFilterOnsetTarget();
  startSlide(0);
  lastFilterPick = millis();
  //lastTitleRotate = millis();
  contourPreviousTime = millis() / 1000.0;
  chooseSunsetColors();
  if (autoMode) pickFilter();
  titlecardCycleStarted = millis();
}

// Applies requests coming from the keyboard.
void applyKeyRequests() {
  if (requestNextSlide) {
    requestNextSlide = false;
    startSlide((slideIndex + 1) % slides.size());
  }
  if (requestResetContours) {
    requestResetContours = false;
    contourAnimationOffset = 0;
  }
  if (requestNewColors) {
    requestNewColors = false;
    chooseSunsetColors();
  }
}

void setTitlecardsEnabled(boolean on) {
  titlecardsEnabled = on;
  if (on) {
    titlecardCycleStarted = millis();
    titlecardVisible = true;
  } else {
    titlecardVisible = false;
  }
  println("Titlecards: " + (on ? "ON" : "OFF"));
}

void draw() {
  if (slides.size() == 0) return;

  int now = millis();

  applyKeyRequests();
  applyTitleRequest();

  // Titlecard visibility cycle.
  if (titlecardsEnabled) {
    if (titlecardHiddenMs <= 0) {
      titlecardVisible = true;
    } else {
      int cycleDuration = titlecardVisibleMs + titlecardHiddenMs;
      int elapsed = (now - titlecardCycleStarted) % cycleDuration;
      titlecardVisible = elapsed < titlecardVisibleMs;
    }
  } else {
    titlecardVisible = false;
  }

  // Followers take every decision from the leader (sync.pde) instead.
  boolean deciding = !following();
  if (deciding && autoMode && now - slideStarted >= slideMs) {
    startSlide((slideIndex + 1) % slides.size());
  }

  if (deciding) {
    updateOnsetSwap();
    updateOnsetFilter();
    updateOnsetSlide();
  }

  if (!filtersEnabled || !autoMode || onsetFilters || !deciding) {
    runningFilters.clear();
    lastFilterPick = now;
  } else if (now - lastFilterPick >= FILTER_PICK_MS) {
    pickFilter();
    lastFilterPick = now;
  }

  //if (titlecardsEnabled && now - lastTitleRotate >= TITLE_ROTATE_MS) {
  //  titlecardSelection = (titlecardSelection % titlecardNames.length) + 1;
  //  lastTitleRotate = now;
  //}

  expireFilters(now);
  updateContourClock();
  applySync();   // follower: the leader's state wins
  long t0 = System.nanoTime();
  composeFrame();
  long t1 = System.nanoTime();

  for (int i = 0; i < runningFilters.size(); i++) {
    runningFilters.get(i).filter.apply(frame);
  }
  if ((!autoMode || onsetFilters) && filtersEnabled && manualFilter != null) manualFilter.apply(frame);

  long t2 = System.nanoTime();
  boolean fast = presentFrame();   // upscale + titlecard, straight to the screen
  long t3 = System.nanoTime();
  if (!fast) {
    drawKaleidoFront();
    drawTitlecardOverlay();
  }
  long t4 = System.nanoTime();
  profCompose += t1 - t0; profFilter += t2 - t1; profUpscale += t3 - t2; profTitle += t4 - t3;
  profFrames++;
  sendSync();    // leader: share this frame's state
  logFps(now);
}

// ------------------------------------------------------------------
// PRESENTING THE FRAME
// Java2D's own image scaling costs ~100 ms a frame on the show laptops, and
// its DIFFERENCE blend ~17 ms. Instead: a 2x bilinear upscale in plain integer
// math into a screen-size buffer, the titlecard inverted into it (what
// DIFFERENCE with white does), then one unscaled blit.
// ------------------------------------------------------------------

BufferedImage screenImg;
int[] screenPx;

boolean presentFrame() {
  if (RS != 2 || !(g instanceof PGraphicsJava2D)) {
    image(frame, 0, 0, width, height);
    return false;
  }
  if (screenImg == null) {
    screenImg = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
    screenPx = ((DataBufferInt) screenImg.getRaster().getDataBuffer()).getData();
  }
  boolean title = titlecardsEnabled && titlecardVisible;
  if (title && !currentTitlecardName().equals(titleMaskName)) buildTitleMask(currentTitlecardName());
  if (kaleidoInFront()) {
    // Kaleido at render size, over the filtered frame but not over the
    // titlecard: keep the letter pixels, draw the rings, put them back.
    int[] fp = frame.pixels;
    if (title) for (int j = 0; j < titleIdxLo.length; j++) titleSavedLo[j] = fp[titleIdxLo[j]];
    ((KaleidoGeometryEffect) effectA).drawShapeJ2D(frameG, W * 5.0 / 6.0, H * 0.5,
      kaleidoRadius() / RS, showTime(), 1.0 / RS);
    if (title) for (int j = 0; j < titleIdxLo.length; j++) fp[titleIdxLo[j]] = titleSavedLo[j];
  }
  upscale2x(frame.pixels, W, H, screenPx, width, height);
  if (title) invertTitle(screenPx);
  ((PGraphicsJava2D) g).g2.drawImage(screenImg, 0, 0, null);
  return true;
}

int avg2(int a, int b) {
  return ((a & 0xFEFEFE) >> 1) + ((b & 0xFEFEFE) >> 1);
}

void upscale2x(int[] src, int sw, int sh, int[] dst, int dw, int dh) {
  for (int y = 0; y < sh; y++) {
    int r0 = y * sw;
    int r1 = min(y + 1, sh - 1) * sw;
    int dy = 2 * y;
    int d0 = dy * dw;
    int d1 = (dy + 1) * dw;
    boolean row2 = dy + 1 < dh;
    for (int x = 0; x < sw; x++) {
      int x1 = min(x + 1, sw - 1);
      int a = src[r0 + x], b = src[r0 + x1];
      int c = src[r1 + x], d = src[r1 + x1];
      int dx = 2 * x;
      int ab = avg2(a, b);
      dst[d0 + dx] = a;
      if (dx + 1 < dw) dst[d0 + dx + 1] = ab;
      if (row2) {
        int ac = avg2(a, c);
        dst[d1 + dx] = ac;
        if (dx + 1 < dw) dst[d1 + dx + 1] = avg2(ab, avg2(c, d));
      }
    }
  }
  // Odd screen sizes: repeat the last column / row.
  if (dw > 2 * sw) for (int y = 0; y < dh; y++) dst[y * dw + dw - 1] = dst[y * dw + dw - 2];
  if (dh > 2 * sh) System.arraycopy(dst, (dh - 2) * dw, dst, (dh - 1) * dw, dw);
}

// Titlecard letter coverage at screen size, cached per name.
int[] titleIdx, titleCov;
int[] titleIdxLo, titleSavedLo;   // letter pixels at render size (kaleido stays out)
String titleMaskName = null;

void invertTitle(int[] px) {
  String name = currentTitlecardName();
  if (!name.equals(titleMaskName)) buildTitleMask(name);
  for (int j = 0; j < titleIdx.length; j++) {
    int i = titleIdx[j], k = titleCov[j];
    int c = px[i];
    int r = (c >> 16) & 0xFF, gg = (c >> 8) & 0xFF, b = c & 0xFF;
    r += k * (255 - 2 * r) / 255;
    gg += k * (255 - 2 * gg) / 255;
    b += k * (255 - 2 * b) / 255;
    px[i] = (r << 16) | (gg << 8) | b;
  }
}

void buildTitleMask(String name) {
  PGraphics t = createGraphics(width, height);
  t.beginDraw();
  t.background(0);
  t.textFont(titleFont);
  t.textAlign(CENTER, CENTER);
  t.textSize(titlecardTextSize(t, name));
  t.fill(255);
  t.noStroke();
  t.text(name, width / 2, height / 2);
  t.endDraw();
  t.loadPixels();
  int n = 0;
  for (int i = 0; i < t.pixels.length; i++) if ((t.pixels[i] & 0xFF) > 0) n++;
  titleIdx = new int[n];
  titleCov = new int[n];
  n = 0;
  for (int i = 0; i < t.pixels.length; i++) {
    int k = t.pixels[i] & 0xFF;
    if (k > 0) { titleIdx[n] = i; titleCov[n] = k; n++; }
  }
  boolean[] lo = new boolean[W * H];
  int m = 0;
  for (int j = 0; j < n; j++) {
    int x = min(titleIdx[j] % width / RS, W - 1), y = min(titleIdx[j] / width / RS, H - 1);
    int li = y * W + x;
    if (!lo[li]) { lo[li] = true; m++; }
  }
  titleIdxLo = new int[m];
  titleSavedLo = new int[m];
  m = 0;
  for (int i = 0; i < lo.length; i++) if (lo[i]) titleIdxLo[m++] = i;
  titleMaskName = name;
}

// Prints the frame rate and current effect/filter every 5 s (for tuning).
int lastFpsLog = 0;
long profCompose, profFilter, profUpscale, profTitle;
int profFrames;
void logFps(int now) {
  if (now - lastFpsLog < 5000) return;
  lastFpsLog = now;
  float n = max(1, profFrames) * 1e6;
  println("fps " + nf(frameRate, 0, 1)
    + " | " + (syncLeader ? "leader" : following() ? "follower" : "alone")
    + " | slide " + (slideIndex + 1) + " zone " + (photoInA ? "B" : "A")
    + " contour " + nf(contourAnimationOffset, 0, 2) + "/" + contourSteps
    + " | effect " + effectA.getName()
    + " | filter " + FILTER_NAMES[manualFilterChoice] + " | title " + titlecardVisible
    + " | ms compose " + nf(profCompose / n, 0, 1) + " filter " + nf(profFilter / n, 0, 1)
    + " present " + nf(profUpscale / n, 0, 1) + " kaleido " + nf(profTitle / n, 0, 1));
  profCompose = profFilter = profUpscale = profTitle = 0;
  profFrames = 0;
}

// ------------------------------------------------------------------
// SLIDE AND MASK LOADING
// ------------------------------------------------------------------

void loadSlides() {
  File rawDir = new File(sketchPath("img_raw"));
  File maskDir = new File(sketchPath("img_mask"));

  File[] files = rawDir.listFiles();
  if (files == null) return;

  ArrayList<File> ordered = new ArrayList<File>();
  for (File f : files) {
    if (f.isFile() && isImage(f.getName())) ordered.add(f);
  }

  Collections.sort(ordered, new Comparator<File>() {
    public int compare(File a, File b) {
      return a.getName().compareToIgnoreCase(b.getName());
    }
  });

  for (File raw : ordered) {
    String stem = stem(raw.getName());
    File maskFile = new File(maskDir, stem + ".png");

    if (!maskFile.exists()) {
      println("Skipping " + raw.getName() + " (no " + maskFile.getName() + ")");
      continue;
    }

    PImage img = loadImage(raw.getAbsolutePath());
    PImage msk = loadImage(maskFile.getAbsolutePath());

    if (img != null && msk != null) {
      slides.add(new Slide(img, msk, stem));
    }
    img = null;
    msk = null;
  }
}

boolean isImage(String n) {
  String s = n.toLowerCase();
  return s.endsWith(".jpg") || s.endsWith(".jpeg") || s.endsWith(".png");
}

String stem(String n) {
  int p = n.lastIndexOf('.');
  return p < 0 ? n : n.substring(0, p);
}

void startSlide(int next) {
  slideIndex = next;
  slideStarted = millis();
  if (autoMode) photoInA = random(1) < 0.5;

  Slide sl = slides.get(slideIndex);
  lowerVisualTop = sl.lowerTop;
  upperVisualBottom = sl.upperBottom;

  int upperH = max(1, upperVisualBottom);
  int lowerH = max(1, H - lowerVisualTop);

  upperVisual = createGraphics(W, upperH);
  lowerVisual = createGraphics(W, lowerH);

  makeEffects();

  println("Slide " + (slideIndex + 1) + "/" + slides.size() +
          ": " + slides.get(slideIndex).name +
          " | upper visual: 0-" + upperVisualBottom +
          " | lower visual: " + lowerVisualTop + "-" + H + " (render " + W + "x" + H + ")");
}

// ------------------------------------------------------------------
// EFFECT RENDERING AND COMPOSITING
// ------------------------------------------------------------------

// Builds the frame: the slide photo, with the effect written into its masked
// zone. When kaleido is the effect it is drawn on the front layer instead, so
// the frame is just the photo. No per-frame allocation.
void composeFrame() {
  Slide sl = slides.get(slideIndex);
  frame.loadPixels();
  int[] fp = frame.pixels;
  System.arraycopy(sl.photo, 0, fp, 0, fp.length);

  if (!kaleidoInFront()) {
    // Zone A (white mask) is the lower visual, zone B the upper one.
    boolean effectInA = !photoInA;
    byte want = (byte) (effectInA ? 1 : 0);
    int y0 = effectInA ? lowerVisualTop : 0;
    int y1 = effectInA ? H : upperVisualBottom;
    SkyEffect e = effectInA ? effectA : effectB;

    if (e instanceof ContourEffect) {
      renderContoursInto(fp, sl.zone, want, y0, y1);
    } else {
      PGraphics pg = effectInA ? lowerVisual : upperVisual;
      e.render(pg, showTime());
      pg.loadPixels();
      int[] ep = pg.pixels;
      for (int y = y0; y < y1; y++) {
        int row = y * W;
        int erow = (y - y0) * W;
        for (int x = 0; x < W; x++) {
          if (sl.zone[row + x] == want) fp[row + x] = ep[erow + x];
        }
      }
    }
  }
  frame.updatePixels();
}

// ------------------------------------------------------------------
// FILTERS AND TITLECARDS
// ------------------------------------------------------------------

VisualFilter makeFilter(int n) {
  if (n == 1) return new PosterizeFilter();
  if (n == 2) return new ScanlineFilter();
  if (n == 3) return new ThermalFilter();
  return null;
}

void pickFilter() {
  VisualFilter f = makeFilter(1 + int(random(3)));

  runningFilters.add(new RunningFilter(f, millis() + FILTER_SHOW_MS));
  println("Filter selected: " + f.getName());
}

void expireFilters(int now) {
  for (int i = runningFilters.size() - 1; i >= 0; i--) {
    if (now >= runningFilters.get(i).expiresAt) {
      runningFilters.remove(i);
    }
  }
}

String currentTitlecardName() {
  return titlecardNames[constrain(titlecardSelection, 1, titlecardNames.length) - 1];
}

// Titlecard size: 25% of the height, shrunk to fit horizontally with a 5%
// margin on each side. Measured on `pg` (its current font must be titleFont).
float titlecardTextSize(PGraphics pg, String name) {
  float size = max(height * 0.25, width * 0.045);
  pg.textFont(titleFont);
  pg.textSize(size);
  float maxW = width * 0.90;
  float w = pg.textWidth(name);
  return w > maxW ? size * maxW / w : size;
}

void drawTitlecardOverlay() {
  //if (!titlecardsEnabled) return;
  if (!titlecardsEnabled || !titlecardVisible) return;
  
  pushStyle();
  blendMode(DIFFERENCE);
  //PFont f = createFont("Arial Italic", 32);
  //textFont(f);
  textFont(titleFont);
  fill(255);
  noStroke();
  textAlign(CENTER, CENTER);
  String name = currentTitlecardName();
  textSize(titlecardTextSize(g, name));
  text(name, width / 2, height / 2);
  blendMode(BLEND);
  popStyle();
}

// ------------------------------------------------------------------
// EFFECT INTERFACES AND EFFECTS
// ------------------------------------------------------------------

interface SkyEffect {
  void setup(PApplet app, int w, int h);
  void render(PGraphics pg, float timeSeconds);
  String getName();
}

interface VisualFilter {
  void apply(PImage img);
  String getName();
}

// A slide, prepared once at load at render size: the photo pixels, the zone
// of every pixel (1 = A/white mask, 0 = B/black) and the zone bounds.
class Slide {
  int[] photo;
  byte[] zone;
  int lowerTop, upperBottom;   // first row of zone A, one past the last row of zone B
  String name;

  Slide(PImage img, PImage msk, String n) {
    name = n;
    img.resize(W, H);
    img.loadPixels();
    photo = new int[W * H];
    for (int i = 0; i < photo.length; i++) photo[i] = img.pixels[i] | 0xFF000000;

    msk.resize(W, H);
    msk.loadPixels();
    zone = new byte[W * H];
    int highestA = H, lowestB = -1;
    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        int i = y * W + x;
        boolean isWhite = brightness(msk.pixels[i]) >= 128;
        zone[i] = (byte) (isWhite ? 1 : 0);
        if (isWhite && y < highestA) highestA = y;
        if (!isWhite && y > lowestB) lowestB = y;
      }
    }
    lowerTop = constrain(highestA == H ? H / 2 : highestA, 0, H - 1);
    upperBottom = constrain(lowestB < 0 ? H / 2 : lowestB + 1, 1, H);
  }
}

class RunningFilter {
  VisualFilter filter;
  int expiresAt;
  RunningFilter(VisualFilter f, int e) {
    filter = f;
    expiresAt = e;
  }
}

// Builds the same effect for both zones. Only the zone not showing the photo
// is rendered, so the effect follows the onset swaps automatically.
int currentEffectId = -1;

void makeEffects() {
  makeEffects(effectChoice <= 0
    ? EFFECT_IDS[int(random(EFFECT_IDS.length))]
    : EFFECT_IDS[effectChoice - 1]);
}

void makeEffects(int n) {
  currentEffectId = n;
  effectA = randomEffect(false, n);
  effectB = randomEffect(true, n);
  effectA.setup(this, lowerVisual.width, lowerVisual.height);
  effectB.setup(this, upperVisual.width, upperVisual.height);
}

SkyEffect randomEffect(boolean upperZone, int n) {
  SkyEffect effect;

  if (n == 0) effect = new PlasmaEffect();
  else if (n == 1) effect = new WaveEffect(upperZone);
  else if (n == 2) effect = new ParticleEffect();
  else if (n == 3) effect = new ContourEffect();
  else if (n == 4) effect = new FluidFieldEffect();
  else if (n == 5) effect = new SignalGlitchEffect();
  else if (n == 6) effect = new KaleidoGeometryEffect();
  else effect = new PlasmaMorphEffect();

  println("Selected Effect: " + effect.getName());
  return effect;
}

class PlasmaEffect implements SkyEffect {
  public void setup(PApplet app, int w, int h) { }
  public String getName() { return "Plasma"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(35, 8, 18);
    p.noStroke();

    for (int i = 0; i < 110; i++) {
      float x = p.width * 0.5 + sin(i * 0.11 + t * 1.3) * p.width * 0.43;
      float y = p.height * 0.5 + cos(i * 0.17 + t) * p.height * 0.43;
      p.fill(sunsetColor(i, 190));
      float d = 18 + (i % 6) * 5;
      p.ellipse(x, y, d, d);
    }

    p.endDraw();
  }
}

class WaveEffect implements SkyEffect {
  boolean upperZone;

  WaveEffect(boolean isUpperZone) {
    upperZone = isUpperZone;
  }

  public void setup(PApplet app, int w, int h) { }

  public String getName() {
    return "Wave";
  }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(28, 7, 15);
    p.noFill();

    // B/sky zone: position waves closer to the top.
    // A/lower zone: position waves closer to the bottom.
    float waveCenter = upperZone
      ? p.height * 0.25
      : p.height * 0.75;

    for (int k = 0; k < 34; k++) {
      p.stroke(sunsetColor(k, 190));
      p.strokeWeight(2);
      p.beginShape();

      for (int x = 0; x <= p.width; x += 8) {
        float y = waveCenter +
          sin(x * 0.012 + t + k * 0.19) * (12 + k * 1.5);

        p.vertex(x, y);
      }

      p.endShape();
    }

    p.endDraw();
  }
}

class ParticleEffect implements SkyEffect {
  PVector[] pts = new PVector[260];

  public void setup(PApplet app, int w, int h) {
    for (int i = 0; i < pts.length; i++) {
      pts[i] = new PVector(random(w), random(h));
    }
  }

  public String getName() { return "Particles"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(28, 7, 16);
    p.noStroke();

    for (int i = 0; i < pts.length; i++) {
      PVector q = pts[i];
      float x = (q.x + sin(t + i * 0.13) * 35 + p.width) % p.width;
      float y = (q.y + cos(t * 0.7 + i * 0.09) * 25 + p.height) % p.height;
      p.fill(sunsetColor(i, 215));
      p.ellipse(x, y, 3 + (i % 5) * 2, 3 + (i % 5) * 2);
    }

    p.endDraw();
  }
}

// Contour lines computed per pixel from a height field (same noise terrain as
// before), instead of drawing thousands of marching-squares segments. Each
// pixel finds its distance to the nearest contour level, divided by the local
// slope, so lines keep an even width. Colour = that level through LINE_PALETTE.
class ContourEffect implements SkyEffect {
  public void setup(PApplet app, int w, int h) { ensureContourField(); }
  public String getName() { return "Contours"; }
  public void render(PGraphics p, float t) { }   // drawn by renderContoursInto()
}

float[] contourElev;      // terrain height per render pixel
float[] contourInvSlope;  // 1 / |gradient| per render pixel
int[] contourLut = new int[256];

void ensureContourField() {
  if (contourElev != null && contourElev.length == W * H) return;
  final float TERRAIN_SCALE = 0.006;   // per screen pixel, as before
  final int GRID = 6;                  // render px between noise samples
  noiseDetail(5, 0.5);
  int gc = W / GRID + 3, gr = H / GRID + 3;
  float[] grid = new float[gc * gr];
  for (int gy = 0; gy < gr; gy++) {
    for (int gx = 0; gx < gc; gx++) {
      grid[gy * gc + gx] = noise(gx * GRID * RS * TERRAIN_SCALE, gy * GRID * RS * TERRAIN_SCALE);
    }
  }
  contourElev = new float[W * H];
  for (int y = 0; y < H; y++) {
    int gy = y / GRID;
    float fy = (y % GRID) / (float) GRID;
    fy = fy * fy * (3 - 2 * fy);
    for (int x = 0; x < W; x++) {
      int gx = x / GRID;
      float fx = (x % GRID) / (float) GRID;
      fx = fx * fx * (3 - 2 * fx);
      int g0 = gy * gc + gx;
      float top = lerp(grid[g0], grid[g0 + 1], fx);
      float bot = lerp(grid[g0 + gc], grid[g0 + gc + 1], fx);
      contourElev[y * W + x] = lerp(top, bot, fy);
    }
  }
  contourInvSlope = new float[W * H];
  for (int y = 0; y < H; y++) {
    int ya = max(0, y - 1), yb = min(H - 1, y + 1);
    for (int x = 0; x < W; x++) {
      int xa = max(0, x - 1), xb = min(W - 1, x + 1);
      float dx = (contourElev[y * W + xb] - contourElev[y * W + xa]) / max(1, xb - xa);
      float dy = (contourElev[yb * W + x] - contourElev[ya * W + x]) / max(1, yb - ya);
      contourInvSlope[y * W + x] = 1.0 / max(1e-5, sqrt(dx * dx + dy * dy));
    }
  }
  for (int i = 0; i < 256; i++) contourLut[i] = linePaletteAt(i / 255.0);
}

// Writes contours on black into fp for the pixels of `zone` == want in rows y0..y1.
void renderContoursInto(int[] fp, byte[] zone, byte want, int y0, int y1) {
  ensureContourField();
  int steps = max(1, contourSteps);
  float phase = contourAnimationOffset / elevationDelta;   // 0..1
  // Line half-width in render px (the old 2 px screen line).
  final float HALF = 1.0 / RS;
  for (int y = y0; y < y1; y++) {
    int row = y * W;
    for (int x = 0; x < W; x++) {
      int i = row + x;
      if (zone[i] != want) continue;
      float v = (contourElev[i] - phase) * steps;
      int fl = (int) Math.floor(v);
      float f = v - fl;
      int nearest = f < 0.5 ? fl : fl + 1;
      float d = (f < 0.5 ? f : 1 - f) / steps * contourInvSlope[i];   // render px
      float cov = 1.0 - (d - HALF);
      if (cov <= 0) { fp[i] = 0xFF000000; continue; }
      float t = (float) nearest / steps + phase;
      t -= (float) Math.floor(t);
      int c = contourLut[(int) (t * 255)];
      if (cov >= 1) { fp[i] = c; continue; }
      int k = (int) (cov * 256);
      fp[i] = 0xFF000000 | ((((c >> 16) & 0xFF) * k >> 8) << 16)
                         | ((((c >> 8) & 0xFF) * k >> 8) << 8)
                         | ((c & 0xFF) * k >> 8);
    }
  }
}

class SkylineEffect implements SkyEffect {
  float[] heights = new float[90];

  public void setup(PApplet app, int w, int h) {
    for (int i = 0; i < heights.length; i++) {
      heights[i] = random(h * 0.08, h * 0.55);
    }
  }

  public String getName() { return "Skyline"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(24, 7, 16);
    p.noStroke();
    float bw = p.width / (float)heights.length;

    for (int i = 0; i < heights.length; i++) {
      float x = i * bw;
      float h = heights[i];
      p.fill(75 + (i % 5) * 12, 20 + (i % 4) * 5, 24 + (i % 6) * 4);
      p.rect(x, p.height * 0.82 - h, bw - 2, h);

      p.fill(255, 190, 75, 190);
      for (float yy = p.height * 0.82 - h + 8; yy < p.height * 0.8; yy += 13) {
        for (float xx = x + 5; xx < x + bw - 4; xx += 10) {
          if (((int)(xx + yy + i) % 4) == 0) p.rect(xx, yy, 3, 5);
        }
      }
    }

    p.fill(20, 5, 12);
    p.rect(0, p.height * 0.82, p.width, p.height * 0.18);
    p.endDraw();
  }
}


// ------------------------------------------------------------------
// NEW EFFECTS — optimized for persistent per-effect buffers and 1080p
// ------------------------------------------------------------------

/**
 * FluidFieldEffect
 * A fixed pool of particles advected through a smooth, time-varying vector
 * field. Particle positions and velocities are allocated once in setup().
 */
class FluidFieldEffect implements SkyEffect {
  final int PARTICLE_COUNT = 520;
  float[] px = new float[PARTICLE_COUNT];
  float[] py = new float[PARTICLE_COUNT];
  float[] vx = new float[PARTICLE_COUNT];
  float[] vy = new float[PARTICLE_COUNT];
  int effectW, effectH;
  boolean initialized = false;

  public void setup(PApplet app, int w, int h) {
    effectW = w;
    effectH = h;
    for (int i = 0; i < PARTICLE_COUNT; i++) {
      px[i] = app.random(w);
      py[i] = app.random(h);
      vx[i] = 0;
      vy[i] = 0;
    }
    initialized = true;
  }

  public String getName() { return "Fluid Field"; }

  public void render(PGraphics p, float t) {
    if (!initialized) return;
    p.beginDraw();
    p.noStroke();
    p.fill(22, 5, 14, 42);
    p.rect(0, 0, p.width, p.height);

    for (int i = 0; i < PARTICLE_COUNT; i++) {
      float nx = px[i] * 0.006;
      float ny = py[i] * 0.006;
      float angle = sin(nx * 1.7 + t * 0.42) * 2.1
                  + cos(ny * 1.9 - t * 0.31) * 1.8
                  + sin((nx + ny) * 1.2 + t * 0.2);
      float targetVX = cos(angle) * 1.7;
      float targetVY = sin(angle) * 1.7;
      vx[i] += (targetVX - vx[i]) * 0.075;
      vy[i] += (targetVY - vy[i]) * 0.075;

      float oldX = px[i];
      float oldY = py[i];
      px[i] += vx[i];
      py[i] += vy[i];

      if (px[i] < 0 || px[i] >= effectW || py[i] < 0 || py[i] >= effectH) {
        px[i] = (px[i] + effectW) % effectW;
        py[i] = (py[i] + effectH) % effectH;
        oldX = px[i];
        oldY = py[i];
      }

      p.stroke(sunsetColor(i, 150 + (i % 90)));
      p.strokeWeight(1.1 + (i % 3) * 0.35);
      p.line(oldX, oldY, px[i], py[i]);
    }
    p.endDraw();
  }
}

/**
 * SignalGlitchEffect
 * Procedural digital tearing, offset color bars and scanline bursts.
 * Uses a small fixed number of rectangles and lines rather than pixel copies.
 */
// Colour-field wave swings once per beat (/audio/bpm); the signal tears
// light up on high onsets and fade over TEAR_DECAY_S.
class SignalGlitchEffect implements SkyEffect {
  final float TEAR_DECAY_S = 0.15;
  int effectW, effectH;
  float lastT = -1;
  float tearFlash = 0;
  int highSeen = highHits;

  public void setup(PApplet app, int w, int h) {
    effectW = w;
    effectH = h;
  }

  public String getName() { return "Signal Glitch"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(7, 8, 19);
    p.noStroke();

    float dt = lastT < 0 ? 0 : constrain(t - lastT, 0, 0.25);
    lastT = t;
    // One full swing per beat; without a BPM lock, the original slow drift (1.4 rad/s).
    float bpm = oscBpm;
    // Leader / standalone: advance the beat; followers get it from the leader.
    if (!following()) {
      glitchBeatPhase += dt * (bpm > 0 ? bpm / 60.0 : 1.4 / TWO_PI);
      glitchBeatPhase %= 1000;
    }

    int hh = highHits;
    if (hh != highSeen) tearFlash = 1;
    else tearFlash *= exp(-dt / TEAR_DECAY_S);
    highSeen = hh;

    // Colour field, swinging to the beat.
    for (int band = 0; band < 18; band++) {
      float y = (band / 18.0) * effectH;
      float wave = sin(TWO_PI * glitchBeatPhase + band * 0.73);
      float x = effectW * (0.08 + 0.08 * wave);
      float w = effectW * (0.35 + 0.28 * (0.5 + 0.5 * cos(t + band)));
      p.fill(linePaletteColor(band, 28 + (band % 4) * 12));
      p.rect(x, y, w, max(2, effectH / 26.0));
    }

    // Signal tears: each high onset lights 3 of the 9 (rotating with the
    // onset count) and they fade out. Positions stay deterministic.
    if (tearFlash > 0.02) {
      for (int tear = 0; tear < 9; tear++) {
        if ((tear + hh) % 3 != 0) continue;
        float pulse = tearFlash;
        float y = (0.08 + 0.84 * ((tear * 0.137 + hh * 0.311) % 1.0)) * effectH;
        float shift = (0.82 + 0.18 * pulse) * effectW * 0.12;
        float h = max(2, effectH * (0.006 + (tear % 3) * 0.003));
        p.fill(#D13333, 170 * pulse);
        p.rect(shift, y, effectW * 0.72, h);
        p.fill(#FFCB53, 150 * pulse);
        p.rect(-shift * 0.55, y + h, effectW * 0.58, h * 0.8);
      }
    }

    p.stroke(255, 36);
    p.strokeWeight(1);
    for (int y = 0; y < effectH; y += max(2, 5 / RS)) {
      p.line(0, y, effectW, y);
    }

    // Bright sync flashes.
    float flash = max(0, sin(t * 0.83 + 1.2) - 0.96);
    if (flash > 0) {
      p.noStroke();
      p.fill(255, 220 * flash);
      p.rect(0, effectH * 0.47, effectW, effectH * 0.035);
    }
    p.endDraw();
  }
}

/**
 * KaleidoGeometryEffect
 * Radially repeated polygonal geometry. Work is bounded by fixed sector/ring
 * counts, independent of the full output resolution.
 */
class KaleidoGeometryEffect implements SkyEffect {
  final int SECTORS = 12;
  final int RINGS = 9;
  int effectW, effectH;

  public void setup(PApplet app, int w, int h) {
    effectW = w;
    effectH = h;
  }

  public String getName() { return "Kaleido Geometry"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(18, 4, 24);
    drawShape(p, effectW * 0.5, effectH * 0.5, min(effectW, effectH) * 0.49, t);
    p.endDraw();
  }

  // Same shape straight onto a Java2D surface: one batched path per ring
  // instead of 48 separate quads of line() calls.
  void drawShapeJ2D(Graphics2D g2, float cx, float cy, float maxR, float t, float strokeScale) {
    AffineTransform saved = g2.getTransform();
    g2.translate(cx, cy);
    g2.rotate(t * 0.12);
    Path2D.Float path = new Path2D.Float();
    for (int ring = 0; ring < RINGS; ring++) {
      float radius = maxR * (ring + 1) / RINGS;
      float twist = sin(t * 0.38 + ring * 0.42) * 0.16;
      float inner = radius * (0.48 + 0.12 * sin(t + ring));
      path.reset();
      for (int sector = 0; sector < SECTORS; sector++) {
        float a = TWO_PI * sector / SECTORS + twist;
        float b = TWO_PI * (sector + 1) / SECTORS + twist;
        path.moveTo(cos(a) * inner, sin(a) * inner);
        path.lineTo(cos(a) * radius, sin(a) * radius);
        path.lineTo(cos(b) * radius, sin(b) * radius);
        path.lineTo(cos(b) * inner, sin(b) * inner);
        path.closePath();
      }
      int c = linePaletteAt(ring / (float)(RINGS - 1));
      g2.setColor(new java.awt.Color((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, 170));
      g2.setStroke(new BasicStroke((1.4 + (ring % 3) * 0.45) * strokeScale,
        BasicStroke.CAP_ROUND, BasicStroke.JOIN_MITER));
      g2.draw(path);
    }
    g2.setTransform(saved);
  }

  // Draws the kaleidoscope lines only (no background) centred at cx, cy.
  void drawShape(PGraphics p, float cx, float cy, float maxR, float t) {
    p.pushStyle();
    p.pushMatrix();
    p.translate(cx, cy);
    p.rotate(t * 0.12);
    p.noFill();

    for (int ring = 0; ring < RINGS; ring++) {
      float radius = maxR * (ring + 1) / RINGS;
      float twist = sin(t * 0.38 + ring * 0.42) * 0.16;
      // Inner rings dark, outer rings light, through LINE_PALETTE.
      p.stroke(linePaletteAt(ring / (float)(RINGS - 1)), 170);
      p.strokeWeight(1.4 + (ring % 3) * 0.45);

      for (int sector = 0; sector < SECTORS; sector++) {
        float a = TWO_PI * sector / SECTORS + twist;
        float b = TWO_PI * (sector + 1) / SECTORS + twist;
        float inner = radius * (0.48 + 0.12 * sin(t + ring));
        float x1 = cos(a) * inner;
        float y1 = sin(a) * inner;
        float x2 = cos(a) * radius;
        float y2 = sin(a) * radius;
        float x3 = cos(b) * radius;
        float y3 = sin(b) * radius;
        float x4 = cos(b) * inner;
        float y4 = sin(b) * inner;

        p.line(x1, y1, x2, y2);
        p.line(x2, y2, x3, y3);
        p.line(x3, y3, x4, y4);
        p.line(x4, y4, x1, y1);
      }
    }
    p.popMatrix();
    p.popStyle();
  }
}

// ------------------------------------------------------------------
// KALEIDO FRONT LAYER
// Kaleido Geometry is drawn in front of everything (behind the titlecard),
// centred in the right third, and grows with the continuous low level.
// ------------------------------------------------------------------

float kaleidoBassGrow = 1.5;   // extra scale at full low (1.5 = 2.5x)
float kaleidoLowEnv = 0;

boolean kaleidoInFront() {
  return effectA instanceof KaleidoGeometryEffect;
}

// Radius for this frame: grows with the smoothed low level.
float kaleidoRadius() {
  float fps = max(frameRate, 1);
  float target = constrain(oscLow, 0, 1);
  if (!following()) {
    kaleidoLowEnv += (target - kaleidoLowEnv)
      * (1 - exp(-1.0 / (fps * (target > kaleidoLowEnv ? 0.03 : 0.25))));
  }
  float baseR = min(width / 3.0, height) * 0.49;
  return baseR * (1 + kaleidoBassGrow * kaleidoLowEnv);
}

// Fallback path (non-Java2D renderer): draw on the sketch surface.
void drawKaleidoFront() {
  if (!kaleidoInFront()) return;
  float r = kaleidoRadius();
  KaleidoGeometryEffect k = (KaleidoGeometryEffect) effectA;
  float t = showTime();

  Graphics2D g2 = (g instanceof PGraphicsJava2D) ? ((PGraphicsJava2D) g).g2 : null;
  Shape clip = (titlecardsEnabled && titlecardVisible && g2 != null) ? titleClip() : null;
  if (clip == null) {
    k.drawShape(g, width * 5.0 / 6.0, height * 0.5, r, t);
    return;
  }
  // Titlecard showing: clip the letters out, so the name stays fully in front
  // (its DIFFERENCE blend would otherwise show the lines through the letters).
  Shape old = g2.getClip();
  g2.setClip(clip);
  k.drawShape(g, width * 5.0 / 6.0, height * 0.5, r, t);
  g2.setClip(old);
}

Area titleClipArea;
String titleClipName = null;

// The screen minus the titlecard letters (plus a 2 px margin), cached per name.
// The letter outlines come from the title font; they are placed by rendering
// the titlecard once offscreen and matching its bounding box.
Shape titleClip() {
  String name = currentTitlecardName();
  if (titleClipArea != null && name.equals(titleClipName)) return titleClipArea;
  titleClipName = name;
  titleClipArea = null;

  Font base = (Font) titleFont.getNative();
  if (base == null) return null;

  PGraphics t = createGraphics(width, height);
  t.beginDraw();
  t.background(0);
  t.textFont(titleFont);
  t.textAlign(CENTER, CENTER);
  float size = titlecardTextSize(t, name);
  t.textSize(size);
  t.fill(255);
  t.noStroke();
  t.text(name, width / 2, height / 2);
  t.endDraw();
  t.loadPixels();
  int bx0 = width, by0 = height;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if ((t.pixels[y * width + x] & 0xFF) > 128) {
        if (x < bx0) bx0 = x;
        if (y < by0) by0 = y;
      }
    }
  }
  if (bx0 == width) return null;

  Graphics2D g2 = ((PGraphicsJava2D) g).g2;
  GlyphVector gv = base.deriveFont(size).createGlyphVector(g2.getFontRenderContext(), name);
  Shape outline = gv.getOutline();
  Rectangle2D ob = outline.getBounds2D();
  Shape placed = AffineTransform.getTranslateInstance(bx0 - ob.getX(), by0 - ob.getY())
    .createTransformedShape(outline);
  Area letters = new Area(placed);
  letters.add(new Area(new BasicStroke(4).createStrokedShape(placed)));
  Area clip = new Area(new Rectangle2D.Float(0, 0, width, height));
  clip.subtract(letters);
  titleClipArea = clip;
  return clip;
}

/**
 * PlasmaMorphEffect
 * Organic animated plasma calculated into a quarter-resolution buffer, then
 * enlarged into the zone surface. Buffer and pixel storage are reused.
 */
class PlasmaMorphEffect implements SkyEffect {
  PGraphics lowBuffer;
  int bufferW, bufferH;
  boolean ready = false;

  public void setup(PApplet app, int w, int h) {
    bufferW = max(1, w / 4);
    bufferH = max(1, h / 4);
    lowBuffer = app.createGraphics(bufferW, bufferH);
    ready = true;
  }

  public String getName() { return "Plasma Morph"; }

  public void render(PGraphics p, float t) {
    if (!ready) return;

    lowBuffer.beginDraw();
    lowBuffer.loadPixels();
    for (int y = 0; y < bufferH; y++) {
      float ny = y * 0.055;
      for (int x = 0; x < bufferW; x++) {
        float nx = x * 0.055;
        float v = sin(nx + t * 0.9)
                + sin(ny * 1.2 - t * 0.7)
                + sin((nx + ny) * 0.72 + t * 0.55)
                + cos(sqrt(nx * nx + ny * ny) * 0.85 - t);
        float u = (v + 4.0) * 0.125;
        int idx = constrain(round(u * (RAMP_SIZE - 1)), 0, RAMP_SIZE - 1);
        color c = contourColorRamp[idx];
        lowBuffer.pixels[y * bufferW + x] = color(red(c), green(c), blue(c), 255);
      }
    }
    lowBuffer.updatePixels();
    lowBuffer.endDraw();

    p.beginDraw();
    p.image(lowBuffer, 0, 0, p.width, p.height);
    p.endDraw();
  }
}


// ------------------------------------------------------------------
// FILTER IMPLEMENTATIONS
// ------------------------------------------------------------------

// Posterize plus a slight bass-driven pixelation (from photobooth pixelz):
// the low band sets the block size. Quiet = full resolution, loud low = blocks
// up to posterizeMaxBlock px.
float posterizeMaxBlock = 12;

class PosterizeFilter implements VisualFilter {
  final float ATTACK_S = 0.01;    // blocks grow almost instantly on a hit...
  final float RELEASE_S = 0.10;   // ...and sharpen back quickly
  final float CURVE = 1.5;        // >1 keeps quiet bass sharp, only loud bass gets chunky
  float env = 0;

  public String getName() { return "Posterize"; }

  public void apply(PImage p) {
    float fps = max(frameRate, 1);
    float target = constrain(oscLow, 0, 1);
    env += (target - env) * (1 - exp(-1.0 / (fps * (target > env ? ATTACK_S : RELEASE_S))));
    int block = round(lerp(1, posterizeMaxBlock / RS, pow(env, CURVE)));   // render px
    if (block >= 2) pixelate(p, block);
    posterize(p);
  }

  // Same result as filter(POSTERIZE, 4), through a 256-entry table.
  int[] lut;
  void posterize(PImage p) {
    if (lut == null) {
      lut = new int[256];
      for (int v = 0; v < 256; v++) lut[v] = ((v * 4) >> 8) * 255 / 3;
    }
    p.loadPixels();
    int[] px = p.pixels;
    for (int i = 0; i < px.length; i++) {
      int c = px[i];
      px[i] = (c & 0xFF000000) | (lut[(c >> 16) & 0xFF] << 16)
            | (lut[(c >> 8) & 0xFF] << 8) | lut[c & 0xFF];
    }
    p.updatePixels();
  }

  // Each block takes the colour of its centre pixel, like the photobooth shader.
  void pixelate(PImage p, int block) {
    int w = p.width, h = p.height;
    p.loadPixels();
    int[] px = p.pixels;
    for (int by = 0; by < h; by += block) {
      int bh = min(block, h - by);
      int cy = by + bh / 2;
      for (int bx = 0; bx < w; bx += block) {
        int bw = min(block, w - bx);
        int c = px[cy * w + bx + bw / 2];
        for (int y = by; y < by + bh; y++) {
          int row = y * w;
          for (int x = bx; x < bx + bw; x++) px[row + x] = c;
        }
      }
    }
    p.updatePixels();
  }
}

class ScanlineFilter implements VisualFilter {
  public String getName() { return "Scanlines"; }

  // Thick dark bands that scroll upward (sizes in screen px, frame is 1/RS).
  final int PERIOD = 10 / RS;     // from one band to the next
  final int THICK = 4 / RS;       // each dark band
  final float SPEED = 60 / RS;    // per second, upward
  final float DARK = 0.55;    // brightness kept inside a band

  public void apply(PImage p) {
    int offset = int(showTime() * SPEED) % PERIOD;
    int k = int(DARK * 256);
    p.loadPixels();
    for (int y = 0; y < p.height; y++) {
      if ((y + offset) % PERIOD >= THICK) continue;
      int row = y * p.width;
      for (int x = 0; x < p.width; x++) {
        int c = p.pixels[row + x];
        int r = (((c >> 16) & 0xFF) * k) >> 8;
        int g = (((c >> 8) & 0xFF) * k) >> 8;
        int b = ((c & 0xFF) * k) >> 8;
        p.pixels[row + x] = (c & 0xFF000000) | (r << 16) | (g << 8) | b;
      }
    }
    p.updatePixels();
  }
}

class TitlecardsFilter implements VisualFilter {
  public String getName() { return "Titlecards"; }
  public void apply(PImage p) {
    // Drawn by drawTitlecardOverlay().
  }
}

// ------------------------------------------------------------------
// SHARED COLOR AND CONTOUR CLOCK HELPERS
// ------------------------------------------------------------------

// Line palette for Contours and Signal Glitch, dark to light.
final color[] LINE_PALETTE = { #7B132F, #901212, #D13333, #FF7A28, #FFCB53 };

// u = 0 (darkest) .. 1 (lightest), blended between palette stops.
color linePaletteAt(float u) {
  float x = constrain(u, 0, 1) * (LINE_PALETTE.length - 1);
  int i = min(int(x), LINE_PALETTE.length - 2);
  return lerpColor(LINE_PALETTE[i], LINE_PALETTE[i + 1], x - i);
}

color linePaletteColor(int index, int alphaValue) {
  color c = LINE_PALETTE[index % LINE_PALETTE.length];
  return color(red(c), green(c), blue(c), alphaValue);
}

color sunsetColor(int index, int alphaValue) {
  color c = SUNSET_PALETTE[index % SUNSET_PALETTE.length];
  return color(red(c), green(c), blue(c), alphaValue);
}

// Contours follow the continuous low level (/audio/lmh): count goes 4..20 and
// speed goes from secondsPerStep (quiet) to CONTOUR_FAST_SPS (full low).
boolean contoursFollowBass = true;
final int CONTOUR_STEPS_MIN = 4, CONTOUR_STEPS_MAX = 20;
final float CONTOUR_FAST_SPS = 0.25;   // seconds per step at full low
float contourLowEnv = 0;

void updateContourClock() {
  float now = millis() / 1000.0;
  float elapsed = max(0, now - contourPreviousTime);
  contourPreviousTime = now;

  float sps = secondsPerStep;
  if (contoursFollowBass) {
    float target = constrain(oscLow, 0, 1);
    // Smoothed so the count doesn't flicker: quick rise, slower fall.
    float tc = target > contourLowEnv ? 0.05 : 0.30;
    contourLowEnv += (target - contourLowEnv) * (1 - exp(-elapsed / tc));
    contourSteps = round(lerp(CONTOUR_STEPS_MIN, CONTOUR_STEPS_MAX, contourLowEnv));
    sps = lerp(secondsPerStep, CONTOUR_FAST_SPS, contourLowEnv);
  }

  if (!contoursPaused) {
    float intervalSize = elevationDelta / max(1, contourSteps);
    float movement = intervalSize * elapsed / max(0.05, sps);
    contourAnimationOffset += uphill ? movement : -movement;
    contourAnimationOffset =
      (contourAnimationOffset % elevationDelta + elevationDelta) % elevationDelta;
  }
}

// ------------------------------------------------------------------
// KEYBOARD CONTROLS
// ------------------------------------------------------------------

void keyPressed() {
  if (key == ESC) key = 0;
  handleControlKey(key == 0 ? ESC : key, keyCode);
}

void handleControlKey(char k, int kc) {
  if (k == ESC) {
    exit();
    return;
  }

  // Select titlecard text (1-6).
  // Selection does not automatically enable or disable it.
  if (k >= '1' && k <= '6') {
    titlecardSelection = k - '0';
    println("Titlecard selection: " + titlecardSelection);
  }

  // Toggle titlecard cycling ON/OFF. Enabling starts with a visible phase.
  if (k == '`') setTitlecardsEnabled(!titlecardsEnabled);

  if (k == ' ') contoursPaused = !contoursPaused;
  if (k == 'd' || k == 'D') uphill = !uphill;

  if (kc == UP) secondsPerStep = max(0.25, secondsPerStep - 0.25);
  if (kc == DOWN) secondsPerStep += 0.25;

  if (k == '+' || k == '=') contourSteps++;
  if (k == '-' || k == '_') contourSteps = max(1, contourSteps - 1);

  if (k == 'r' || k == 'R') requestResetContours = true;
  if (k == 'c' || k == 'C') requestNewColors = true;
  if (k == 'n' || k == 'N') requestNextSlide = true;
}

void chooseSunsetColors() {
  int first = int(random(SUNSET_PALETTE.length));
  int second = int(random(SUNSET_PALETTE.length));
  while (second == first) second = int(random(SUNSET_PALETTE.length));

  minContourColor = SUNSET_PALETTE[first];
  maxContourColor = SUNSET_PALETTE[second];

  for (int i = 0; i < RAMP_SIZE; i++) {
    float u = i / float(RAMP_SIZE - 1);
    contourColorRamp[i] = lerpColor(minContourColor, maxContourColor, u);
  }
}


