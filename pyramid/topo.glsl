#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#endif

#define PROCESSING_TEXTURE_SHADER

// Print-style topographic map: thin contour lines in ink, a halftone
// dot fill whose density follows the height, a flat accent band and a
// dark shadow area, on coloured paper.
//
// Expects the output of water_grit.glsl:
//   R = clean height (contours are traced from this)
//   G = gritty height (roughens the dots and region edges)

uniform sampler2D texture;
uniform vec2 texOffset;      // set by Processing: size of one texel
uniform vec2 fragOffset;     // this screen's position on the span canvas (0 when not spanning)

varying vec4 vertColor;
varying vec4 vertTexCoord;

// ------------------------------------
// COLOURS (0..1 RGB)
// ------------------------------------

uniform vec3 paperColor;     // background
uniform vec3 inkColor;       // contour lines and halftone dots
uniform vec3 accentColor;    // flat band between accentBand.x and .y
uniform vec3 shadowColor;    // everything below shadowLevel

// ------------------------------------
// CONTOUR LINES
// ------------------------------------

uniform float levels;        // number of contour lines, e.g. 48 (0 = 48)
uniform float majorEvery;    // every Nth line is thicker, 0 = off
uniform float lineWidth;     // minor line thickness in pixels (0 = 1)
uniform vec2  misregister;   // shift lines vs. fill in pixels, like an
                             // off-register print. (0, 0) = aligned

// ------------------------------------
// FILL
// ------------------------------------

uniform vec2  accentBand;    // height range of the accent band, e.g. (0.55, 0.6)
uniform float shadowLevel;   // heights below this are shadowColor, 0 = off
uniform float halftoneSize;  // dot grid spacing in pixels (0 = 4)
uniform float halftoneAngle; // dot grid rotation in radians, e.g. 0.26
uniform float inkLow;        // dot coverage 0..1 at the lowest ground
uniform float inkHigh;       // dot coverage 0..1 at the highest ground
uniform float bandMix;       // 0 = dot density follows height smoothly,
                             // 1 = steps with each contour band
uniform float gritMix;       // how much the grit roughens dots and edges


float heightAt(vec2 uv) {
    return texture2D(texture, uv).r;
}

// Number of the 8 points in a ring around uv that sit in a different
// height band than uv. Anything above 0 means a band edge (a contour)
// passes within `radius` pixels.
float contourHits(vec2 uv, float bands, float radius) {
    float band = floor(heightAt(uv) * bands);
    vec2 r = radius * texOffset;
    const float D = 0.70710678;   // cos/sin of 45 degrees

    // The 8 ring directions (0, 45, ... 315 degrees), unrolled with
    // constant offsets instead of cos/sin per sample.
    float hits = 0.0;
    hits += step(0.5, abs(floor(heightAt(uv + vec2( 1.0,  0.0) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2(   D,    D) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2( 0.0,  1.0) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2(  -D,    D) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2(-1.0,  0.0) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2(  -D,   -D) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2( 0.0, -1.0) * r) * bands) - band));
    hits += step(0.5, abs(floor(heightAt(uv + vec2(   D,   -D) * r) * bands) - band));

    return hits;
}

// 1 where a halftone dot covers this pixel, 0 between dots
float halftone(vec2 px, float coverage, float size, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    vec2 r = vec2(c * px.x - s * px.y, s * px.x + c * px.y) / size;

    vec2 cell = fract(r) - 0.5;

    // dot radius whose area covers `coverage` of the cell;
    // past ~0.78 the dots merge into solid ink with holes
    float radius = sqrt(max(coverage, 0.0) / 3.14159);

    return step(length(cell), radius);
}


void main(void) {

    // Fallbacks so a forgotten uniform doesn't blank the whole map
    float L = levels > 0.0 ? levels : 48.0;
    float lw = lineWidth > 0.0 ? lineWidth : 1.0;
    float ht = halftoneSize > 0.0 ? halftoneSize : 4.0;

    vec2 uv = vertTexCoord.st;
    vec4 s = 1- texture2D(texture, uv);

    float h = s.r;
    float grit = (s.g - s.r) * gritMix;
    float hg = h + grit * 0.25;         // height with slightly ragged edges


    // --------------------------------
    // PAPER, ACCENT BAND, SHADOW
    // --------------------------------

    vec3 col = paperColor;

    float accent = step(accentBand.x, hg) * step(hg, accentBand.y);
    col = mix(col, accentColor, accent);

    float shadow = 1.0 - step(shadowLevel, hg);
    col = mix(col, shadowColor, shadow);


    // --------------------------------
    // HALFTONE DOTS
    // --------------------------------

    float stepped = (floor(h * L) + 0.5) / L;
    float t = clamp(mix(h, stepped, bandMix), 0.0, 1.0);

    // grit pushes coverage around so dots come out ragged and uneven
    float coverage = mix(inkLow, inkHigh, t) + grit * 1.5;

    float dots = halftone(gl_FragCoord.xy + fragOffset, coverage, ht, halftoneAngle);

    // no dots on the accent band or in the shadow, like separate plates
    dots *= (1.0 - accent) * (1.0 - shadow);


    // --------------------------------
    // CONTOUR LINES (hard-edged, like ink)
    // --------------------------------

    vec2 luv = uv + misregister * texOffset;
    float radius = lw * 0.5;

    float line = step(1.5, contourHits(luv, L, radius));

    if (majorEvery >= 1.0) {
        line = max(line, step(1.5, contourHits(luv, L / majorEvery, radius * 2.0)));
    }


    // --------------------------------
    // COMPOSITE
    // --------------------------------

    col = mix(col, inkColor, max(dots, line));

    gl_FragColor = vec4(col, 1.0) * vertColor;
}
