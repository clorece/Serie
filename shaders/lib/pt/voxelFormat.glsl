#ifndef VOXEL_FORMAT_GLSL
#define VOXEL_FORMAT_GLSL

// ---------------------------------------------------------------------------
// Packed voxel word (R32UI, one uint per voxel).
//
// The grid used to be RGBA8UI: a category byte plus RGB888 albedo. That left no
// room for shape ids once shapes came from Minecraft's own block models (761 of
// them, so 10 bits) instead of a hand-written 66-entry enum. Repacking into a
// single 32-bit word buys those bits at exactly the same 4 bytes per voxel, by
// spending albedo precision (RGB565) that bounce lighting cannot resolve anyway.
//
//   [ 2: 0]  category   VOXEL_AIR .. VOXEL_LIGHT
//   [12: 3]  shapeId    index into the BLAS shape table (0 = full cube)
//   [15:13]  skylight   vanilla sky lightmap, quantised to 3 bits (0..7)
//   [31:16]  payload    albedo RGB565, or the light material for VOXEL_LIGHT
//              (emitters take their colour from GetSpecialBlocklightColor(mat),
//               so they have no albedo to store and reuse the field)
//
// The skylight field used to be spare. It exists so the surface cache can answer
// "how much sky does this block see?" from the voxel word it has already fetched,
// instead of casting an occlusion probe per face. That probe was the single most
// expensive ray in the renderer -- SC_SKY_PROBE_DIST was 64 blocks, twice the
// bounce range, and it was recast for all six faces on every refresh purely to
// recover information Minecraft had already computed and handed to the voxeliser
// in gl_MultiTexCoord1.y. Three bits is ample: the value only gates a broad
// ambient term, and GI_SKY_LEAK_FALLOFF reshapes it non-linearly afterwards.
// ---------------------------------------------------------------------------

#define VOXEL_AIR      0u
#define VOXEL_OPAQUE   1u
#define VOXEL_FOLIAGE  2u
#define VOXEL_EMISSIVE 3u
#define VOXEL_LIGHT    4u

#define VOX_CAT_BITS     3u
#define VOX_SHAPE_BITS  10u
#define VOX_SHAPE_SHIFT  3u
#define VOX_SKY_SHIFT   13u
#define VOX_PAYLOAD_SHIFT 16u

#define VOX_CAT_MASK     7u
#define VOX_SHAPE_MASK   1023u
#define VOX_SKY_MASK     7u
#define VOX_PAYLOAD_MASK 65535u

// Largest shape id the 10-bit field can hold; the generator asserts against this.
#define VOX_MAX_SHAPE_ID 1023u

// Base of the generated block-id encoding: id = SHAPE_ID_BASE + shapeId*16 + matClass.
// Must match SHAPE_ID_BASE in scripts/gen_block_shapes.py.
#define SHAPE_ID_BASE 40000

uint voxelCategory(uint w) { return w & VOX_CAT_MASK; }
uint voxelShape(uint w)    { return (w >> VOX_SHAPE_SHIFT) & VOX_SHAPE_MASK; }
uint voxelPayload(uint w)  { return (w >> VOX_PAYLOAD_SHIFT) & VOX_PAYLOAD_MASK; }

// Sky access of this block, 0 (fully enclosed) .. 1 (open sky), from the vanilla
// skylight lightmap captured at voxelisation time.
float voxelSkylight(uint w) { return float((w >> VOX_SKY_SHIFT) & VOX_SKY_MASK) * (1.0 / 7.0); }

uint packSkylight(float skyLight01) {
    return uint(clamp(skyLight01, 0.0, 1.0) * 7.0 + 0.5) & VOX_SKY_MASK;
}

bool voxelIsAir(uint w)      { return (w & VOX_CAT_MASK) == VOXEL_AIR; }
bool voxelIsEmissive(uint w) { uint c = w & VOX_CAT_MASK; return c == VOXEL_EMISSIVE || c == VOXEL_LIGHT; }
uint voxelLightMat(uint w)   { return (w >> VOX_PAYLOAD_SHIFT) & 127u; }

vec3 unpackAlbedo565(uint p) {
    return vec3(float((p >> 11) & 31u) * (1.0 / 31.0),
                float((p >>  5) & 63u) * (1.0 / 63.0),
                float( p        & 31u) * (1.0 / 31.0));
}

uint packAlbedo565(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    uint r = uint(c.r * 31.0 + 0.5);
    uint g = uint(c.g * 63.0 + 0.5);
    uint b = uint(c.b * 31.0 + 0.5);
    return (r << 11) | (g << 5) | b;
}

vec3 voxelAlbedo(uint w) { return unpackAlbedo565(voxelPayload(w)); }

uint packVoxel(uint category, uint shapeId, uint skyBits, uint payload) {
    return (category & VOX_CAT_MASK)
         | ((shapeId & VOX_SHAPE_MASK) << VOX_SHAPE_SHIFT)
         | ((skyBits & VOX_SKY_MASK)   << VOX_SKY_SHIFT)
         | ((payload & VOX_PAYLOAD_MASK) << VOX_PAYLOAD_SHIFT);
}

#endif
