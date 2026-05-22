#ifndef COMMON_GLSL
#define COMMON_GLSL

uniform float near; 
uniform float far;
uniform float viewWidth;                    
uniform float viewHeight;  

#define texelSize (vec2(1.0) / vec2(viewWidth, viewHeight))


float rand(float seed) {
    return fract(sin(seed) * 43758.5453123) * 2.0 - 1.0;
}

vec4 nvec4(vec3 pos) {
    return vec4(pos.xyz, 1.0);
}

float distx(float dist){
	return (((dist - near) * far) / ((far - near) * dist));
}

float getDepth(float depth) {
    return 2.0 * near * far / (far + near - (2.0 * depth - 1.0) * (far - near));
}

// Octahedral unit-vector encoding (Cigolle et al. 2014) for packing a normal into vec2.
vec2 octEncodeNormal(vec3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    vec2 e = (n.z >= 0.0)
        ? n.xy
        : (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 octDecodeNormal(vec2 f) {
    f = f * 2.0 - 1.0;
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = max(-n.z, 0.0);
    n.x += (n.x >= 0.0) ? -t : t;
    n.y += (n.y >= 0.0) ? -t : t;
    return normalize(n);
}

#endif