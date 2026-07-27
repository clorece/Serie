// Uploads the generated block-shape table into the BLAS SSBO.
//
// Runs once, when the pack loads: Iris setup programs execute a single time at
// pipeline creation and the buffer object persists until the next reload. That
// keeps the bulky const arrays out of every hot trace shader -- only this
// throwaway compute pass ever sees shapeTable.glsl; d0_restir and friends just
// read the SSBO.

#include "/lib/pt/blas.glsl"
#include "/lib/pt/shapeTable.glsl"

layout(local_size_x = 64) in;
const ivec3 workGroups = ivec3(128, 1, 1); // 8192 invocations >= lookup + box words

void main() {
    uint i = gl_GlobalInvocationID.x;

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
