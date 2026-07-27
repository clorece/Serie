// Builds the entity BVH from the AABBs the shadow pass captured this frame.
//
// Runs in shadowcomp, which Iris executes after the shadow (voxelization) pass,
// so every entity fragment has already deposited its bounds.
//
// The build is deliberately simple: convert each occupied slot into a leaf, then
// merge pairwise up a complete binary tree. Minecraft renders tens of entities,
// occasionally a few hundred, so a full SAH build would cost more to set up than
// it could ever save during traversal. One workgroup handles the whole thing,
// which lets barrier() replace any cross-dispatch synchronisation.

#include "/lib/pt/entityBvh.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(1, 1, 1);

const float INF = 3.402823e38;

// Occupied-slot tally. Each thread walks a strided subset of the slots, so the
// count has to be reduced across the whole workgroup, not read off thread 0.
shared uint sLive;

void main() {
    uint tid = gl_LocalInvocationID.x;

    if (tid == 0u) sLive = 0u;
    barrier();

    // --- leaves --------------------------------------------------------------
    // Slot order is a spatial hash, not a spatial sort, but each leaf is an
    // independent box and the tree above it is rebuilt from actual bounds, so
    // ordering only affects tree quality, never correctness.
    for (uint s = tid; s < ENTITY_MAX; s += 256u) {
        uint node = ENTITY_MAX + s;
        if (entityBvh.slotUsed[s] != 0u) {
            vec3 bmin = vec3(entityDecode(entityBvh.slotMin[s * 3u + 0u]),
                             entityDecode(entityBvh.slotMin[s * 3u + 1u]),
                             entityDecode(entityBvh.slotMin[s * 3u + 2u]));
            vec3 bmax = vec3(entityDecode(entityBvh.slotMax[s * 3u + 0u]),
                             entityDecode(entityBvh.slotMax[s * 3u + 1u]),
                             entityDecode(entityBvh.slotMax[s * 3u + 2u]));
            entityBvh.nodeMin[node] = vec4(bmin, 1.0); // w = occupied flag
            entityBvh.nodeMax[node] = vec4(bmax, 1.0);
            atomicAdd(sLive, 1u);
        } else {
            entityBvh.nodeMin[node] = vec4(INF, INF, INF, 0.0);
            entityBvh.nodeMax[node] = vec4(-INF, -INF, -INF, 0.0);
        }
        // Clear for the next frame's accumulation. Iris only clears images, not
        // buffer objects, so the slots must be reset by hand or bounds from old
        // frames would keep widening every box forever.
        entityBvh.slotUsed[s] = 0u;
        entityBvh.slotMin[s * 3u + 0u] = 0xFFFFFFFFu;
        entityBvh.slotMin[s * 3u + 1u] = 0xFFFFFFFFu;
        entityBvh.slotMin[s * 3u + 2u] = 0xFFFFFFFFu;
        entityBvh.slotMax[s * 3u + 0u] = 0u;
        entityBvh.slotMax[s * 3u + 1u] = 0u;
        entityBvh.slotMax[s * 3u + 2u] = 0u;
    }

    barrier();
    memoryBarrierBuffer();

    // --- internal nodes, one level at a time ---------------------------------
    // Level width halves each round; node i unions its two children.
    for (uint width = ENTITY_MAX >> 1u; width >= 1u; width >>= 1u) {
        for (uint i = tid; i < width; i += 256u) {
            uint n = width + i;
            vec4 aMin = entityBvh.nodeMin[n * 2u],      aMax = entityBvh.nodeMax[n * 2u];
            vec4 bMin = entityBvh.nodeMin[n * 2u + 1u], bMax = entityBvh.nodeMax[n * 2u + 1u];
            float occ = max(aMin.w, bMin.w);
            entityBvh.nodeMin[n] = vec4(min(aMin.xyz, bMin.xyz), occ);
            entityBvh.nodeMax[n] = vec4(max(aMax.xyz, bMax.xyz), occ);
        }
        barrier();
        memoryBarrierBuffer();
    }

    // Publish the live count last, so traversal never sees a half-built tree.
    if (tid == 0u) {
        entityBvh.count = sLive;
    }
}
