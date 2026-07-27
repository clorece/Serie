// dg1_denoise pass 3: a-trous at stride 4, colortex10 -> colortex9.
//
// Thin wrapper. The only thing that lives here rather than in the shared body is
// the RENDERTARGETS line, which must be a literal Iris can read straight out of
// the source text -- see the note in dg1_denoise.glsl.

#define DN_STRIDE 4
#define DN_SRC colortex10

#include "/program/deferred/dg1_denoise.glsl"

#ifdef FRAGMENT
void main() {
    /* RENDERTARGETS: 9 */
    gl_FragData[0] = dnFilter();
}
#endif
