// c2_bloom_finalize : passthrough write to preserve colortex3 ping-pong parity
// The atlas is fully built by c1; final.glsl reads it directly. This pass
// exists only to keep the total number of colortex3 writes per frame
// identical to the pre-rewrite count (5 deferred + 2 composite = 7). Iris
// double-buffers colortex3, so changing the write count flips which physical
// texture `final` reads — see the bloom-lesson in project memory
// (2026-05-20): "do not add/remove Iris composite passes that write a
// ping-pong colortex without accounting for flip parity".
//
// Cost: one texture read + one write per pixel. Cheap.

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"

in vec2 texCoord;

void main() {
    /* DRAWBUFFERS:3 */
    gl_FragData[0] = texture(colortex3, texCoord);
}

#endif
