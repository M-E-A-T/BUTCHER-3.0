// ---------- Control panel (separate Swing window) ----------
// Its own native window, independent of the OpenGL sketch window.
// TAB or h (in the sketch window) shows/hides it. Right-click a slider to reset it.

class Param {
  String key, label;
  float min, max, def, val;
  boolean isInt;
  Param(String key, String label, float min, float max, float def, boolean isInt) {
    this.key = key; this.label = label; this.min = min; this.max = max;
    this.def = def; this.val = def; this.isInt = isInt;
  }
  void set(float v) {
    val = constrain(v, min, max);
    if (isInt) val = round(val);
  }
}

class Toggle {
  String key, label;
  boolean def, val;
  Toggle(String key, String label, boolean def) {
    this.key = key; this.label = label; this.def = def; this.val = def;
  }
}

HashMap<String, Param> params = new HashMap<String, Param>();
HashMap<String, Toggle> toggles = new HashMap<String, Toggle>();

float P(String k) { return params.get(k).val; }
boolean B(String k) { return toggles.get(k).val; }

// Layout: each entry is "#Header", "p:key", "t:key", or "b:action|Label"
String[][] layout = {
  { "#SHAPE",
    "p:zoom", "p:detail", "p:octaves", "p:warp", "p:warpFreq",
    "p:density", "p:thickness", "p:softness", "p:minCoverage",
    "t:rotate",
    "#MOTION",
    "p:speed", "p:lineSpeed", "p:drift", "p:onsetMotion", "p:hideAfter", "p:silenceLevel" },
  { "#COLOR",
    "p:colorSpeed", "p:colorBands", "p:sparks", "p:sparkRadius",
    "p:autoShuffle", "p:paletteFade",
    "t:hardColors", "t:pingpong",
    "#OVERLAY",
    "p:opacity", "b:mode|Blend mode", "t:invert",
    "#CAMERA",
    "p:camBright", "p:camWarm", "t:mirror" }
};

void addP(String k, String label, float mn, float mx, float def) { params.put(k, new Param(k, label, mn, mx, def, false)); }
void addI(String k, String label, float mn, float mx, float def) { params.put(k, new Param(k, label, mn, mx, def, true)); }
void addT(String k, String label, boolean def) { toggles.put(k, new Toggle(k, label, def)); }

{
  // Defaults match the sketch as it looked before the panel existed
  addP("zoom",        "Zoom (pattern scale)",    1,    30,   8);
  addP("detail",      "Feature size",            0.05, 2,    0.4);
  addI("octaves",     "Roughness (octaves)",     1,    8,    5);
  addP("warp",        "Warp amount",             0,    1.5,  0.05);
  addP("warpFreq",    "Warp frequency",          0,    6,    1);
  addP("density",     "Line density",            0.2,  12,   2);
  addP("thickness",   "Line thickness",          0,    0.9,  0.09);
  addP("softness",    "Edge softness",           0,    0.5,  0.03);
  addP("minCoverage", "Min screen coverage",     0,    0.6,  0.15);
  addP("speed",       "Overall speed",           0,    3,    0.5);
  addP("lineSpeed",   "Line travel speed",       -10,  10,   3);
  addP("drift",       "Shape drift speed",       0,    2,    0.3);
  addP("onsetMotion", "Motion after onset (s)",  0,    3,    0.6);
  addP("hideAfter",   "Hide after no hits (s)",  0,    10,   2);
  addP("silenceLevel","Silence level",           0,    0.3,  0.03);

  addP("colorSpeed",  "Color cycle speed",       0,    2,    0.2);
  addP("colorBands",  "Colors on screen",        0.2,  8,    1);
  addP("sparks",      "Sparks amount",           0,    1,    0.1);
  addP("sparkRadius", "Spark reach",             0,    3,    0.9);
  addP("autoShuffle", "Auto-shuffle every (s)",  0,    30,   0);
  addP("paletteFade", "Shuffle fade time (s)",   0,    5,    1);

  addP("opacity",     "Overlay opacity",         0,    1,    1);

  addP("camBright",   "Camera brightness",       0,    1.5,  1);
  addP("camWarm",     "Camera warm tint",        0,    1,    0);

  addT("rotate",      "Rotate pattern 90°",      true);
  addT("hardColors",  "Hard color blocks",       false);
  addT("pingpong",    "Sweep back & forth",      true);
  addT("invert",      "Invert mask",             false);
  addT("mirror",      "Mirror camera",           true);
}

void resetAll() {
  for (Param p : params.values()) p.val = p.def;
  for (Toggle tg : toggles.values()) tg.val = tg.def;
  modeIndex = 0;
}

