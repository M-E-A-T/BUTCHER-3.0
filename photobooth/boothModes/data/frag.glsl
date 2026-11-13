// Based on "Shader_251001_2" by SamuelYAN (CC BY-NC-SA)
// https://openprocessing.org/sketch/2741733
// Every look parameter is a uniform driven by the Controls window.

#ifdef GL_ES
precision highp float;
#endif

#define PROCESSING_COLOR_SHADER

uniform vec2  u_resolution;
uniform float u_time;          // already scaled by speed on the CPU side
uniform vec2  u_seed;          // random per run: picks a different pattern, same coverage
uniform float u_angle;         // random per run: rotates the flow field

// Shape
uniform float u_rotate;        // 1 = pattern turned 90°
uniform float u_zoom;          // original 8.0
uniform float u_detail;        // original 0.4 (divisor)
uniform float u_octaves;       // original 5
uniform float u_warp;          // original 0.05
uniform float u_warpFreq;      // multiplier on wobble frequencies, original 1.0
uniform float u_density;       // original 2.0
uniform float u_lineSpeed;     // original 3.0
uniform float u_drift;         // original 0.3
uniform float u_thick;         // original 0.09
uniform float u_soft;          // original 0.03

// Color
uniform vec3  u_c0;
uniform vec3  u_c1;
uniform vec3  u_c2;
uniform vec3  u_c3;
uniform vec3  u_c4;
uniform float u_colorSpeed;    // original 0.2
uniform float u_colorBands;    // 1.0
uniform float u_hardColors;    // 1 = posterized color blocks
uniform float u_pingpong;      // 1 = sweep A->E->A, 0 = loop A->E, jump to A
uniform float u_sparkAmt;      // original 0.1 (fraction of pixels that spark)
uniform float u_sparkRadius;   // original 0.9
uniform vec3  u_sparkColor;

// Overlay
uniform float u_opacity;
uniform float u_invert;        // 1 = colors everywhere except the lines
uniform float u_mode;          // 0 = normal alpha, 1 = additive-style, 2 = multiply-style

vec3 palette(float t) {
  t = fract(t);
  if (u_pingpong > 0.5) {
    t = 1.0 - abs(t * 2.0 - 1.0);
    t *= 4.0;                     // 4 segments: c0..c4
  } else {
    t *= 5.0;                     // 5 segments: c0..c4..c0
  }
  float f = fract(t);
  f = u_hardColors > 0.5 ? step(0.5, f) : smoothstep(0.0, 1.0, f);
  if (t < 1.0) return mix(u_c0, u_c1, f);
  if (t < 2.0) return mix(u_c1, u_c2, f);
  if (t < 3.0) return mix(u_c2, u_c3, f);
  if (t < 4.0) return mix(u_c3, u_c4, f);
  if (u_pingpong > 0.5) return u_c4;
  return mix(u_c4, u_c0, f);
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
  float f = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 8; i++) {
    if (float(i) >= u_octaves) break;
    f += amp * noise(p);
    p *= 2.0;
    amp *= 0.5;
  }
  return f;
}

void main() {
  vec2 R;
  vec2 uv;
  if (u_rotate > 0.5) {
    R  = u_resolution.yx;
    uv = vec2(gl_FragCoord.y / u_resolution.y, 1.0 - gl_FragCoord.x / u_resolution.x);
  } else {
    R  = u_resolution;
    uv = gl_FragCoord.xy / u_resolution;
  }
  uv = uv * 1.0/3.0 - 1.0/3.0;
  uv.x *= R.x / R.y;

  float time = u_time;

  // random per-run rotation of the flow field
  float ca = cos(u_angle), sa = sin(u_angle);
  vec2 flow = mat2(ca, sa, -sa, ca) * (uv * u_zoom);
  flow += u_warp * vec2(
    sin(flow.y * 1.0 * u_warpFreq + time * 4.0),
    cos(flow.x * 4.0 * u_warpFreq + time * 1.0)
  );

  float n = fbm(flow / u_detail + u_seed + time * u_drift);

  float line = abs(sin(n * u_density - time * u_lineSpeed));
  float band = smoothstep(u_thick + u_soft, u_thick - 0.0001, line);

  float spark = step(u_sparkAmt, fract(sin(dot(uv, vec2(2.9898, 1.233))) * 43758.5453));
  spark *= smoothstep(u_sparkRadius, 0.0, length(uv));

  vec3 col = palette(n * u_colorBands + time * u_colorSpeed);
  if (spark <= 0.0 && u_sparkAmt > 0.0) col = u_sparkColor;

  float a = (u_invert > 0.5 ? 1.0 - band : band) * u_opacity;

  if (u_mode < 0.5)      gl_FragColor = vec4(col, a);                    // normal
  else if (u_mode < 1.5) gl_FragColor = vec4(col * a, a);                // screen/add/lighten...
  else                   gl_FragColor = vec4(mix(vec3(1.0), col, a), a); // multiply/darken
}
