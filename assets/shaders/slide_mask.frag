#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uAlpha;
uniform float uSlide;
uniform float uEnd;
uniform float uExtent;
uniform float uVertical;
uniform float uFlipX;
uniform float uFlipY;
uniform vec4 uColor;
uniform sampler2D uMaskTexture;

out vec4 fragColor;

void main() {
  vec2 screenUv = FlutterFragCoord().xy / uSize;
  vec2 uv = vec2(screenUv.x, 1.0 - screenUv.y);
  vec2 maskUv = vec2(
    mix(uv.x, 1.0 - uv.x, uFlipX),
    mix(1.0 - uv.y, uv.y, uFlipY)
  );
  float progress = clamp((uAlpha - 0.2) * 1.25, 0.0, 1.0);
  float start = progress * (uSlide + uEnd) - uEnd;
  float span = uEnd + progress * (uExtent - uEnd);
  float coord = mix(maskUv.x, maskUv.y, uVertical);
  float other = mix(maskUv.y, maskUv.x, uVertical);
  float maskU = (coord - start) / span;
  float maskAlpha = texture(uMaskTexture, vec2(maskU, other)).a;
  float alpha = clamp(maskAlpha + uAlpha, 0.0, 1.0) * uColor.a;
  fragColor = vec4(uColor.rgb * alpha, alpha);
}
