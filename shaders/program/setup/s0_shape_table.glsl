// Uploads the static lookup tables the tracer needs into their SSBOs.
//
// Runs once, when the pack loads: Iris setup programs execute a single time at
// pipeline creation and the buffer objects persist until the next reload. That
// keeps bulky constant data out of every hot trace shader -- only this
// throwaway compute pass ever sees shapeTable.glsl or the blocklight palette;
// the tracing passes just read the SSBOs.
//
// Two tables:
//   binding 0  block-shape BLAS (lookup + packed AABBs)
//   binding 2  special-blocklight emitter palette
//
// Both are pure constants, so "once at load" is the correct cadence -- and a
// pack reload is also the only way their source can change.

#include "/lib/pt/blas.glsl"
#include "/lib/pt/shapeTable.glsl"
#include "/lib/pt/emitterPalette.glsl"
#include "/lib/blocklightColors.glsl"

layout(local_size_x = 64) in;
const ivec3 workGroups = ivec3(128, 1, 1); // 8192 invocations >= lookup + box words

void main() {
    uint i = gl_GlobalInvocationID.x;

    // Flatten the emitter branch tree into a flat indexed table. This is the
    // only place GetSpecialBlocklightColor is evaluated for the tracer.
    if (i < uint(EMITTER_PALETTE_SIZE)) {
        emitterPalette.color[i] = GetSpecialBlocklightColor(int(i));
    }

    // Lookup table: one entry per shape, plus index 0 for the full cube.
    if (i < uint(SHAPE_LOOKUP.length())) {
        shapeTable.shapeLookup[i] = SHAPE_LOOKUP[i];
    } else if (i < 1024u) {
        shapeTable.shapeLookup[i] = 0u; // unused ids resolve to "no boxes"
    }

    // Packed AABBs, two uints per box.
    uint boxWords = SHAPE_BOX_COUNT * 2u;
    if (i < boxWords) {
        shapeTable.shapeBoxes[i] = SHAPE_BOXES[i];
    }
}