void randomizeLook() {
  // thickness/softness are left alone so the lines cover the same amount of screen
  String[] keys = { "zoom", "detail", "octaves", "warp", "warpFreq", "density",
                    "lineSpeed", "drift", "colorSpeed", "colorBands" };
  for (String k : keys) {
    Param p = params.get(k);
    p.set(random(p.min, lerp(p.min, p.max, 0.6)));   // keep within the saner part of each range
  }
  toggles.get("hardColors").val = random(1) < 0.3;
  newPattern();
  shufflePalette();
}

void savePreset() {
  JSONObject j = new JSONObject();
  for (Param p : params.values()) j.setFloat(p.key, p.val);
  for (Toggle tg : toggles.values()) j.setBoolean(tg.key, tg.val);
  j.setInt("mode", modeIndex);
  j.setFloat("seedX", seedX); j.setFloat("seedY", seedY); j.setFloat("angle", angle);
  JSONArray pal = new JSONArray();
  for (int i = 0; i < 5; i++) pal.setString(i, "#" + hex(sunset[i], 6));
  j.setJSONArray("palette", pal);
  String name = "presets/preset-" + nf(year(), 4) + nf(month(), 2) + nf(day(), 2) + "-" + nf(hour(), 2) + nf(minute(), 2) + nf(second(), 2) + ".json";
  saveJSONObject(j, sketchPath(name));
  saveJSONObject(j, sketchPath("presets/latest.json"));
  println("Saved " + name);
}

void loadPreset() {
  File f = new File(sketchPath("presets/latest.json"));
  if (!f.exists()) { println("No preset saved yet."); return; }
  JSONObject j = loadJSONObject(f);
  for (Param p : params.values()) if (j.hasKey(p.key)) p.set(j.getFloat(p.key));
  for (Toggle tg : toggles.values()) if (j.hasKey(tg.key)) tg.val = j.getBoolean(tg.key);
  if (j.hasKey("mode")) modeIndex = j.getInt("mode");
  if (j.hasKey("seedX")) { seedX = j.getFloat("seedX"); seedY = j.getFloat("seedY"); angle = j.getFloat("angle"); }
  if (j.hasKey("palette")) {
    JSONArray pal = j.getJSONArray("palette");
    for (int i = 0; i < 5; i++) {
      int c = unhex("FF" + pal.getString(i).substring(1));
      sunset[i] = c;
      palTarget[i][0] = red(c) / 255.0; palTarget[i][1] = green(c) / 255.0; palTarget[i][2] = blue(c) / 255.0;
    }
  }
  println("Loaded presets/latest.json");
}

class Controls {
  javax.swing.JFrame frame;
  HashMap<String, javax.swing.JSlider> sliders = new HashMap<String, javax.swing.JSlider>();
  HashMap<String, javax.swing.JLabel> valueLabels = new HashMap<String, javax.swing.JLabel>();
  HashMap<String, javax.swing.JCheckBox> boxes = new HashMap<String, javax.swing.JCheckBox>();
  javax.swing.JComboBox<String> modeBox;
  javax.swing.JPanel[] swatches = new javax.swing.JPanel[5];
  javax.swing.JLabel[] swatchLabels = new javax.swing.JLabel[5];
  boolean syncing = false;
  final int STEPS = 1000;

  final java.awt.Color BG = new java.awt.Color(0x17111C), CARD = new java.awt.Color(0x221827),
                       TEXT = new java.awt.Color(0xF3E9EE), DIM = new java.awt.Color(0xA8909E),
                       ACCENT = new java.awt.Color(0xE63946);

  Controls() {
    javax.swing.SwingUtilities.invokeLater(new Runnable() { public void run() { build(); } });
  }

  void setVisible(final boolean v) {
    javax.swing.SwingUtilities.invokeLater(new Runnable() { public void run() { if (frame != null) frame.setVisible(v); } });
  }
  boolean isVisible() { return frame != null && frame.isVisible(); }

  String fmt(Param p) {
    return p.isInt ? str((int) p.val) : nf(p.val, 0, p.max - p.min > 5 ? 1 : 2);
  }

