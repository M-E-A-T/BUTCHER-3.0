/**
 * skysets.pde — masked camera/effects slideshow for Processing 4 (Java mode).
 * Requires the Processing Video library. 
 * AudioWaveEffect also uses Processing Sound.
 *
 * Pairing: img_raw/name.jpg + img_mask/name.png
 * White mask pixels (brightness >= 128) are zone A; black pixels are zone B.
 *
 * Controls:
 * A separate "skysets controls" window opens with sliders/toggles for all
 * of the controls below, plus effect selection, slide timing and camera/filters.
 *
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

import processing.video.*;
import processing.sound.*;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;

// ------------------------------------------------------------------
// SETTINGS
// ------------------------------------------------------------------

// Adjustable live from the control panel window.
int slideMs = 20000;
final int FILTER_PICK_MS = 10000;
final int FILTER_SHOW_MS = 20000;
//final int TITLE_ROTATE_MS = 5000;
int titlecardVisibleMs = 60000;
int titlecardHiddenMs = 0;       // 0 = titlecard always visible
final int MAX_CAMERAS = 2;
final int RAMP_SIZE = 1024;

final color[] SUNSET_PALETTE = {
  #9D0208, #D00000, #E85D04, #F48C06,
  #FFBA08, #F9844A, #F15BB5, #FF6B6B
};

final String[] titlecardNames = {
  "TATSMIXES", "IVY", "SUNSCRN", "GRILLMASTER", "KINGKILO", "HIMMA"
};

ArrayList<Slide> slides = new ArrayList<Slide>();
ArrayList<Capture> cameras = new ArrayList<Capture>();
ArrayList<RunningFilter> runningFilters = new ArrayList<RunningFilter>();

int slideIndex = 0;
int slideStarted = 0;
int lastFilterPick = 0;
//int lastTitleRotate = 0;

boolean cameraInA = true;
boolean titlecardsEnabled = true;
int titlecardSelection = 1;
PFont titleFont;

// Control panel state. Effect choice 0 = random, 1..9 = specific effect.
ControlPanel panel;
boolean useCamera = true;
boolean filtersEnabled = true;
// Manual by default: nothing switches on its own. Auto restores timed switching.
boolean autoMode = false;
int manualFilterChoice = 0; // 0 = none, 1..4 = filter
VisualFilter manualFilter = null;
volatile boolean requestFilter = false;
final String[] FILTER_NAMES = { "None", "Invert", "Grayscale", "Posterize", "Scanlines" };
int effectChoiceA = 4; // Contours
int effectChoiceB = 1; // Plasma
final String[] EFFECT_NAMES = {
  "Random", "Plasma", "Wave", "Particles", "Contours", "Fluid Field",
  "Signal Glitch", "Kaleido Geometry", "Audio Wave", "Plasma Morph"
};

// Requests from the panel window, applied on the main draw thread.
volatile boolean requestNextSlide = false;
volatile boolean requestEffectA = false;
volatile boolean requestEffectB = false;
volatile boolean requestResetContours = false;
volatile boolean requestNewColors = false;

// Shared microphone analyzer; initialized only if AudioWaveEffect is selected.
AudioIn audioInput;
Amplitude audioAmplitude;
boolean audioInitialized = false;

//boolean titlecardsEnabled = false;
//int titlecardSelection = 1;
int titlecardCycleStarted = 0;
boolean titlecardVisible = false;

PGraphics zoneA, zoneB, stage;
PGraphics upperVisual, lowerVisual;
PImage maskA, maskB;

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

float[][] contourElevation;
int contourCols, contourRows;
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

  loadSlides();

  zoneA = createGraphics(width, height);
  zoneB = createGraphics(width, height);
  stage = createGraphics(width, height);
  //zoneA = createGraphics(width, height, P2D);
  //zoneB = createGraphics(width, height, P2D);
  //stage = createGraphics(width, height, P2D);
  if (slides.size() == 0) {
    println("No matching image/mask pairs. Add JPGs to img_raw and matching PNGs to img_mask.");
    exit();
    return;
  }

  titleFont = createFont("Arial Italic", 48, true);

  startCameras();
  startSlide(0);
  lastFilterPick = millis();
  //lastTitleRotate = millis();
  contourPreviousTime = millis() / 1000.0;
  chooseSunsetColors();
  if (autoMode) pickFilter();
  titlecardCycleStarted = millis();

  // Open the separate slider/control window.
  panel = new ControlPanel();
  PApplet.runSketch(new String[] { "skysets controls" }, panel);
}

// Applies button/effect requests coming from the control panel thread.
void applyPanelRequests() {
  if (requestNextSlide) {
    requestNextSlide = false;
    startSlide((slideIndex + 1) % slides.size());
  }
  if (requestEffectA) {
    requestEffectA = false;
    effectA = chooseEffect(effectChoiceA, false, null);
    effectA.setup(this, lowerVisual.width, lowerVisual.height);
  }
  if (requestEffectB) {
    requestEffectB = false;
    effectB = chooseEffect(effectChoiceB, true, effectA.getName());
    effectB.setup(this, upperVisual.width, upperVisual.height);
  }
  if (requestFilter) {
    requestFilter = false;
    manualFilter = makeFilter(manualFilterChoice);
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

int millis0() {
  return millis();
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

  applyPanelRequests();

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

  if (autoMode && now - slideStarted >= slideMs) {
    startSlide((slideIndex + 1) % slides.size());
  }

  updateCameras();

  if (!filtersEnabled || !autoMode) {
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
  renderEffectZones();
  composeStage();

  PImage output = stage.get();
  for (int i = 0; i < runningFilters.size(); i++) {
    runningFilters.get(i).filter.apply(output);
  }
  if (!autoMode && filtersEnabled && manualFilter != null) manualFilter.apply(output);

  image(output, 0, 0, width, height);
  drawTitlecardOverlay();
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
  if (autoMode) cameraInA = random(1) < 0.5;

  PImage scaledMask = slides.get(slideIndex).mask.copy();
  scaledMask.resize(width, height);

  maskA = createImage(width, height, ALPHA);
  maskB = createImage(width, height, ALPHA);

  scaledMask.loadPixels();
  maskA.loadPixels();
  maskB.loadPixels();

  int highestA = height;
  int lowestB = -1;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int index = y * width + x;
      boolean isWhite = brightness(scaledMask.pixels[index]) >= 128;

      maskA.pixels[index] = isWhite ? color(255) : color(0);
      maskB.pixels[index] = isWhite ? color(0) : color(255);

      if (isWhite && y < highestA) highestA = y;
      if (!isWhite && y > lowestB) lowestB = y;
    }
  }

  maskA.updatePixels();
  maskB.updatePixels();

  // A/white's highest pixel anchors the top of the lower visual.
  // B/black's lowest pixel anchors the bottom of the upper visual.
  //lowerVisualTop = (highestA == height) ? height / 2 : highestA;
  //upperVisualBottom = (lowestB < 0) ? height / 2 : lowestB + 1;
  lowerVisualTop = (highestA == height) ? height / 2 : highestA;
  upperVisualBottom = (lowestB < 0) ? height / 2 : lowestB + 1;
  
  // Keep rendering surfaces within the window.
  lowerVisualTop = constrain(lowerVisualTop, 0, height - 1);
  upperVisualBottom = constrain(upperVisualBottom, 1, height);

  // Keep both rendering surfaces nonzero-sized for unusual/all-one-color masks.
  lowerVisualTop = constrain(lowerVisualTop, 0, height - 1);
  upperVisualBottom = constrain(upperVisualBottom, 1, height);

  int upperH = max(1, upperVisualBottom);
  int lowerH = max(1, height - lowerVisualTop);

  upperVisual = createGraphics(width, upperH);
  lowerVisual = createGraphics(width, lowerH);
  //upperVisual = createGraphics(width, upperH, P2D);
  //lowerVisual = createGraphics(width, lowerH, P2D);

// Effect A is assigned to the lower visual (A zone).
// Effect B is assigned to the upper visual (B zone).
effectA = chooseEffect(effectChoiceA, false, null);
effectB = chooseEffect(effectChoiceB, true, effectA.getName());

  effectA.setup(this, lowerVisual.width, lowerVisual.height);
  effectB.setup(this, upperVisual.width, upperVisual.height);

  println("Slide " + (slideIndex + 1) + "/" + slides.size() +
          ": " + slides.get(slideIndex).name +
          " | upper visual: 0-" + upperVisualBottom +
          " | lower visual: " + lowerVisualTop + "-" + height);
}

// ------------------------------------------------------------------
// CAMERA SUPPORT
// ------------------------------------------------------------------

boolean cameraReady(Capture c) {
  return c != null && c.width > 0 && c.height > 0 &&
         c.pixels != null && c.pixels.length > 0;
}

void startCameras() {
  try {
    String[] devices = Capture.list();

    println("Available cameras:");
    if (devices == null || devices.length == 0) {
      println("No cameras detected.");
      return;
    }

    printArray(devices);

    String device = devices[0];
    println("Attempting camera: " + device);

    Capture c = new Capture(this, 640, 480, device, 30);
    c.start();
    cameras.add(c);

    println("Camera start requested: " + device);
  }
  catch (Throwable t) {
    println("Camera initialization failed:");
    t.printStackTrace();
  }
}

void updateCameras() {
  for (int i = 0; i < cameras.size(); i++) {
    Capture c = cameras.get(i);
    try {
      if (c.available()) c.read();
    }
    catch (Throwable t) {
      println("Camera update failed:");
      t.printStackTrace();
    }
  }
}

void drawCameras(PGraphics pg) {
  pg.beginDraw();
  pg.background(0);

  ArrayList<Capture> ready = new ArrayList<Capture>();
  for (Capture c : cameras) {
    if (cameraReady(c)) ready.add(c);
  }

  if (ready.size() == 1) {
    drawCover(pg, ready.get(0), 0, 0, pg.width, pg.height);
  } else if (ready.size() >= 2) {
    drawCover(pg, ready.get(0), 0, 0, pg.width / 2, pg.height);
    drawCover(pg, ready.get(1), pg.width / 2, 0, pg.width / 2, pg.height);
  }

  pg.endDraw();
}

// Aspect-preserving cover: fills the target viewport without nonuniform stretching.
void drawCover(PGraphics pg, PImage img, float x, float y, float w, float h) {
  float scaleFactor = max(w / img.width, h / img.height);
  float drawW = img.width * scaleFactor;
  float drawH = img.height * scaleFactor;
  float drawX = x + (w - drawW) * 0.5;
  float drawY = y + (h - drawH) * 0.5;

  pg.pushStyle();
  pg.clip((int)x, (int)y, (int)w, (int)h);
  pg.image(img, drawX, drawY, drawW, drawH);
  pg.noClip();
  pg.popStyle();
}

// ------------------------------------------------------------------
// EFFECT RENDERING AND COMPOSITING
// ------------------------------------------------------------------

void renderEffectZones() {
  boolean hasCamera = false;
  for (Capture c : cameras) {
    if (useCamera && cameraReady(c)) {
      hasCamera = true;
      break;
    }
  }

  // Zone A is the lower visual region: its top edge is the highest
  // white/A mask pixel. Zone B is the upper visual region: its bottom
  // edge is the lowest/last black/B mask pixel.
  zoneA.beginDraw();
  zoneA.background(0);
  if (hasCamera && cameraInA) {
    // Camera is assigned to A; the mask clips it to the A silhouette.
    zoneA.endDraw();
  } else {
    zoneA.endDraw();
    //effectA.render(lowerVisual, millis() * 0.001);
    //zoneA.beginDraw();
    //zoneA.image(lowerVisual, 0, lowerVisualTop);
    //zoneA.endDraw();
    effectA.render(lowerVisual, millis() * 0.001);

    zoneA.beginDraw();
    zoneA.image(
      lowerVisual,
      0,
      lowerVisualTop,
      width,
      height - lowerVisualTop
    );
    zoneA.endDraw();
  }

  zoneB.beginDraw();
  zoneB.background(0);
  if (hasCamera && !cameraInA) {
    zoneB.endDraw();
  } else {
    zoneB.endDraw();
    effectB.render(upperVisual, millis() * 0.001);
    zoneB.beginDraw();
    zoneB.image(upperVisual, 0, 0);
    zoneB.endDraw();
  }

  if (hasCamera) {
    if (cameraInA) drawCameras(zoneA);
    else drawCameras(zoneB);
  }
}

void composeStage() {
  PImage a = zoneA.get();
  PImage b = zoneB.get();

  // Apply the corresponding masks.
  a.mask(maskA);
  b.mask(maskB);

  // Retrieve the original slide image.
  PImage raw = slides.get(slideIndex).image;

  // Composite the original image and both masked effect layers.
  stage.beginDraw();
  stage.background(0);
  stage.image(raw, 0, 0, width, height);
  stage.image(a, 0, 0, width, height);
  stage.image(b, 0, 0, width, height);
  stage.endDraw();
}

// ------------------------------------------------------------------
// FILTERS AND TITLECARDS
// ------------------------------------------------------------------

VisualFilter makeFilter(int n) {
  if (n == 1) return new InvertFilter();
  if (n == 2) return new GrayscaleFilter();
  if (n == 3) return new PosterizeFilter();
  if (n == 4) return new ScanlineFilter();
  return null;
}

void pickFilter() {
  VisualFilter f;
  int n = int(random(4));

  if (n == 0) f = new InvertFilter();
  else if (n == 1) f = new GrayscaleFilter();
  else if (n == 2) f = new PosterizeFilter();
  else f = new ScanlineFilter();

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
  textSize(max(height * 0.25, width * 0.045));
  text(titlecardNames[constrain(titlecardSelection, 1, titlecardNames.length) - 1],
       width / 2, height / 2);
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

class Slide {
  PImage image, mask;
  String name;
  Slide(PImage i, PImage m, String n) {
    image = i;
    mask = m;
    name = n;
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

// choice 0 = random (avoiding `avoid` if given), 1..9 = specific effect.
SkyEffect chooseEffect(int choice, boolean upperZone, String avoid) {
  if (choice <= 0) {
    return avoid == null ? randomEffect(upperZone) : randomEffectAvoiding(avoid, upperZone);
  }
  return randomEffect(upperZone, choice - 1);
}

SkyEffect randomEffect(boolean upperZone) {
  return randomEffect(upperZone, int(random(9)));
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
  else if (n == 7) effect = new AudioWaveEffect();
  else effect = new PlasmaMorphEffect();

  println("Selected Effect: " + effect.getName());
  return effect;
}

SkyEffect randomEffectAvoiding(String previous, boolean upperZone) {
  SkyEffect e = randomEffect(upperZone);

  for (int i = 0; i < 8 && e.getName().equals(previous); i++) {
    e = randomEffect(upperZone);
  }

  return e;
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

class ContourEffect implements SkyEffect {
  float[][] elevation;
  int cols, rows;
  int gridSpacing = 12;
  float terrainScale = 0.006;
  float terrainDetail = 0.5;

  public void setup(PApplet app, int w, int h) {
    //cols = w / gridSpacing + 2;
    //rows = h / gridSpacing + 2;
    //elevation = new float[cols][rows];

    // Add sufficient extra grid cells to extend contours
    // beyond the right and bottom edges of the rendering surface.
    cols = (int)Math.ceil(w / (float)gridSpacing) + 2;
    rows = (int)Math.ceil(h / (float)gridSpacing) + 2;

elevation = new float[cols][rows];

    app.noiseDetail(5, terrainDetail);
    for (int x = 0; x < cols; x++) {
      for (int y = 0; y < rows; y++) {
        elevation[x][y] = app.noise(
          x * gridSpacing * terrainScale,
          y * gridSpacing * terrainScale
        );
      }
    }
  }

  public String getName() { return "Contours"; }

  color getContourColor(float level) {
    float u = constrain(level / elevationDelta, 0, 1);
    int index = round(u * (RAMP_SIZE - 1));
    return contourColorRamp[index];
  }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    //p.background(30, 6, 15, 255);
    p.background(30, 6, 15);
    p.noFill();

    float interval = elevationDelta / max(1, contourSteps);
    for (int i = 0; i < contourSteps; i++) {
      float level = (i * interval + contourAnimationOffset) % elevationDelta;
      float threshold = level / elevationDelta;

      p.stroke(getContourColor(level));
      p.strokeWeight(2.0);

      for (int x = 0; x < cols - 1; x++) {
        for (int y = 0; y < rows - 1; y++) {
          drawCell(p, x, y, threshold);
        }
      }
    }

    p.endDraw();
  }

  void drawCell(PGraphics p, int x, int y, float threshold) {
    float v0 = elevation[x][y];
    float v1 = elevation[x + 1][y];
    float v2 = elevation[x + 1][y + 1];
    float v3 = elevation[x][y + 1];

    float px = x * gridSpacing;
    float py = y * gridSpacing;

    PVector[] intersections = new PVector[4];
    int count = 0;

    if ((v0 < threshold) != (v1 < threshold)) {
      intersections[count++] = interpolate(px, py, px + gridSpacing, py,
                                             v0, v1, threshold);
    }
    if ((v1 < threshold) != (v2 < threshold)) {
      intersections[count++] = interpolate(px + gridSpacing, py,
                                             px + gridSpacing, py + gridSpacing,
                                             v1, v2, threshold);
    }
    if ((v2 < threshold) != (v3 < threshold)) {
      intersections[count++] = interpolate(px + gridSpacing, py + gridSpacing,
                                             px, py + gridSpacing,
                                             v2, v3, threshold);
    }
    if ((v3 < threshold) != (v0 < threshold)) {
      intersections[count++] = interpolate(px, py + gridSpacing,
                                             px, py, v3, v0, threshold);
    }

    if (count == 2) {
      p.line(intersections[0].x, intersections[0].y,
             intersections[1].x, intersections[1].y);
    } else if (count == 4) {
      float center = (v0 + v1 + v2 + v3) / 4.0;

      if (center >= threshold) {
        p.line(intersections[0].x, intersections[0].y,
               intersections[1].x, intersections[1].y);
        p.line(intersections[2].x, intersections[2].y,
               intersections[3].x, intersections[3].y);
      } else {
        p.line(intersections[0].x, intersections[0].y,
               intersections[3].x, intersections[3].y);
        p.line(intersections[1].x, intersections[1].y,
               intersections[2].x, intersections[2].y);
      }
    }
  }

  PVector interpolate(float x1, float y1, float x2, float y2,
                       float v1, float v2, float threshold) {
    float denominator = v2 - v1;
    float u = abs(denominator) < 0.000001 ? 0.5 : (threshold - v1) / denominator;
    u = constrain(u, 0, 1);
    return new PVector(lerp(x1, x2, u), lerp(y1, y2, u));
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
class SignalGlitchEffect implements SkyEffect {
  int effectW, effectH;

  public void setup(PApplet app, int w, int h) {
    effectW = w;
    effectH = h;
  }

  public String getName() { return "Signal Glitch"; }

  public void render(PGraphics p, float t) {
    p.beginDraw();
    p.background(7, 8, 19);
    p.noStroke();

    // Slow moving color field.
    for (int band = 0; band < 18; band++) {
      float y = (band / 18.0) * effectH;
      float wave = sin(t * 1.4 + band * 0.73);
      float x = effectW * (0.08 + 0.08 * wave);
      float w = effectW * (0.35 + 0.28 * (0.5 + 0.5 * cos(t + band)));
      p.fill(sunsetColor(band, 28 + (band % 4) * 12));
      p.rect(x, y, w, max(2, effectH / 26.0));
    }

    // Repeating signal tears; their positions are deterministic and allocation-free.
    for (int tear = 0; tear < 9; tear++) {
      float pulse = sin(t * (2.0 + tear * 0.17) + tear * 4.1);
      if (pulse > 0.82) {
        float y = (0.08 + 0.84 * ((tear * 0.137 + t * 0.035) % 1.0)) * effectH;
        float shift = pulse * effectW * 0.12;
        float h = max(2, effectH * (0.006 + (tear % 3) * 0.003));
        p.fill(255, 45, 75, 170);
        p.rect(shift, y, effectW * 0.72, h);
        p.fill(30, 220, 255, 150);
        p.rect(-shift * 0.55, y + h, effectW * 0.58, h * 0.8);
      }
    }

    p.stroke(255, 36);
    p.strokeWeight(1);
    for (int y = 0; y < effectH; y += 5) {
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
    p.pushMatrix();
    p.translate(effectW * 0.5, effectH * 0.5);
    p.rotate(t * 0.12);
    p.noFill();

    float maxR = min(effectW, effectH) * 0.49;
    for (int ring = 0; ring < RINGS; ring++) {
      float radius = maxR * (ring + 1) / RINGS;
      float twist = sin(t * 0.38 + ring * 0.42) * 0.16;
      p.stroke(sunsetColor(ring * 2, 170));
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
    p.endDraw();
  }
}

/**
 * AudioWaveEffect
 * Microphone amplitude drives waveform displacement and pulse size. Requires
 * the Processing Sound library. The input/analyzer is shared across instances.
 */
