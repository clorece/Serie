#ifndef IRCACHE_GLSL
#define IRCACHE_GLSL

#include "/lib/pt/voxelData.glsl"

// World-space irradiance cache. A 64^3 grid of isotropic probes covers
// +- IC_PROBE_RADIUS blocks around the camera, packed as 8x8 z-slice tiles
// of 64x64 pixels = a 512x512 atlas region in the top-left of colortex10.
//
// Each probe stores RGBA16F: .rgb = sphere-averaged incoming irradiance,
// .a = temporal history length used by the update blend. The cascade is
// snapped to integer-block coordinates so probes only shift one cell at a
// time as the camera walks (most of the volume retains history).

#define IC_GRID_DIM     64
#define IC_TILE         64
#define IC_ATLAS_COLS    8
#define IC_ATLAS_ROWS    8

ivec2 icAtlasSize() { return ivec2(IC_ATLAS_COLS * IC_TILE, IC_ATLAS_ROWS * IC_TILE); }

bool icPixelInAtlas(ivec2 px) {
    ivec2 sz = icAtlasSize();
    return all(greaterThanEqual(px, ivec2(0))) && all(lessThan(px, sz));
}

vec3 icGridOrigin(vec3 cameraPos) {
    return floor(cameraPos) - vec3(IC_PROBE_RADIUS);
}

ivec2 icCoordToAtlas(ivec3 c) {
    int col = c.z % IC_ATLAS_COLS;
    int row = c.z / IC_ATLAS_COLS;
    return ivec2(col * IC_TILE + c.x, row * IC_TILE + c.y);
}

bool icAtlasToCoord(ivec2 px, out ivec3 c) {
    if (!icPixelInAtlas(px)) return false;
    int col = px.x / IC_TILE;
    int row = px.y / IC_TILE;
    int z = row * IC_ATLAS_COLS + col;
    if (z >= IC_GRID_DIM) return false;
    c = ivec3(px.x % IC_TILE, px.y % IC_TILE, z);
    return true;
}

vec4 icFetchProbe(sampler2D atlas, ivec3 c) {
    if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(IC_GRID_DIM))))
        return vec4(0.0);
    return texelFetch(atlas, icCoordToAtlas(c), 0);
}

// Short DDA to check if a solid voxel occludes the path from worldAbs to probePos.
bool icProbeOccluded(usampler2D voxelAtlas, vec3 voxelGridOrigin, vec3 worldAbs, vec3 probePos) {
    vec3 rayDir = probePos - worldAbs;
    float maxDist = length(rayDir);
    if (maxDist < 1e-4) return false;
    rayDir /= maxDist;
    
    vec3 localPos = worldAbs - voxelGridOrigin;
    ivec3 vox = ivec3(floor(localPos));
    ivec3 stepDir = ivec3(sign(rayDir));
    vec3 tDelta = 1.0 / max(abs(rayDir), vec3(1e-8));
    vec3 tMax;
    for (int i = 0; i < 3; ++i) {
        if (rayDir[i] > 0.0)      tMax[i] = (floor(localPos[i]) + 1.0 - localPos[i]) * tDelta[i];
        else if (rayDir[i] < 0.0) tMax[i] = (localPos[i] - floor(localPos[i])) * tDelta[i];
        else                      tMax[i] = 1e38;
    }
    float tEntry = 0.0;
    // Max distance is ~1.73 blocks. At most we cross 3 boundaries. Loop 4 times.
    for (int i = 0; i < 4; i++) {
        if (tEntry >= maxDist) break;
        if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(VOXEL_GRID_SIZE)))) break;
        
        uint vt = texelFetch(voxelAtlas, voxelCoordToAtlas(vox), 0).r;
        if (vt != VOXEL_AIR && vt != VOXEL_FOLIAGE && i > 0) return true;
        
        bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
        tEntry = min(tMax.x, min(tMax.y, tMax.z));
        tMax += vec3(mask) * tDelta;
        vox += stepDir * ivec3(mask);
    }
    return false;
}

// Trilinear-interpolated irradiance lookup. The caller passes the grid origin
// that anchored the atlas at the time it was written, so a reader in frame N
// sampling the atlas written in frame N-1 must pass icGridOrigin(previousCameraPosition).
// Probes are anchored at grid-cell centers, so a world position at integer block
// boundaries lands halfway between eight probes.
vec4 icSampleTrilinear(
    sampler2D atlas, vec3 worldAbs, vec3 worldNormal, vec3 gridOrigin,
    usampler2D voxelAtlas, vec3 voxelGridOrigin
) {
    vec3 g = (worldAbs - gridOrigin) - vec3(0.5);
    vec3 gi = floor(g);
    vec3 gf = clamp(g - gi, vec3(0.0), vec3(1.0));
    ivec3 base = ivec3(gi);

    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    float histAcc = 0.0;
    for (int dz = 0; dz < 2; dz++) {
        float wz = (dz == 0) ? (1.0 - gf.z) : gf.z;
        for (int dy = 0; dy < 2; dy++) {
            float wy = (dy == 0) ? (1.0 - gf.y) : gf.y;
            for (int dx = 0; dx < 2; dx++) {
                float wx = (dx == 0) ? (1.0 - gf.x) : gf.x;
                ivec3 c = base + ivec3(dx, dy, dz);
                vec4 p = icFetchProbe(atlas, c);
                if (p.a <= 0.0) continue;
                
                vec3 probePos = gridOrigin + vec3(c) + vec3(0.5);
                vec3 toProbe = probePos - worldAbs;
                
                // 1. Backface culling
                if (dot(toProbe, worldNormal) < -0.1) continue;
                
                // 2. Voxel occlusion
                if (icProbeOccluded(voxelAtlas, voxelGridOrigin, worldAbs, probePos)) continue;

                float w = wx * wy * wz;
                acc     += p.rgb * w;
                histAcc += p.a   * w;
                wsum    += w;
            }
        }
    }
    if (wsum > 1e-5) return vec4(acc / wsum, histAcc / wsum);
    return vec4(0.0);
}

#endif