  void build() {
    frame = new javax.swing.JFrame("Controls");
    frame.setDefaultCloseOperation(javax.swing.WindowConstants.HIDE_ON_CLOSE);  // closing just hides it

    javax.swing.JPanel root = new javax.swing.JPanel(new java.awt.BorderLayout(0, 12));
    root.setBackground(BG);
    root.setBorder(javax.swing.BorderFactory.createEmptyBorder(14, 16, 14, 16));

    javax.swing.JPanel cols = new javax.swing.JPanel(new java.awt.GridLayout(1, layout.length, 24, 0));
    cols.setOpaque(false);
    for (String[] column : layout) cols.add(buildColumn(column));
    root.add(cols, java.awt.BorderLayout.CENTER);
    root.add(buildBottom(), java.awt.BorderLayout.SOUTH);

    frame.setContentPane(root);
    frame.pack();
    frame.setLocation(20, 40);
    frame.setVisible(false);   // hidden at start; TAB or h shows it

    // keep swatches in sync with shuffles (keyboard, auto-shuffle...)
    new javax.swing.Timer(200, new java.awt.event.ActionListener() {
      public void actionPerformed(java.awt.event.ActionEvent e) { refreshSwatches(); }
    }).start();
  }

  javax.swing.JPanel buildColumn(String[] items) {
    javax.swing.JPanel col = new javax.swing.JPanel();
    col.setOpaque(false);
    col.setLayout(new javax.swing.BoxLayout(col, javax.swing.BoxLayout.Y_AXIS));
    for (String item : items) {
      java.awt.Component c;
      if (item.startsWith("#"))       c = header(item.substring(1));
      else if (item.startsWith("p:")) c = slider(params.get(item.substring(2)));
      else if (item.startsWith("t:")) c = checkbox(toggles.get(item.substring(2)));
      else                             c = modeRow();
      ((javax.swing.JComponent) c).setAlignmentX(0);
      col.add(c);
    }
    col.add(javax.swing.Box.createVerticalGlue());
    return col;
  }

  javax.swing.JLabel header(String t) {
    javax.swing.JLabel l = new javax.swing.JLabel(t);
    l.setForeground(ACCENT);
    l.setFont(l.getFont().deriveFont(java.awt.Font.BOLD, 11f));
    l.setBorder(javax.swing.BorderFactory.createEmptyBorder(10, 0, 4, 0));
    return l;
  }

  javax.swing.JPanel slider(final Param p) {
    javax.swing.JPanel row = new javax.swing.JPanel(new java.awt.BorderLayout());
    row.setOpaque(false);
    row.setMaximumSize(new java.awt.Dimension(320, 52));
    row.setPreferredSize(new java.awt.Dimension(300, 52));

    javax.swing.JPanel top = new javax.swing.JPanel(new java.awt.BorderLayout());
    top.setOpaque(false);
    javax.swing.JLabel name = new javax.swing.JLabel(p.label);
    name.setForeground(TEXT);
    final javax.swing.JLabel val = new javax.swing.JLabel(fmt(p));
    val.setForeground(DIM);
    top.add(name, java.awt.BorderLayout.WEST);
    top.add(val, java.awt.BorderLayout.EAST);

    final javax.swing.JSlider s = new javax.swing.JSlider(0, STEPS, toStep(p));
    s.setOpaque(false);
    s.setToolTipText("default " + (p.isInt ? str((int) p.def) : nf(p.def, 0, 2)) + "  (right-click to reset)");
    s.addChangeListener(new javax.swing.event.ChangeListener() {
      public void stateChanged(javax.swing.event.ChangeEvent e) {
        if (syncing) return;
        p.set(lerp(p.min, p.max, s.getValue() / (float) STEPS));
        val.setText(fmt(p));
      }
    });
    s.addMouseListener(new java.awt.event.MouseAdapter() {
      public void mousePressed(java.awt.event.MouseEvent e) {
        if (javax.swing.SwingUtilities.isRightMouseButton(e)) { p.val = p.def; sync(); }
      }
    });
    sliders.put(p.key, s);
    valueLabels.put(p.key, val);
    row.add(top, java.awt.BorderLayout.NORTH);
    row.add(s, java.awt.BorderLayout.CENTER);
    return row;
  }

  int toStep(Param p) { return round((p.val - p.min) / (p.max - p.min) * STEPS); }

  javax.swing.JCheckBox checkbox(final Toggle tg) {
    final javax.swing.JCheckBox b = new javax.swing.JCheckBox(tg.label, tg.val);
    b.setOpaque(false);
    b.setForeground(TEXT);
    b.addActionListener(new java.awt.event.ActionListener() {
      public void actionPerformed(java.awt.event.ActionEvent e) { tg.val = b.isSelected(); }
    });
    boxes.put(tg.key, b);
    return b;
  }

