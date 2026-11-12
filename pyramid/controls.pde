// Control window: sliders for the shader parameters.
//
// Opens as a second window next to the sketch. Drag a slider to change a
// value live; double-click a slider to reset it; press R in the control
// window to reset everything. Values are saved to params.json in the sketch
// folder whenever you let go of a slider, and loaded again on the next run.
// Closing the control window only hides it.

import java.util.LinkedHashMap;

class Param {
  String section, key, label;
  float min, max, def, value, step;
  Param(String section, String key, String label, float min, float max, float def, float step) {
    this.section = section; this.key = key; this.label = label;
    this.min = min; this.max = max; this.def = def; this.value = def; this.step = step;
  }
  void set(float v) {
    v = constrain(v, min, max);
    if (step > 0) v = min + round((v - min) / step) * step;
    value = v;
  }
}

LinkedHashMap<String, Param> params = new LinkedHashMap<String, Param>();
final String PARAMS_FILE = "params.json";

void addParam(String section, String key, String label, float min, float max, float def, float step) {
  params.put(key, new Param(section, key, label, min, max, def, step));
}

float P(String key) {
  return params.get(key).value;
}

void defineParams() {
  // Contour lines (count follows the low band between these two)
  addParam("Contour lines", "levelsMin", "levels at silence", 1, 60, 10, 1);
  addParam("Contour lines", "levelsMax", "levels at low peak", 1, 60, 20, 1);
  addParam("Contour lines", "peakDecay", "range adapt (s)", 1, 30, 10, 0);
  addParam("Contour lines", "majorEvery", "major line every", 0, 10, 5, 1);
  addParam("Contour lines", "misregX", "misregister x (px)", -5, 5, 1.5, 0);
  addParam("Contour lines", "misregY", "misregister y (px)", -5, 5, -1.0, 0);

  // Fill
  addParam("Fill", "accentLo", "accent band low", 0, 1, 0.57, 0);
  addParam("Fill", "accentHi", "accent band high", 0, 1, 0.60, 0);
  addParam("Fill", "shadowLevel", "shadow level", 0, 1, 0.12, 0);
  addParam("Fill", "halftoneSize", "halftone size (px)", 1, 12, 1.0, 0);
  addParam("Fill", "halftoneAngle", "halftone angle (rad)", 0, 1.571, 0.26, 0);
  addParam("Fill", "inkLow", "ink low ground", 0, 1, 0.1, 0);
  addParam("Fill", "inkHigh", "ink high ground", 0, 1, 0.0, 0);
  addParam("Fill", "bandMix", "band mix", 0, 1, 0.0, 0);
  addParam("Fill", "gritMix", "grit mix", 0, 1, 1.0, 0);

  // Water noise (the height field under the map)
  addParam("Noise", "noiseXLow0", "noise x at low 0", 0, 4, 4.0, 0);
  addParam("Noise", "noiseXLow1", "noise x at low 1", 0, 4, 0.0, 0);
  addParam("Noise", "noiseYLow0", "noise y at low 0", 0, 4, 4.0, 0);
  addParam("Noise", "noiseYLow1", "noise y at low 1", 0, 4, 0.0, 0);
  addParam("Noise", "noiseSpeed", "noise speed", 0, 2, 0.3, 0);
  addParam("Noise", "contrastMin", "contrast at silence", 0, 4, 0.5, 0);
  addParam("Noise", "contrastMax", "contrast at mid peak", 0, 4, 1.5, 0);
}

void loadParams() {
  File f = new File(sketchPath(PARAMS_FILE));
  if (!f.exists()) return;
  try {
    JSONObject j = loadJSONObject(f.getAbsolutePath());
    for (Param p : params.values()) {
      if (j.hasKey(p.key)) p.set(j.getFloat(p.key));
    }
    println("controls: loaded " + PARAMS_FILE);
  } catch (Exception e) {
    println("controls: couldn't read " + PARAMS_FILE + " (" + e.getMessage() + "), using defaults");
  }
}

void saveParams() {
  JSONObject j = new JSONObject();
  for (Param p : params.values()) j.setFloat(p.key, p.value);
  saveJSONObject(j, sketchPath(PARAMS_FILE));
}

// Push the slider values into the shaders (called every frame from draw()).
void applyParams() {
  topo.set("majorEvery", P("majorEvery"));
  topo.set("misregister", P("misregX"), P("misregY"));
  topo.set("accentBand", P("accentLo"), P("accentHi"));
  topo.set("shadowLevel", P("shadowLevel"));
  topo.set("halftoneSize", P("halftoneSize"));
  topo.set("halftoneAngle", P("halftoneAngle"));
  topo.set("inkLow", P("inkLow"));
  topo.set("inkHigh", P("inkHigh"));
  topo.set("bandMix", P("bandMix"));
  topo.set("gritMix", P("gritMix"));

  binning.set("noiseFactor", noiseXNow, noiseYNow);   // low band -> x, y (pyramid.pde)
  binning.set("noiseFactorTime", P("noiseSpeed"));
  binning.set("contastfactor", contrastNow);   // mid band -> contrast (pyramid.pde)
}

