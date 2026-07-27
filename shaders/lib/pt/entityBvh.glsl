#ifndef ENTITY_BVH_GLSL
#define ENTITY_BVH_GLSL

// ---------------------------------------------------------------------------
// Per-frame entity acceleration structure.
//
// Entities are excluded from the voxel grid (they move every frame and would
// smear the static grid), so until now they cast no path-traced shadow at all.
// They do rasterise in the shadow pass, which is the one place their geometry is
// visible to us, so that is where we capture them.
//
// The hard part is identity: a fragment knows nothing about which entity it
// belongs to, and Iris exposes only an entity *type* id, so two pigs would merge
// into one box spanning both. Instead we key on the entity's render origin,
// which the shadow vertex stage can read out of the model-view matrix
// translation -- each entity is drawn with its own transform, so that origin is
// effectively a per-instance identifier. Hashing it into a slot gives us a
// stable place to accumulate an AABB with atomics.
//
// Bounds are accumulated as fixed-point integers because GLSL has no float
// atomics: positions are stored camera-relative in 1/64-block units with a bias,
// which keeps them positive and monotonic so atomicMin/atomicMax stay correct.
//
// shadowcomp then builds a complete binary tree over the slots by unioning
// bounds pairwise up the levels (see program/shadowcomp/sc0_entity_bvh.glsl).
// Slot order comes from the spatial hash rather than a Morton sort, so the tree
// is not perfectly localised -- but at the entity counts Minecraft produces
// (tens, occasionally hundreds) traversal is bounded by tree depth, not by node
// quality, and skipping the sort keeps the build to a handful of microseconds.
// ---------------------------------------------------------------------------

#include "/lib/pt/voxelFormat.glsl"

#define ENTITY_MAX        512u   // slots; also the leaf count of the padded tree
#define ENTITY_TREE_NODES 1024u  // 2 * ENTITY_MAX, heap-indexed from 1

// Fixed-point encoding for atomic bounds accumulation.
#define ENTITY_FP_SCALE 64.0
#define ENTITY_FP_BIAS  8388608u // 2^23: keeps camera-relative coords positive

layout(std430, binding = 1) buffer EntityBvhBuffer {
    uint  count;                    // slots actually touched this frame
    uint  pad0[3];
    // Per-slot fixed-point AABB: min.xyz then max.xyz, accumulated with atomics.
    uint  slotMin[ENTITY_MAX * 3u];
    uint  slotMax[ENTITY_MAX * 3u];
    uint  slotUsed[ENTITY_MAX];     // 0 = empty this frame
    // Built tree: heap layout, node i has children 2i and 2i+1, leaves at
    // [ENTITY_MAX, 2*ENTITY_MAX). Stored as float bounds once built.
    vec4  nodeMin[ENTITY_TREE_NODES];
    vec4  nodeMax[ENTITY_TREE_NODES];
} entityBvh;

uint entityEncode(float v) {
    return uint(int(floor(v * ENTITY_FP_SCALE)) + int(ENTITY_FP_BIAS));
}

float entityDecode(uint v) {
    return float(int(v) - int(ENTITY_FP_BIAS)) / ENTITY_FP_SCALE;
}

// Hash an entity's render origin into a slot. Distinct entities land in distinct
// slots almost always; a collision merges two boxes, which over-occludes very
// slightly rather than dropping a shadow.
uint entitySlot(vec3 origin) {
    ivec3 q = ivec3(floor(origin * 8.0)); // 1/8-block granularity
    uint h = uint(q.x * 73856093 ^ q.y * 19349663 ^ q.z * 83492791);
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return h % ENTITY_MAX;
}

// ---------------------------------------------------------------------------
// Traversal
// ---------------------------------------------------------------------------

bool entityBoxHit(vec3 ro, vec3 ird, vec3 bmin, vec3 bmax, float maxT, out float tn) {
    vec3 t0 = (bmin - ro) * ird;
    vec3 t1 = (bmax - ro) * ird;
    vec3 a = min(t0, t1), b = max(t0, t1);
    tn = max(a.x, max(a.y, a.z));
    float tf = min(b.x, min(b.y, b.z));
    return tf >= max(tn, 0.0) && tn < maxT;
}

// Any-hit query against the entity tree. Used for shadow and GI occlusion, so
// entities finally block light instead of being invisible to the path tracer.
//
// Takes a world-absolute origin. Bounds are stored camera-relative to keep
// fixed-point precision usable far from the world origin, so the conversion
// happens here rather than at every call site. cameraPosition is constant for
// the frame, and shadowcomp rebuilds the tree before any of this is read, so
// the two always agree.
bool entityBvhOccluded(vec3 roWorld, vec3 rd, float maxT) {
    if (entityBvh.count == 0u) return false;

    vec3 ro = roWorld - cameraPosition;
    vec3 ird = 1.0 / (rd + vec3(1e-8));
    uint stack[24];
    int sp = 0;
    stack[sp++] = 1u; // root

    while (sp > 0) {
        uint n = stack[--sp];
        vec4 bmin = entityBvh.nodeMin[n];
        vec4 bmax = entityBvh.nodeMax[n];
        if (bmin.w == 0.0) continue; // empty node

        float tn;
        if (!entityBoxHit(ro, ird, bmin.xyz, bmax.xyz, maxT, tn)) continue;

        if (n >= ENTITY_MAX) return true; // leaf: a real entity box was hit
        if (sp < 22) {
            stack[sp++] = n * 2u;
            stack[sp++] = n * 2u + 1u;
        }
    }
    return false;
}

// Closest-hit query, for rays that need a surface to shade. World-absolute origin.
bool entityBvhClosest(vec3 roWorld, vec3 rd, float maxT, out float tHit, out vec3 nHit) {
    tHit = maxT; nHit = -rd;
    if (entityBvh.count == 0u) return false;

    vec3 ro = roWorld - cameraPosition;
    vec3 ird = 1.0 / (rd + vec3(1e-8));
    uint stack[24];
    int sp = 0;
    stack[sp++] = 1u;
    bool hit = false;

    while (sp > 0) {
        uint n = stack[--sp];
        vec4 bmin = entityBvh.nodeMin[n];
        vec4 bmax = entityBvh.nodeMax[n];
        if (bmin.w == 0.0) continue;

        float tn;
        if (!entityBoxHit(ro, ird, bmin.xyz, bmax.xyz, tHit, tn)) continue;

        if (n >= ENTITY_MAX) {
            if (tn < tHit) {
                tHit = max(tn, 0.0);
                // Face normal: whichever slab the entry distance came from.
                vec3 t0 = (bmin.xyz - ro) * ird;
                vec3 t1 = (bmax.xyz - ro) * ird;
                vec3 a  = min(t0, t1);
                nHit = -sign(ird) * vec3(equal(a, vec3(tn)));
                hit = true;
            }
        } else if (sp < 22) {
            stack[sp++] = n * 2u;
            stack[sp++] = n * 2u + 1u;
        }
    }
    return hit;
}

#endif
