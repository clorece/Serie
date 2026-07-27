// dg1_denoise : one a-trous pass over the GI buffer.
//
// Shared body for the whole stride ladder. Each pass file defines DN_STRIDE and
// DN_SRC, then supplies its own main() with a LITERAL RENDERTARGETS line.
//
// The literal matters. Iris reads RENDERTARGETS out of the source text the same
// way it reads `const ivec3 workGroups`, so putting the output index behind an
// #if would be trusting it to evaluate a preprocessor branch it may simply not
// look at. Four tiny wrapper files with one hard-coded target each cost nothing
// and cannot be got wrong.
//
// Buffer flow, fixed regardless of how many passes are enabled:
//   deferred1  stride 1   colortex8  -> colortex9
//   deferred2  stride 2   colortex9  -> colortex10
//   deferred3  stride 4   colortex10 -> colortex9
//   deferred4  stride 8   colortex9  -> colortex10
//
// colortex8 is never written here. It is dg0_gather's temporal history, and
// feeding a denoised result back into the accumulator would compound the blur
// every frame -- each pass would filter an already-filtered signal without any
// new information to anchor it. SVGF does feed its first a-trous output back,
// but SVGF's history is a 1-spp estimate that needs the help; here the surface
// cache has already converged the signal before the gather runs, so the raw
// accumulation is the better thing to reproject.

#include "/lib/options.glsl"

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    // Same squeeze as dg0_gather: the GI buffers live in the bottom-left
    // renderScale region of a full-res target.
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/util/common.glsl"
#include "/lib/pt/atrous.glsl"

in vec2 texCoord;

// Everything is texelFetch, so no jitter and no renderScale enters the reads:
// gl_FragCoord is already in buffer pixels inside the scaled region, which is
// exactly the space colortex8/9/10/15 are written in.
vec4 dnFilter() {
    ivec2 pix    = ivec2(gl_FragCoord.xy);
    ivec2 pixMax = ivec2(vec2(viewWidth, viewHeight) * renderScale) - 1;
    return atrousGI(DN_SRC, colortex15, pix, pixMax, DN_STRIDE);
}

#endif
