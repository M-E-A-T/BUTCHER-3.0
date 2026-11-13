// Pixelate: snap each fragment to the centre of its block.
#ifdef GL_ES
precision mediump float;
#endif

#define PROCESSING_TEXTURE_SHADER

uniform sampler2D texture;
uniform vec2 u_grid;          // blocks across, blocks down (of the drawn image)

varying vec4 vertColor;
varying vec4 vertTexCoord;

void main() {
  vec2 uv = (floor(vertTexCoord.st * u_grid) + 0.5) / u_grid;
  gl_FragColor = texture2D(texture, uv) * vertColor;
}