class AudioWaveEffect implements SkyEffect {
  int effectW, effectH;
  float smoothedLevel = 0;

  public void setup(PApplet app, int w, int h) {
    effectW = w;
    effectH = h;

    if (!audioInitialized) {
      try {
        audioInput = new AudioIn(app, 0);
        audioAmplitude = new Amplitude(app);
        audioInput.start();
        audioAmplitude.input(audioInput);
        audioInitialized = true;
        println("Audio input initialized.");
      }
      catch (Throwable ex) {
        println("Audio input unavailable; Audio Wave will use its idle animation.");
        ex.printStackTrace();
        audioInitialized = false;
      }
    }
  }

  public String getName() { return "Audio Wave"; }

  public void render(PGraphics p, float t) {
    float level = 0;
    if (audioInitialized && audioAmplitude != null) {
      try {
        level = constrain(audioAmplitude.analyze() * 5.0, 0, 1);
      }
      catch (Throwable ex) {
        level = 0;
      }
    }
    smoothedLevel += (level - smoothedLevel) * 0.22;
    float energy = smoothedLevel;

    p.beginDraw();
    p.background(13, 5, 20);
    p.noFill();

    for (int layer = 0; layer < 8; layer++) {
      float baseY = effectH * (0.22 + layer * 0.08);
      float amp = effectH * (0.025 + energy * 0.24) * (1.0 - layer * 0.055);
      p.stroke(sunsetColor(layer * 2, 190));
      p.strokeWeight(1.5 + energy * 2.0);
      p.beginShape();
      for (int x = 0; x <= effectW; x += 8) {
        float phase = x * 0.012 + t * (1.1 + layer * 0.035);
        float y = baseY + sin(phase + layer * 0.42) * amp
                         + sin(phase * 0.47 - t) * amp * 0.38;
        p.vertex(x, y);
      }
      p.endShape();
    }

    p.noStroke();
    int bars = 42;
    float barW = effectW / (float)bars;
    for (int i = 0; i < bars; i++) {
      float pulse = 0.12 + energy * 0.88;
      float h = effectH * pulse *
        (0.025 + 0.13 * abs(sin(i * 0.31 + t * 1.8)));
      p.fill(sunsetColor(i, 150));
      p.rect(i * barW, effectH - h, max(1, barW - 2), h);
    }
    p.endDraw();
  }
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

class InvertFilter implements VisualFilter {
  public String getName() { return "Invert"; }
  public void apply(PImage p) { p.filter(INVERT); }
}

class GrayscaleFilter implements VisualFilter {
  public String getName() { return "Grayscale"; }
  public void apply(PImage p) { p.filter(GRAY); }
}

class PosterizeFilter implements VisualFilter {
  public String getName() { return "Posterize"; }
  public void apply(PImage p) { p.filter(POSTERIZE, 4); }
}

class ScanlineFilter implements VisualFilter {
  public String getName() { return "Scanlines"; }

