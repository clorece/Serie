// p2_voxel_mip : coarse voxel-occupancy build (brick-skipping DDA acceleration).
//
// Target: colortex4 (RGBA8, 512×256). Each texel is one coarse cell ("brick")
// covering an 8³ block of the fine voxel grid (voxelSampler). .r = 1.0 if any
// voxel inside the brick is non-air, else 0.0.
//
// Runs in the prepare stage, which executes AFTER the shadow pass that voxelizes
// the 3D voxel image, so the grid is fully populated by the time we reduce it.
// The brick-skipping DDA in lib/pt/ddaTrace.glsl + lib/pt/gi.glsl reads this to
// jump over whole empty bricks in one step instead of marching voxel-by-voxel.
//
// Cost: COARSE_DIMS cells (64×16×64 = 131072) × 8³ fine reads, once per frame.

#ifdef VERTEX

void main() {
    gl_Position = ftransform();
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/pt/voxelData.glsl"
// voxelSampler (fine 3D voxel grid) is declared in /lib/uniforms.glsl, included above.

/* RENDERTARGETS: 4 */

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);

    bool occ = false;
    ivec3 c;
    if (coarseAtlasToCoord(px, c)) {
        ivec3 base = c * VOXEL_BRICK; // base+7 < VOXEL_DIMS, always in-grid
        for (int z = 0; z < VOXEL_BRICK && !occ; z++)
        for (int y = 0; y < VOXEL_BRICK && !occ; y++)
        for (int x = 0; x < VOXEL_BRICK && !occ; x++) {
            if (texelFetch(voxelSampler, base + ivec3(x, y, z), 0).r != VOXEL_AIR) {
                occ = true;
            }
        }
    }

    gl_FragData[0] = vec4(occ ? 1.0 : 0.0, 0.0, 0.0, 1.0);
}

#endif
