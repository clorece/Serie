#ifndef LIGHT_SHAPES_GLSL
#define LIGHT_SHAPES_GLSL

// ---------------------------------------------------------------------------
// Sub-block geometry for special blocklights.
//
// Emitters keep their 101xx block ids because the material is what supplies
// their colour (GetSpecialBlocklightColor), so they cannot also carry a
// generated shape id from gen_block_shapes.py -- a block gets exactly one id.
// There are only a handful of emitter silhouettes, so they stay hand-written
// here; every other block's shape comes from the generated BLAS table.
//
// Two separate boxes matter per emitter:
//   occluder - what actually blocks light (a torch's stick)
//   emissive - the part that glows (the flame cap at its top)
// Keeping them apart is what lets a torch shadow the surface beneath it while
// still lighting the room: rays that miss the flame but hit the post go dark.
// ---------------------------------------------------------------------------

#include "/lib/pt/blas.glsl"

// Occluder box for an emitter material. Returns false for area emitters
// (lava, glowstone, froglight) that fill their whole voxel.
bool lightOccluderAabb(uint mat, out vec3 bmin, out vec3 bmax) {
    if (mat == 2u || mat == 28u || mat == 35u) {          // torch / soul / redstone torch
        bmin = vec3(7.0 / 16.0, 0.0, 7.0 / 16.0);
        bmax = vec3(9.0 / 16.0, 10.0 / 16.0, 9.0 / 16.0);
        return true;
    }
    if (mat == 12u || mat == 29u || mat == 6u || mat == 36u ||
        mat == 38u || mat == 40u || mat == 24u ||
        (mat >= 70u && mat <= 80u)) {                     // lanterns, candles, amethyst, brewing stand
        bmin = vec3(5.0 / 16.0, 0.0, 5.0 / 16.0);
        bmax = vec3(11.0 / 16.0, 9.0 / 16.0, 11.0 / 16.0);
        return true;
    }
    if (mat == 3u || mat == 20u || mat == 65u) {          // end rod, cave/weeping vines
        bmin = vec3(7.0 / 16.0, 0.0, 7.0 / 16.0);
        bmax = vec3(9.0 / 16.0, 1.0, 9.0 / 16.0);
        return true;
    }
    if (mat == 15u || mat == 30u) {                       // campfires
        bmin = vec3(0.0, 0.0, 0.0);
        bmax = vec3(1.0, 7.0 / 16.0, 1.0);
        return true;
    }
    if (mat == 33u) {                                     // enchanting table
        bmin = vec3(0.0, 0.0, 0.0);
        bmax = vec3(1.0, 12.0 / 16.0, 1.0);
        return true;
    }
    if (mat == 66u) {                                     // redstone wire
        bmin = vec3(0.0, 0.0, 0.0);
        bmax = vec3(1.0, 1.0 / 16.0, 1.0);
        return true;
    }
    if (mat == 67u) {                                     // powered repeater / comparator
        bmin = vec3(0.0, 0.0, 0.0);
        bmax = vec3(1.0, 2.0 / 16.0, 1.0);
        return true;
    }
    bmin = vec3(0.0); bmax = vec3(1.0);
    return false; // full-voxel emitter
}

// Emissive sub-box (local 0..1) for an emitter material. Concentrating emission
// inside the block is what makes the occluder cast a real shadow: a torch emits
// only from the flame box above its post, so surfaces low and behind the stick
// fall into the post's shadow. Defaults to the full cube for area emitters.
void lightEmissiveAabb(uint mat, out vec3 bmin, out vec3 bmax) {
    bmin = vec3(0.0); bmax = vec3(1.0);
    if (mat == 2u || mat == 28u || mat == 35u) {                  // torch flame cap
        bmin = vec3(5.0 / 16.0, 7.0 / 16.0, 5.0 / 16.0);
        bmax = vec3(11.0 / 16.0, 13.0 / 16.0, 11.0 / 16.0);
    } else if (mat == 15u || mat == 30u) {                        // campfire embers
        bmin = vec3(3.0 / 16.0, 1.0 / 16.0, 3.0 / 16.0);
        bmax = vec3(13.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0);
    } else if (mat == 12u || mat == 29u || mat == 40u ||          // lantern / brewing stand
               (mat >= 70u && mat <= 80u)) {                      // candles
        bmin = vec3(5.0 / 16.0, 1.0 / 16.0, 5.0 / 16.0);
        bmax = vec3(11.0 / 16.0, 9.0 / 16.0, 11.0 / 16.0);
    }
}

// Ray/AABB entry-exit test that disturbs no running best-hit state.
bool aabbEntry(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax, out float tn, out float tf) {
    vec3 ird = 1.0 / (rd + vec3(1e-8));
    vec3 t0  = (bmin - ro) * ird;
    vec3 t1  = (bmax - ro) * ird;
    tn = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    tf = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    return tf >= max(tn, 0.0);
}

// Intersect an emitter's occluder box. Mirrors intersectShape's contract.
bool intersectLightShape(uint mat, vec3 ro, vec3 rd, bool skipInside,
                         out float tHit, out vec3 nHit) {
    tHit = 1e30;
    nHit = -rd;
    vec3 bmin, bmax;
    if (!lightOccluderAabb(mat, bmin, bmax)) return false; // fills the voxel
    vec3 ird = 1.0 / (rd + vec3(1e-8));
    return blasBoxHit(ro, ird, bmin, bmax, skipInside, tHit, nHit);
}

// Emission weight for an emitter voxel the ray is crossing.
// realHit/occT describe the occluder hit, when there was one.
float lightEmisFactor(uint mat, vec3 localRo, vec3 rayDir, bool realHit, float occT, bool hasShape) {
#ifdef VOXEL_EMISSIVE_SHAPES
    vec3 bmin, bmax;
    lightEmissiveAabb(mat, bmin, bmax);
    const float EB = 2.0 / 64.0; // edge tolerance (~0.03 block)
    if (realHit && hasShape) {
        vec3 hp = localRo + rayDir * occT;
        bool onEmis = all(greaterThanEqual(hp, bmin - EB)) && all(lessThanEqual(hp, bmax + EB));
        return onEmis ? 1.0 : 0.0;    // flame glows, stick stays dark
    }
    float tn, tf;
    if (aabbEntry(localRo, rayDir, bmin, bmax, tn, tf)) return 1.0;
    return realHit ? 1.0 : 0.0;
#else
    return realHit ? 1.0 : 0.35;
#endif
}

#endif