  public void apply(PImage p) {
    p.loadPixels();
    for (int y = 1; y < p.height; y += 3) {
      for (int x = 0; x < p.width; x++) {
        int i = y * p.width + x;
        int c = p.pixels[i];
        p.pixels[i] = color(red(c) * 0.68, green(c) * 0.68,
                            blue(c) * 0.68, alpha(c));
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

color sunsetColor(int index, int alphaValue) {
  color c = SUNSET_PALETTE[index % SUNSET_PALETTE.length];
  return color(red(c), green(c), blue(c), alphaValue);
}

void updateContourClock() {
  float now = millis() / 1000.0;
  float elapsed = max(0, now - contourPreviousTime);
  contourPreviousTime = now;

  if (!contoursPaused) {
    float intervalSize = elevationDelta / max(1, contourSteps);
    float movement = intervalSize * elapsed / max(0.05, secondsPerStep);
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

// Shared by the main window and the control panel window.
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

// ------------------------------------------------------------------
// CONTROL PANEL WINDOW — sliders, toggles and buttons for every control.
// ------------------------------------------------------------------

class ControlPanel extends PApplet {
  static final int SLIDER = 0, TOGGLE = 1, BUTTON = 2, HEADER = 3, CHOICE = 4, COLUMN = 5;

  class Widget {
    int type;
    String id, label;
    float min, max;
    boolean isInt;
    String[] options;   // CHOICE only
    int cols = 3;       // CHOICE only
    float x, y, w, h;
    Widget(int type, String id, String label, float min, float max, boolean isInt) {
      this.type = type; this.id = id; this.label = label;
      this.min = min; this.max = max; this.isInt = isInt;
    }
    boolean hit(float mx, float my) {
      return mx >= x && mx <= x + w && my >= y && my <= y + h;
    }
    // CHOICE: index of the option cell under (mx, my), or -1.
    int cellAt(float mx, float my) {
      for (int i = 0; i < options.length; i++) {
        float[] r = cellRect(i);
        if (mx >= r[0] && mx <= r[0] + r[2] && my >= r[1] && my <= r[1] + r[3]) return i;
      }
      return -1;
    }
    float[] cellRect(int i) {
      float gap = 6;
      float cw = (w - gap * (cols - 1)) / cols;
      int c = i % cols, r = i / cols;
      return new float[] { x + c * (cw + gap), y + r * (CELL_H + gap), cw, CELL_H };
    }
  }

  ArrayList<Widget> widgets = new ArrayList<Widget>();
  Widget dragging = null;
  final int PAD = 18, COL_W = 330, CELL_H = 28;
  int panelW, panelH;

  public void settings() {
    buildWidgets();
    size(panelW, panelH);
  }

  public void setup() {
    surface.setTitle("skysets controls");
    surface.setAlwaysOnTop(true);
    surface.setLocation(40, 60);
    textFont(createFont("SansSerif", 13, true));
  }

  Widget add(int type, String id, String label, float min, float max, boolean isInt) {
    Widget wd = new Widget(type, id, label, min, max, isInt);
    widgets.add(wd);
    return wd;
  }

  void choice(String id, String label, String[] options, int cols) {
    Widget wd = add(CHOICE, id, label, 0, options.length - 1, true);
    wd.options = options;
    wd.cols = cols;
  }

  void buildWidgets() {
    // ---- Left column
    add(HEADER, "", "TITLECARDS", 0, 0, false);
    add(TOGGLE, "tc_on", "Titlecards on   ( ` )", 0, 1, false);
    choice("tc_sel", "Titlecard   (1–6)", titlecardNames, 3);
    add(SLIDER, "tc_vis", "Visible seconds", 1, 120, true);
    add(SLIDER, "tc_hid", "Hidden seconds   (0 = always on)", 0, 120, true);

    add(HEADER, "", "SCENE", 0, 0, false);
    add(TOGGLE, "auto", "Auto switching (timed)", 0, 1, false);
    add(SLIDER, "slide_s", "Auto: seconds per slide", 5, 120, true);
    add(TOGGLE, "cam", "Camera on", 0, 1, false);
    add(TOGGLE, "camA", "Camera in lower zone", 0, 1, false);
    add(TOGGLE, "filters", "Color filters on", 0, 1, false);
    choice("filter", "Filter", FILTER_NAMES, 3);

    // ---- Right column
    add(COLUMN, "", "", 0, 0, false);
    add(HEADER, "", "EFFECTS", 0, 0, false);
    choice("effA", "Lower zone effect", EFFECT_NAMES, 3);
    choice("effB", "Upper zone effect", EFFECT_NAMES, 3);

    add(HEADER, "", "CONTOURS", 0, 0, false);
    add(TOGGLE, "paused", "Paused   (Space)", 0, 1, false);
    add(TOGGLE, "uphill", "Uphill   (D)", 0, 1, false);
    add(SLIDER, "speed", "Seconds per step   (Up/Down)", 0.25, 10, false);
    add(SLIDER, "steps", "Contour count   (+/-)", 1, 60, true);
    add(BUTTON, "reset", "Reset animation   (R)", 0, 0, false);
    add(BUTTON, "colors", "New sunset colors   (C)", 0, 0, false);

    float colX = PAD, y = PAD, maxY = 0;
    for (Widget wd : widgets) {
      if (wd.type == COLUMN) {
        maxY = max(maxY, y);
        colX += COL_W + PAD * 2;
        y = PAD;
        continue;
      }
      wd.x = colX;
      wd.w = COL_W;
      if (wd.type == HEADER) {
        wd.y = y + 6; wd.h = 22; y += 32;
      } else if (wd.type == SLIDER) {
        wd.y = y + 20; wd.h = 14; y += 46;
      } else if (wd.type == CHOICE) {
        int rows = (wd.options.length + wd.cols - 1) / wd.cols;
        wd.y = y + 22;
        wd.h = rows * CELL_H + (rows - 1) * 6;
        y += 22 + wd.h + 12;
      } else {
        wd.y = y; wd.h = 28; y += 36;
      }
    }
    maxY = max(maxY, y);
    panelW = (int)(colX + COL_W + PAD);
    panelH = (int)(maxY + PAD);
  }

  float getValue(String id) {
    if (id.equals("tc_on")) return titlecardsEnabled ? 1 : 0;
    if (id.equals("tc_sel")) return titlecardSelection - 1;
    if (id.equals("tc_vis")) return titlecardVisibleMs / 1000.0;
    if (id.equals("tc_hid")) return titlecardHiddenMs / 1000.0;
    if (id.equals("slide_s")) return slideMs / 1000.0;
    if (id.equals("effA")) return effectChoiceA;
    if (id.equals("effB")) return effectChoiceB;
    if (id.equals("cam")) return useCamera ? 1 : 0;
    if (id.equals("camA")) return cameraInA ? 1 : 0;
    if (id.equals("filters")) return filtersEnabled ? 1 : 0;
    if (id.equals("auto")) return autoMode ? 1 : 0;
    if (id.equals("filter")) return manualFilterChoice;
    if (id.equals("paused")) return contoursPaused ? 1 : 0;
    if (id.equals("uphill")) return uphill ? 1 : 0;
    if (id.equals("speed")) return secondsPerStep;
    if (id.equals("steps")) return contourSteps;
    return 0;
  }

  void setValue(String id, float v) {
    int iv = round(v);
    if (id.equals("tc_on")) setTitlecardsEnabled(v > 0.5);
    else if (id.equals("tc_sel")) titlecardSelection = iv + 1;
    else if (id.equals("tc_vis")) titlecardVisibleMs = iv * 1000;
    else if (id.equals("tc_hid")) titlecardHiddenMs = iv * 1000;
    else if (id.equals("slide_s")) slideMs = iv * 1000;
    else if (id.equals("effA")) { effectChoiceA = iv; requestEffectA = true; }
    else if (id.equals("effB")) { effectChoiceB = iv; requestEffectB = true; }
    else if (id.equals("cam")) useCamera = v > 0.5;
    else if (id.equals("camA")) cameraInA = v > 0.5;
    else if (id.equals("filters")) filtersEnabled = v > 0.5;
    else if (id.equals("auto")) { autoMode = v > 0.5; slideStarted = millis0(); }
    else if (id.equals("filter")) { manualFilterChoice = iv; requestFilter = true; }
    else if (id.equals("paused")) contoursPaused = v > 0.5;
    else if (id.equals("uphill")) uphill = v > 0.5;
    else if (id.equals("speed")) secondsPerStep = v;
    else if (id.equals("steps")) contourSteps = iv;
  }

  void press(String id) {
    if (id.equals("next")) requestNextSlide = true;
    else if (id.equals("reset")) requestResetContours = true;
    else if (id.equals("colors")) requestNewColors = true;
  }

  String valueText(Widget wd, float v) {
    if (wd.id.equals("tc_hid") && round(v) == 0) return "always on";
    return wd.isInt ? str(round(v)) : nf(v, 1, 2);
  }

  // Extra note shown next to a CHOICE label.
  String choiceNote(Widget wd) {
    boolean camHere = useCamera && cameras.size() > 0;
    if (wd.id.equals("effA") && camHere && cameraInA) return "hidden: camera in this zone";
    if (wd.id.equals("effB") && camHere && !cameraInA) return "hidden: camera in this zone";
    if (wd.id.equals("filter") && autoMode) return "auto mode picks filters";
    return "";
  }

  public void draw() {
    background(24, 22, 28);
    for (Widget wd : widgets) {
      if (wd.type == HEADER) {
        fill(255, 150, 70);
        textAlign(LEFT, CENTER);
        text(wd.label, wd.x, wd.y + wd.h / 2);
        stroke(70);
        line(wd.x, wd.y + wd.h, wd.x + wd.w, wd.y + wd.h);
        noStroke();
      } else if (wd.type == SLIDER) {
        float v = getValue(wd.id);
        float t = constrain((v - wd.min) / (wd.max - wd.min), 0, 1);
        fill(220);
        textAlign(LEFT, BOTTOM);
        text(wd.label, wd.x, wd.y - 4);
        textAlign(RIGHT, BOTTOM);
        fill(255, 190, 90);
        text(valueText(wd, v), wd.x + wd.w, wd.y - 4);
        noStroke();
        fill(60, 56, 70);
        rect(wd.x, wd.y + wd.h / 2 - 3, wd.w, 6, 3);
        fill(240, 120, 60);
        rect(wd.x, wd.y + wd.h / 2 - 3, wd.w * t, 6, 3);
        fill(dragging == wd ? 255 : 235);
        ellipse(wd.x + wd.w * t, wd.y + wd.h / 2, 16, 16);
      } else if (wd.type == CHOICE) {
        int sel = round(getValue(wd.id));
        fill(220);
        textAlign(LEFT, BOTTOM);
        text(wd.label, wd.x, wd.y - 5);
        String note = choiceNote(wd);
        if (note.length() > 0) {
          fill(255, 190, 90);
          textAlign(RIGHT, BOTTOM);
          text(note, wd.x + wd.w, wd.y - 5);
        }
        int hover = wd.cellAt(mouseX, mouseY);
        textAlign(CENTER, CENTER);
        noStroke();
        for (int i = 0; i < wd.options.length; i++) {
          float[] r = wd.cellRect(i);
          if (i == sel) fill(240, 120, 60);
          else if (i == hover) fill(80, 74, 92);
          else fill(52, 48, 62);
          rect(r[0], r[1], r[2], r[3], 5);
          fill(i == sel ? 20 : 225);
          text(wd.options[i], r[0] + r[2] / 2, r[1] + r[3] / 2);
        }
      } else if (wd.type == TOGGLE) {
        boolean on = getValue(wd.id) > 0.5;
        noStroke();
        fill(on ? color(240, 120, 60) : color(60, 56, 70));
        rect(wd.x, wd.y + 4, 40, 20, 10);
        fill(245);
        ellipse(on ? wd.x + 30 : wd.x + 10, wd.y + 14, 16, 16);
        fill(220);
        textAlign(LEFT, CENTER);
        text(wd.label + (on ? "   ON" : "   OFF"), wd.x + 52, wd.y + 14);
      } else if (wd.type == BUTTON) {
        boolean hover = wd.hit(mouseX, mouseY);
        fill(hover && mousePressed ? color(240, 120, 60) : hover ? color(80, 74, 92) : color(60, 56, 70));
        noStroke();
        rect(wd.x, wd.y, wd.w, wd.h, 6);
        fill(235);
        textAlign(CENTER, CENTER);
        text(wd.label, wd.x + wd.w / 2, wd.y + wd.h / 2);
      }
    }
  }

  void dragTo(Widget wd, float mx) {
    float t = constrain((mx - wd.x) / wd.w, 0, 1);
    float v = wd.min + t * (wd.max - wd.min);
    if (wd.isInt) v = round(v);
    setValue(wd.id, v);
  }

  public void mousePressed() {
    for (Widget wd : widgets) {
      if (wd.type == SLIDER && mouseX >= wd.x - 8 && mouseX <= wd.x + wd.w + 8 &&
          mouseY >= wd.y - 22 && mouseY <= wd.y + wd.h + 6) {
        dragging = wd;
        dragTo(wd, mouseX);
        return;
      }
      if (wd.type == CHOICE) {
        int i = wd.cellAt(mouseX, mouseY);
        if (i >= 0) {
          setValue(wd.id, i);   // one click = one change, no drag-through
          return;
        }
      }
      if (wd.type == TOGGLE && wd.hit(mouseX, mouseY)) {
        setValue(wd.id, getValue(wd.id) > 0.5 ? 0 : 1);
        return;
      }
      if (wd.type == BUTTON && wd.hit(mouseX, mouseY)) {
        press(wd.id);
        return;
      }
    }
  }

  public void mouseDragged() {
    if (dragging != null) dragTo(dragging, mouseX);
  }

  public void mouseReleased() {
    dragging = null;
  }

  public void keyPressed() {
    if (key == ESC) key = 0;
    handleControlKey(key == 0 ? ESC : key, keyCode);
  }
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

void stop() {
  for (Capture c : cameras) {
    try {
      c.stop();
    }
    catch (Throwable t) {
    }
  }
  super.stop();
}