  javax.swing.JPanel modeRow() {
    javax.swing.JPanel row = new javax.swing.JPanel(new java.awt.BorderLayout(8, 0));
    row.setOpaque(false);
    row.setMaximumSize(new java.awt.Dimension(320, 34));
    javax.swing.JLabel l = new javax.swing.JLabel("Blend mode");
    l.setForeground(TEXT);
    modeBox = new javax.swing.JComboBox<String>(modeNames);
    modeBox.setSelectedIndex(modeIndex);
    modeBox.addActionListener(new java.awt.event.ActionListener() {
      public void actionPerformed(java.awt.event.ActionEvent e) { if (!syncing) modeIndex = modeBox.getSelectedIndex(); }
    });
    row.add(l, java.awt.BorderLayout.WEST);
    row.add(modeBox, java.awt.BorderLayout.CENTER);
    return row;
  }

  javax.swing.JPanel buildBottom() {
    javax.swing.JPanel bottom = new javax.swing.JPanel(new java.awt.BorderLayout(0, 10));
    bottom.setOpaque(false);

    javax.swing.JPanel pal = new javax.swing.JPanel(new java.awt.GridLayout(1, 5, 6, 0));
    pal.setOpaque(false);
    for (int i = 0; i < 5; i++) {
      swatches[i] = new javax.swing.JPanel(new java.awt.BorderLayout());
      swatches[i].setPreferredSize(new java.awt.Dimension(80, 30));
      swatchLabels[i] = new javax.swing.JLabel("", javax.swing.SwingConstants.CENTER);
      swatchLabels[i].setFont(swatchLabels[i].getFont().deriveFont(10f));
      swatches[i].add(swatchLabels[i]);
      pal.add(swatches[i]);
    }
    javax.swing.JPanel palWrap = new javax.swing.JPanel(new java.awt.BorderLayout(0, 4));
    palWrap.setOpaque(false);
    palWrap.add(header("PALETTE (current order)"), java.awt.BorderLayout.NORTH);
    palWrap.add(pal, java.awt.BorderLayout.CENTER);
    refreshSwatches();

    javax.swing.JPanel btns = new javax.swing.JPanel(new java.awt.GridLayout(0, 4, 8, 8));
    btns.setOpaque(false);
    button(btns, "New pattern (n)",    new Runnable() { public void run() { newPattern(); } });
    button(btns, "Shuffle colors (r)", new Runnable() { public void run() { shufflePalette(); } });
    button(btns, "Randomize look",     new Runnable() { public void run() { randomizeLook(); sync(); } });
    button(btns, "Reset all",          new Runnable() { public void run() { resetAll(); sync(); } });
    button(btns, "Save PNG (s)",       new Runnable() { public void run() { handleKey('s'); } });
    button(btns, "Save preset",        new Runnable() { public void run() { savePreset(); } });
    button(btns, "Load last preset",   new Runnable() { public void run() { loadPreset(); sync(); } });

    bottom.add(palWrap, java.awt.BorderLayout.NORTH);
    bottom.add(btns, java.awt.BorderLayout.CENTER);
    return bottom;
  }

  void button(javax.swing.JPanel parent, String label, final Runnable action) {
    javax.swing.JButton b = new javax.swing.JButton(label);
    b.addActionListener(new java.awt.event.ActionListener() {
      public void actionPerformed(java.awt.event.ActionEvent e) { action.run(); }
    });
    parent.add(b);
  }

  void refreshSwatches() {
    for (int i = 0; i < 5; i++) {
      if (swatches[i] == null) return;
      int c = sunset[i];
      swatches[i].setBackground(new java.awt.Color(c & 0xFFFFFF));
      swatchLabels[i].setText("#" + hex(c, 6));
      float lum = 0.299 * ((c >> 16) & 255) + 0.587 * ((c >> 8) & 255) + 0.114 * (c & 255);
      swatchLabels[i].setForeground(lum > 140 ? java.awt.Color.BLACK : java.awt.Color.WHITE);
    }
  }

  // push current values back into the widgets (after reset / randomize / load)
  void sync() {
    javax.swing.SwingUtilities.invokeLater(new Runnable() { public void run() {
      syncing = true;
      for (Param p : params.values()) {
        javax.swing.JSlider s = sliders.get(p.key);
        if (s != null) s.setValue(toStep(p));
        javax.swing.JLabel l = valueLabels.get(p.key);
        if (l != null) l.setText(fmt(p));
      }
      for (Toggle tg : toggles.values()) {
        javax.swing.JCheckBox b = boxes.get(tg.key);
        if (b != null) b.setSelected(tg.val);
      }
      if (modeBox != null) modeBox.setSelectedIndex(modeIndex);
      refreshSwatches();
      syncing = false;
    }});
  }
}