void openControls() {
  PApplet.runSketch(new String[] { "Controls" }, new ControlWindow());
}

class ControlWindow extends PApplet {
  final int W = 460, PAD = 14, ROW = 26, HEAD = 24, LABEL_W = 150, VAL_W = 52;
  Param dragging = null;
  int lastClick = 0;
  Param lastClicked = null;
  ArrayList<Object> rows = new ArrayList<Object>();  // String = section header, Param = slider
  int[] rowY;

  public void settings() {
    String section = "";
    int h = PAD + 22;
    for (Param p : params.values()) {
      if (!p.section.equals(section)) { section = p.section; rows.add(section); h += HEAD; }
      rows.add(p); h += ROW;
    }
    // P2D like the main sketch: a JAVA2D (AWT) window created from the P2D
    // sketch's thread deadlocks on macOS.
    size(W, h + PAD + 18, P2D);
  }

  public void setup() {
    surface.setTitle("pyramid controls");
    textFont(createFont("SansSerif", 12));
    rowY = new int[rows.size()];
    int y = PAD + 22;
    for (int i = 0; i < rows.size(); i++) {
      rowY[i] = y;
      y += rows.get(i) instanceof String ? HEAD : ROW;
    }
  }

  float trackX0() { return PAD + LABEL_W; }
  float trackX1() { return W - PAD - VAL_W; }

  public void draw() {
    background(24);
    fill(230);
    textAlign(LEFT, CENTER);
    text("low " + nf(low, 1, 2) + "  levels " + nf(levelsNow, 2, 1)
      + "  noise " + nf(noiseXNow, 1, 2) + "/" + nf(noiseYNow, 1, 2)
      + "    mid " + nf(mid, 1, 2) + "  contrast " + nf(contrastNow, 1, 2), PAD, PAD + 6);
    for (int i = 0; i < rows.size(); i++) {
      Object r = rows.get(i);
      int y = rowY[i];
      if (r instanceof String) {
        fill(150);
        text(((String) r).toUpperCase(), PAD, y + HEAD / 2 + 2);
        continue;
      }
      Param p = (Param) r;
      float cy = y + ROW / 2;
      fill(210);
      text(p.label, PAD, cy);
      float x0 = trackX0(), x1 = trackX1();
      float t = (p.value - p.min) / (p.max - p.min);
      noStroke();
      fill(60);
      rect(x0, cy - 3, x1 - x0, 6, 3);
      fill(p == dragging ? color(255, 170, 60) : color(245, 130, 30));
      rect(x0, cy - 3, (x1 - x0) * t, 6, 3);
      // default marker
      float dx = x0 + (x1 - x0) * (p.def - p.min) / (p.max - p.min);
      fill(120);
      rect(dx - 1, cy - 7, 2, 14);
      fill(255);
      ellipse(x0 + (x1 - x0) * t, cy, 12, 12);
      fill(230);
      textAlign(RIGHT, CENTER);
      text(p.step >= 1 ? str(round(p.value)) : nf(p.value, 1, 2), W - PAD, cy);
      textAlign(LEFT, CENTER);
    }
    fill(110);
    text("drag to change · double-click resets · R resets all", PAD, height - PAD);
  }

  Param paramAt(int mx, int my) {
    for (int i = 0; i < rows.size(); i++) {
      if (rows.get(i) instanceof Param && my >= rowY[i] && my < rowY[i] + ROW
          && mx >= trackX0() - 8 && mx <= trackX1() + 8) {
        return (Param) rows.get(i);
      }
    }
    return null;
  }

  void setFromMouse(Param p, int mx) {
    float t = constrain((mx - trackX0()) / (trackX1() - trackX0()), 0, 1);
    p.set(p.min + t * (p.max - p.min));
  }

  public void mousePressed() {
    Param p = paramAt(mouseX, mouseY);
    if (p == null) return;
    if (p == lastClicked && millis() - lastClick < 350) {
      p.set(p.def);
      saveParams();
      lastClicked = null;
      return;
    }
    lastClicked = p;
    lastClick = millis();
    dragging = p;
    setFromMouse(p, mouseX);
  }

  public void mouseDragged() {
    if (dragging != null) setFromMouse(dragging, mouseX);
  }

  public void mouseReleased() {
    if (dragging != null) saveParams();
    dragging = null;
  }

  public void keyPressed() {
    if (key == 'r' || key == 'R') {
      for (Param p : params.values()) p.set(p.def);
      saveParams();
    }
  }

  // Closing the control window just hides it; the sketch keeps running.
  public void exit() {
    surface.setVisible(false);
  }
}
