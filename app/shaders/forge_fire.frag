// Animated forge fire: flames rising from the bottom edge plus a flickering
// hearth glow. Output is premultiplied alpha, so it can sit on any scene.
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
// 0..1: how tall and bright the fire is.
uniform float uIntensity;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float y = 1.0 - uv.y;                      // 0 at the bottom edge, 1 at the top
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2(uv.x * aspect * 3.2, y * 3.2);

  // A bed of glowing coals along the bottom edge.
  float coalTop = 0.09;
  float c = noise(vec2(uv.x * aspect * 26.0, y * 22.0)) * 0.65 +
            noise(vec2(uv.x * aspect * 60.0, y * 50.0)) * 0.35;
  float pulse = 0.75 + 0.25 * sin(uTime * 1.7 + c * 12.0);
  float hot = smoothstep(0.45, 0.8, c) * pulse;
  vec3 coal = mix(vec3(0.07, 0.02, 0.01), vec3(1.0, 0.33, 0.04), hot);
  coal = mix(coal, vec3(1.0, 0.7, 0.3), smoothstep(0.75, 1.0, hot) * 0.6);
  float coalMask = 1.0 - smoothstep(coalTop * 0.6, coalTop, y + (c - 0.5) * 0.03);

  // Flames rise from the coals: two noise layers scrolling upward at
  // different speeds give licking tongues of fire.
  float fy = max(y - coalTop * 0.5, 0.0);
  float n1 = fbm(p * vec2(1.6, 0.9) - vec2(0.0, uTime * 1.5));
  float n2 = fbm(p * vec2(3.0, 1.7) + vec2(uTime * 0.25, -uTime * 2.4));
  float flame = n1 * 0.6 + n2 * 0.4;

  // Flames are tallest in the middle and shrink toward the sides.
  float centre = 1.0 - pow(abs(uv.x - 0.5) * 2.0, 2.0) * 0.45;
  float height = fy / (0.9 * max(uIntensity, 0.05) * centre);
  float v = smoothstep(0.08, 0.62, flame - height * 0.7 + 0.12);

  vec3 col = mix(vec3(0.24, 0.02, 0.0), vec3(0.86, 0.19, 0.02), smoothstep(0.0, 0.4, v));
  col = mix(col, vec3(1.0, 0.5, 0.08), smoothstep(0.35, 0.75, v));
  col = mix(col, vec3(1.0, 0.82, 0.48), smoothstep(0.82, 1.0, v) * 0.65);
  float alpha = clamp(v * 1.1, 0.0, 0.92);

  // A soft, flickering hearth glow behind the flames.
  float flicker = 0.82 + 0.18 * noise(vec2(uTime * 3.1, 0.0));
  float d = length(vec2((uv.x - 0.5) * aspect * 1.1, y * 1.6));
  float glow = exp(-d * 2.6) * 0.45 * flicker;
  vec3 glowCol = vec3(1.0, 0.33, 0.05) * glow;

  vec3 rgb = col * alpha + glowCol * (1.0 - alpha);
  float a = clamp(alpha + glow * (1.0 - alpha), 0.0, 1.0);
  rgb = mix(rgb, coal, coalMask);
  a = mix(a, 1.0, coalMask);
  fragColor = vec4(rgb * uIntensity, a * uIntensity);
}
