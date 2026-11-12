#ifdef GL_ES
// mediump (16-bit on most phones/ES drivers) breaks the hash functions:
// pixel coords * large constants lose all precision and the grain turns
// into flat blocks or stripes. Ask for highp where the GPU supports it.
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#endif

#define PROCESSING_COLOR_SHADER

uniform float time;
uniform vec2 resolution;     // whole span canvas (one screen when not spanning) + margin
uniform vec2 fragOffset;     // this screen's position on the span canvas (0 when not spanning)
uniform vec2 noiseFactor;
uniform float noiseFactorTime;
uniform float contastfactor;

// ------------------------------------
// GRIT SETTINGS (tweak these)
// ------------------------------------

#define GRAIN_AMOUNT  0.07   // fine per-pixel sparkle
#define GRAIN_FPS     12.0   // how often the fine grain re-rolls
#define GRIT_AMOUNT   0.10   // coarser specks that swim with the water
#define GRIT_SCALE    2.5    // grit speck size in pixels
#define WARP_PIXELS   28.0   // how far the water flow drags the grit around


// ------------------------------------
// ORIGINAL PERLIN NOISE FUNCTIONS
// ------------------------------------

vec3 mod289(vec3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 mod289(vec4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 permute(vec4 x) {
    return mod289(((x * 34.0) + 1.0) * x);
}

vec4 taylorInvSqrt(vec4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

vec3 fade(vec3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float noise(vec3 P) {

    vec3 Pi0 = floor(P);
    vec3 Pi1 = Pi0 + vec3(1.0);

    Pi0 = mod289(Pi0);
    Pi1 = mod289(Pi1);

    vec3 Pf0 = fract(P);
    vec3 Pf1 = Pf0 - vec3(1.0);

    vec4 ix = vec4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    vec4 iy = vec4(Pi0.yy, Pi1.yy);
    vec4 iz0 = Pi0.zzzz;
    vec4 iz1 = Pi1.zzzz;

    vec4 ixy = permute(permute(ix) + iy);
    vec4 ixy0 = permute(ixy + iz0);
    vec4 ixy1 = permute(ixy + iz1);

    vec4 gx0 = ixy0 * (1.0 / 7.0);
    vec4 gy0 = fract(floor(gx0) * (1.0 / 7.0)) - 0.5;

    gx0 = fract(gx0);

    vec4 gz0 = vec4(0.5) - abs(gx0) - abs(gy0);
    vec4 sz0 = step(gz0, vec4(0.0));

    gx0 -= sz0 * (step(0.0, gx0) - 0.5);
    gy0 -= sz0 * (step(0.0, gy0) - 0.5);

    vec4 gx1 = ixy1 * (1.0 / 7.0);
    vec4 gy1 = fract(floor(gx1) * (1.0 / 7.0)) - 0.5;

    gx1 = fract(gx1);

    vec4 gz1 = vec4(0.5) - abs(gx1) - abs(gy1);
    vec4 sz1 = step(gz1, vec4(0.0));

    gx1 -= sz1 * (step(0.0, gx1) - 0.5);
    gy1 -= sz1 * (step(0.0, gy1) - 0.5);

    vec3 g000 = vec3(gx0.x, gy0.x, gz0.x);
    vec3 g100 = vec3(gx0.y, gy0.y, gz0.y);
    vec3 g010 = vec3(gx0.z, gy0.z, gz0.z);
    vec3 g110 = vec3(gx0.w, gy0.w, gz0.w);

    vec3 g001 = vec3(gx1.x, gy1.x, gz1.x);
    vec3 g101 = vec3(gx1.y, gy1.y, gz1.y);
    vec3 g011 = vec3(gx1.z, gy1.z, gz1.z);
    vec3 g111 = vec3(gx1.w, gy1.w, gz1.w);

    vec4 norm0 = taylorInvSqrt(vec4(
        dot(g000, g000),
        dot(g010, g010),
        dot(g100, g100),
        dot(g110, g110)
    ));

    g000 *= norm0.x;
    g010 *= norm0.y;
    g100 *= norm0.z;
    g110 *= norm0.w;

    vec4 norm1 = taylorInvSqrt(vec4(
        dot(g001, g001),
        dot(g011, g011),
        dot(g101, g101),
        dot(g111, g111)
    ));

    g001 *= norm1.x;
    g011 *= norm1.y;
    g101 *= norm1.z;
    g111 *= norm1.w;

    float n000 = dot(g000, Pf0);
    float n100 = dot(g100, vec3(Pf1.x, Pf0.yz));
    float n010 = dot(g010, vec3(Pf0.x, Pf1.y, Pf0.z));
    float n110 = dot(g110, vec3(Pf1.xy, Pf0.z));

    float n001 = dot(g001, vec3(Pf0.xy, Pf1.z));
    float n101 = dot(g101, vec3(Pf1.x, Pf0.y, Pf1.z));
    float n011 = dot(g011, vec3(Pf0.x, Pf1.yz));
    float n111 = dot(g111, Pf1);

    vec3 fade_xyz = fade(Pf0);

    vec4 n_z = mix(
        vec4(n000, n100, n010, n110),
        vec4(n001, n101, n011, n111),
        fade_xyz.z
    );

    vec2 n_yz = mix(n_z.xy, n_z.zw, fade_xyz.y);

    return mix(n_yz.x, n_yz.y, fade_xyz.x);
}


// ------------------------------------
// WHITE NOISE / GRIT
// ------------------------------------

// Hash without sine (Dave Hoskins) - stable across GPUs
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Blocky-but-smoothed white noise: gives clumps a few pixels wide
float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


// ------------------------------------
// MAIN
// ------------------------------------

void main(void) {

    // Measured from the screen centre so noiseFactor scales outward from the
    // middle (from gl_FragCoord's origin it would zoom out of the bottom-left).
    vec2 fc = gl_FragCoord.xy + fragOffset;   // pixel on the span canvas
    vec2 p = (fc - 0.5 * resolution.xy) / resolution.y;
    vec2 nx = p * noiseFactor;
    float tz = time * noiseFactorTime;

    // Original animated water noise
    float n = noise(vec3(nx, tz) * 3.0);
    float v = n * 6.28318531 * 0.15 + 0.5;


    // --------------------------------
    // FLOW FIELD
    // Two offset slices of the same Perlin noise give a smooth,
    // randomly wandering 2D vector field that moves at the same speed
    // as the water. The grit is sampled through it, so it swims and
    // swirls with the water instead of sitting still on the screen.
    // --------------------------------

    vec2 flow = vec2(
        noise(vec3(nx * 2.0 + 13.7, tz * 1.3 + 41.0)),
        noise(vec3(nx * 2.0 - 27.1, tz * 1.3 - 19.0))
    );

    vec2 px = fc + flow * WARP_PIXELS;


    // --------------------------------
    // COARSE GRIT: swims smoothly with the flow
    // --------------------------------

    float grit = valueNoise(px / GRIT_SCALE) * 2.0 - 1.0;

    // Square it (keeping the sign) so most of it fades out and only
    // sparse light/dark specks remain - reads as "gritty" not "foggy"
    grit = sign(grit) * grit * grit;

    // Let the water shape the grit: heavier on the bright crests,
    // lighter in the troughs. This is what gives the palette pass
    // something interesting to bite on.
    float gritMask = mix(0.4, 1.6, smoothstep(0.2, 0.8, v));


    // --------------------------------
    // FINE GRAIN: per-pixel, re-rolls GRAIN_FPS times a second
    // Each frame gets a random integer offset into the hash so the
    // pattern jumps somewhere new. Wrapped with mod() so the numbers
    // fed to the hash stay small no matter how long the sketch runs.
    // --------------------------------

    float frame = mod(floor(time * GRAIN_FPS), 1024.0);
    vec2 jump = floor(hash22(vec2(frame, frame * 0.5 + 3.0)) * 2048.0);

    float grain = hash12(floor(px) + jump) * 2.0 - 1.0;


    // --------------------------------
    // COMBINE
    // --------------------------------

    v += grit * GRIT_AMOUNT * gritMask;
    v += grain * GRAIN_AMOUNT;

    // Keep it in 0..1 so a palette lookup doesn't clamp unpredictably
   //v = clamp(v, 0.0, 1.0);



    gl_FragColor = vec4(((vec3(v)-vec3(0.5))* contastfactor + vec3(0.5)), 1.0);
	//gl_FragColor = vec4(vec3(v), 1.0);
}
