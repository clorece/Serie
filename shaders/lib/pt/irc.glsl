#ifndef IRC_GLSL
#define IRC_GLSL

// World-space irradiance cache: coordinate mapping + sampling.
// The cache is a camera-relative 3D grid (one cell = IRC_CELL^3 blocks) whose
// origin is snapped to the cell size so a 1-block camera move reprojects the grid
// by an INTEGER number of cells (the shadowcomp shift pass relies on this). Each
// cell stores a running radiance SUM in .rgb and a sample WEIGHT in .a; the
// resolved mean radiance is rgb / max(a, eps). Writing/accumulating happens in the
// shadowcomp compute passes; this header is shared by those passes (mapping) and
// by the per-pixel resolve in d0_giresolve (the sampled read).

#include "/lib/options.glsl"
#include "/lib/pt/voxelData.glsl"

// Near-field cache grid, decoupled from the (larger) voxel grid. 1-block cells.
const ivec3 IRC_DIMS  = ivec3(IRC_DIM_XZ, IRC_DIM_Y, IRC_DIM_XZ);
const vec3  IRC_DIMSF = vec3(IRC_DIMS);
const float IRC_CELLF = float(IRC_CELL);
const vec3  IRC_HALF  = vec3(IRC_DIM_XZ / 2, IRC_DIM_Y / 2, IRC_DIM_XZ / 2);

// Camera-relative grid origin (world space), snapped to the cell size.
vec3 ircOrigin(vec3 camPos) {
    return floor(camPos / IRC_CELLF) * IRC_CELLF - IRC_HALF;
}

// Integer cell delta the grid moved this frame: a cell now at `coord` held, last
// frame, the value that lived at `coord + ircCellDelta(...)`.
ivec3 ircCellDelta(vec3 camPos, vec3 prevCamPos) {
    return ivec3(floor(camPos / IRC_CELLF) - floor(prevCamPos / IRC_CELLF));
}

// World-space center of a cell.
vec3 ircCellCenter(ivec3 coord, vec3 camPos) {
    return ircOrigin(camPos) + (vec3(coord) + 0.5) * IRC_CELLF;
}

// World position -> fractional cell coordinate (cell centers sit at integer+0.5).
vec3 ircCellCoordF(vec3 worldPos, vec3 camPos) {
    return (worldPos - ircOrigin(camPos)) / IRC_CELLF;
}

bool ircInRange(vec3 cellF) {
    return all(greaterThanEqual(cellF, vec3(0.0))) && all(lessThan(cellF, IRC_DIMSF));
}

// Raw hardware-trilinear tap at a world position pushed IRC_NORMAL_OFFSET cells
// along the surface normal (into the air in front of a face -> avoids sampling the
// surface's own occupied cell, the usual leak source). Optionally rejects the
// offset point if it lands inside solid geometry and falls back to a shorter
// offset. Returns the interpolated (rgb sum, a weight); .a == 0 means "no data".
vec4 ircTap(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec3 samplePos = worldPos + normal * (IRC_NORMAL_OFFSET * IRC_CELLF);

#ifdef IRC_OCCLUSION_GUARD
    // Voxel grid uses a 1-block origin (distinct from the IRC origin).
    vec3  voxOrigin = floor(camPos) - VOXEL_RADIUS_VEC;
    ivec3 vox = ivec3(floor(samplePos - voxOrigin));
    if (all(greaterThanEqual(vox, ivec3(0))) && all(lessThan(vox, VOXEL_DIMS))
        && sampleVoxel(atlas, vox) != VOXEL_AIR) {
        // Offset point is buried in geometry; pull the read back toward the face.
        samplePos = worldPos + normal * (0.35 * IRC_CELLF);
    }
#endif

    vec3 cellF = ircCellCoordF(samplePos, camPos);
    if (!ircInRange(cellF)) return vec4(0.0);
    vec3 uv = cellF / IRC_DIMSF;
    return textureLod(irc, uv, 0.0);
}

// Resolved mean irradiance at a surface (0 if the cell has no data yet).
vec3 readIRC(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec4 t = ircTap(irc, atlas, worldPos, normal, camPos);
    return t.rgb / max(t.a, 1e-4);
}

// Spatially-filtered read: center tap (weighted) + 6 axis neighbours one cell out.
// Summing (rgb,a) before dividing makes it an a-WEIGHTED average, so empty/occluded
// neighbour cells (a==0) drop out instead of darkening the result. This is the
// in-cache spatial smoothing the technique relies on to suppress the residual
// per-cell Monte-Carlo flicker (each cell's 1-spp noise is independent, so the
// 7-tap average cuts the visible shimmer ~sqrt(7)x). Returns (smoothed rgb, center a).
vec4 ircTapSmooth(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec4 c = ircTap(irc, atlas, worldPos, normal, camPos);
#ifndef IRC_SPATIAL_FILTER
    return vec4(c.rgb / max(c.a, 1e-4), c.a); // sharpest: single trilinear tap
#else
    vec4 sum = c * 2.0; // center weighted
    float d = IRC_CELLF;
    sum += ircTap(irc, atlas, worldPos + vec3( d, 0.0, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(-d, 0.0, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0,  d, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, -d, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, 0.0,  d), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, 0.0, -d), normal, camPos);
    return vec4(sum.rgb / max(sum.a, 1e-4), c.a); // value = weighted mean; .a = center weight (for the giSky-fallback gate)
#endif
}

// Nearest integer cell in front of a surface, for an imageLoad feedback read from
// inside the update compute pass (the cache is bound as an image there, not a
// sampler, so we can't trilinear-filter — a point fetch is fine for the bounce).
bool ircCoordOf(vec3 worldPos, vec3 normal, vec3 camPos, out ivec3 cell) {
    vec3 cF = ircCellCoordF(worldPos + normal * (IRC_NORMAL_OFFSET * IRC_CELLF), camPos);
    cell = ivec3(floor(cF));
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, IRC_DIMS));
}

#endif
