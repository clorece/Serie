#ifndef PT_EMITTER_PALETTE_GLSL
#define PT_EMITTER_PALETTE_GLSL

// ---------------------------------------------------------------------------
// Special-blocklight palette, baked into an SSBO once at pack load.
//
// GetSpecialBlocklightColor (lib/blocklightColors.glsl) is a ~160-line binary
// search over ~98 emitter materials. That is fine in a raster pass that calls it
// once per fragment. It is NOT fine where it was also being called: inside the
// DDA traversal loop, from voxelEmitterColor, on every emissive voxel a ray
// walks past.
//
// The cost there is not only the branching. Pulling that tree into the hottest
// loop in the renderer inflates its register allocation, which lowers occupancy
// for EVERY ray -- including the overwhelming majority that never touch an
// emitter at all. It also dragged the whole 300-line header into every program
// that traces: the gather, the surface cache update and d7_composite.
//
// The palette is pure constants -- no uniforms, no world time, nothing that
// varies per frame -- so it can be evaluated once by the setup pass and read
// back as a single indexed fetch from 2 KB that never leaves L1.
//
// If you edit blocklightColors.glsl, nothing else needs changing: the setup pass
// re-runs on every pack reload, which is also when shader edits take effect.
// ---------------------------------------------------------------------------

// Material ids are 7 bits in the voxel word (voxelLightMat), so 128 entries
// covers the whole range the grid can encode. Highest id currently used is 97.
#define EMITTER_PALETTE_SIZE 128

layout(std430, binding = 2) buffer EmitterPaletteBuffer {
    vec4 color[EMITTER_PALETTE_SIZE];
} emitterPalette;

// Masked rather than clamped: voxelLightMat already yields 0..127, and a mask
// keeps this branch-free in the trace loop.
vec3 emitterColor(uint mat) {
    return emitterPalette.color[mat & uint(EMITTER_PALETTE_SIZE - 1)].rgb;
}

#endif
