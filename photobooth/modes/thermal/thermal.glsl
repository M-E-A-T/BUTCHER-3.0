// Thermal camera look: sharpened brightness mapped through a heat gradient.
// Each audio band owns one colour of the gradient: when the band is loud,
// that colour's stretch of the gradient widens (more of the picture turns
// that colour) and glows brighter.
//   lowAmt  -> red      midAmt -> blue      highAmt -> yellow

#ifdef GL_ES
precision mediump float;
#endif

#define PROCESSING_TEXTURE_SHADER

uniform sampler2D texture;
uniform vec2 texOffset;      // one texel, set by Processing
uniform float lowAmt;    // 0..~1.5, smoothed bands (already scaled by the gain key)
uniform float midAmt;
uniform float highAmt;
uniform float time;

const float GROW = 12.0; // a band at 1 makes its colour's region 13x as wide
const float GLOW = 1.0;  // and brightens it by up to 100%

varying vec4 vertColor;
varying vec4 vertTexCoord;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// Sharpened brightness: unsharp mask against the 4 direct neighbours, so
// edges (eyes, hairline, clothing folds) stay crisp in the gradient.
float sharpLuma(vec2 uv) {
  vec2 o = texOffset;
  float c = luma(texture2D(texture, uv).rgb);
  float n = luma(texture2D(texture, uv + vec2( o.x, 0.0)).rgb)
          + luma(texture2D(texture, uv + vec2(-o.x, 0.0)).rgb)
          + luma(texture2D(texture, uv + vec2(0.0,  o.y)).rgb)
          + luma(texture2D(texture, uv + vec2(0.0, -o.y)).rgb);
  return clamp(c + 0.8 * (c - n * 0.25), 0.0, 1.0);
}

// Cold -> hot. Each stop has a width; the bands widen their stop, which
// squeezes the others, so the band's colour covers more of the brightness range.
vec3 gradient(float t) {
  const int N = 8;
  vec3 c[8];
  float w[8];
  float g[8];   // per-stop glow
  for (int k = 0; k < N; k++) { w[k] = 1.0; g[k] = 0.0; }
  w[1] += GROW * midAmt;  g[1] = midAmt;    // blue
  w[4] += GROW * highAmt; g[4] = highAmt;   // yellow
  w[6] += GROW * lowAmt;  g[6] = lowAmt;    // red
  c[0] = vec3(0.02, 0.01, 0.20);   // deep navy
  c[1] = vec3(0.10, 0.05, 0.75);   // blue
  c[2] = vec3(0.00, 0.55, 0.95);   // cyan
  c[3] = vec3(0.10, 0.85, 0.35);   // green
  c[4] = vec3(0.95, 0.95, 0.10);   // yellow
  c[5] = vec3(1.00, 0.55, 0.00);   // orange
  c[6] = vec3(0.95, 0.10, 0.05);   // red
  c[7] = vec3(1.00, 0.90, 0.95);   // white-hot
  for (int k = 0; k < N; k++) c[k] *= 1.0 + GLOW * g[k];

  // Stop positions: segment k..k+1 is (w[k] + w[k+1]) / 2 long.
  float total = 0.0;
  for (int k = 0; k < N - 1; k++) total += 0.5 * (w[k] + w[k + 1]);
  float x = clamp(t, 0.0, 1.0) * total;

  vec3 col = c[N - 1];
  float p = 0.0;
  bool found = false;
  for (int k = 0; k < N - 1; k++) {
    float len = 0.5 * (w[k] + w[k + 1]);
    if (!found && x <= p + len) {
      col = mix(c[k], c[k + 1], smoothstep(0.0, 1.0, (x - p) / len));
      found = true;
    }
    p += len;
  }
  return min(col, vec3(1.0));
}

void main() {
  vec2 uv = vertTexCoord.st;
  float l = sharpLuma(uv);
  // Stretch contrast so faces/skin land in the warm half and backgrounds stay
  // cold. The upper edge sits high so bright windows don't all clip to white.
  l = smoothstep(0.06, 0.95, l);
  float t = l + 0.01 * sin(time * 3.0 + uv.y * 40.0);   // faint shimmer so it isn't static
  gl_FragColor = vec4(gradient(t), 1.0) * vertColor;
}
