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

// IRC_ANTI_LEAK_PATCH: comment out this one line to disable the corner/crevice fix.
#define IRC_ANTI_LEAK_PATCH

// True when a world-space point is either outside the voxel volume or in air.
// Outside is accepted because the IRC extends beyond the voxel volume near its edge.
bool ircPointIsOpen(usampler3D atlas, vec3 worldPos, vec3 camPos) {
    vec3  voxOrigin = floor(camPos) - VOXEL_RADIUS_VEC;
    ivec3 vox = ivec3(floor(worldPos - voxOrigin));
    if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, VOXEL_DIMS))) return true;
    return sampleVoxel(atlas, vox) == VOXEL_AIR;
}

// Cheap visibility test for the one-cell spatial-filter taps. Without this, a
// neighbour on the far side of a corner can be averaged into the current surface.
bool ircShortSegmentOpen(usampler3D atlas, vec3 a, vec3 b, vec3 camPos) {
    return ircPointIsOpen(atlas, a, camPos)
        && ircPointIsOpen(atlas, b, camPos);
}

// Cache tap at a world position pushed IRC_NORMAL_OFFSET cells
// along the surface normal (into the air in front of a face -> avoids sampling the
// surface's own occupied cell, the usual leak source). Optionally walks the offset
// back toward the face until it finds air. A tap is rejected if every candidate is
// solid; sampling a buried cache cell is much worse than temporarily returning no
// multibounce light. Returns (rgb sum, a weight); .a == 0 means "no data".
vec4 ircTap(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec3 samplePos = worldPos + normal * (IRC_NORMAL_OFFSET * IRC_CELLF);

#ifdef IRC_OCCLUSION_GUARD
#ifdef IRC_ANTI_LEAK_PATCH
    if (!ircPointIsOpen(atlas, samplePos, camPos)) {
        samplePos = worldPos + normal * (0.65 * IRC_CELLF);
        if (!ircPointIsOpen(atlas, samplePos, camPos)) {
            samplePos = worldPos + normal * (0.35 * IRC_CELLF);
            if (!ircPointIsOpen(atlas, samplePos, camPos)) {
                samplePos = worldPos + normal * (0.15 * IRC_CELLF);
                if (!ircPointIsOpen(atlas, samplePos, camPos)) return vec4(0.0);
            }
        }
    }
#else
    if (!ircPointIsOpen(atlas, samplePos, camPos))
        samplePos = worldPos + normal * (0.35 * IRC_CELLF);
#endif
#endif

    vec3 cellF = ircCellCoordF(samplePos, camPos);
    if (!ircInRange(cellF)) return vec4(0.0);
#if defined(IRC_OCCLUSION_GUARD) && defined(IRC_ANTI_LEAK_PATCH)
    // Hardware trilinear filtering cannot distinguish an air cache cell from a
    // solid one. Reconstruct the same filter here and discard solid corners so a
    // bright cell embedded in/across a wall cannot contribute through the kernel.
    vec3 texelF = cellF - 0.5;
    ivec3 base = ivec3(floor(texelF));
    vec3 f = fract(texelF);
    vec4 sum = vec4(0.0);
    float weightSum = 0.0;
    for (int z = 0; z < 2; ++z) {
        for (int y = 0; y < 2; ++y) {
            for (int x = 0; x < 2; ++x) {
                ivec3 o = ivec3(x, y, z);
                ivec3 q = base + o;
                if (any(lessThan(q, ivec3(0))) || any(greaterThanEqual(q, IRC_DIMS))) continue;
                vec3 side = mix(vec3(1.0) - f, f, vec3(o));
                float w = side.x * side.y * side.z;
                if (w <= 0.0 || !ircPointIsOpen(atlas, ircCellCenter(q, camPos), camPos)) continue;
                sum += texelFetch(irc, q, 0) * w;
                weightSum += w;
            }
        }
    }
    return weightSum > 1e-4 ? sum / weightSum : vec4(0.0);
#else
    vec3 uv = cellF / IRC_DIMSF;
    return textureLod(irc, uv, 0.0);
#endif
}

// Resolved mean irradiance at a surface (0 if the cell has no data yet).
vec3 readIRC(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec4 t = ircTap(irc, atlas, worldPos, normal, camPos);
    return t.rgb / max(t.a, 1e-4);
}

// Spatially-filtered read: center tap (weighted) + surface-tangent axis neighbours.
// Summing (rgb,a) before dividing makes it an a-WEIGHTED average, so empty/occluded
// neighbour cells (a==0) drop out instead of darkening the result. This is the
// in-cache spatial smoothing the technique relies on to suppress the residual
// per-cell Monte-Carlo flicker (each cell's 1-spp noise is independent, so the
// taps reduce shimmer). Normal-axis taps are suppressed because the negative one
// sits behind the surface; remaining taps also require a clear short voxel segment,
// preventing the filter from reaching around corners. Returns (smoothed rgb, center a).
vec4 ircTapSmooth(sampler3D irc, usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos) {
    vec4 c = ircTap(irc, atlas, worldPos, normal, camPos);
#ifndef IRC_SPATIAL_FILTER
    return vec4(c.rgb / max(c.a, 1e-4), c.a); // sharpest: single trilinear tap
#else
    vec4 sum = c * 2.0; // center weighted
    float d = IRC_CELLF;
#ifdef IRC_ANTI_LEAK_PATCH
    vec3 sampleCenter = worldPos + normal * (IRC_NORMAL_OFFSET * IRC_CELLF);
    vec3 tangentWeight = vec3(1.0) - abs(normal);

    vec3 p = sampleCenter + vec3(d, 0.0, 0.0);
    if (tangentWeight.x > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.x * ircTap(irc, atlas, worldPos + vec3(d, 0.0, 0.0), normal, camPos);
    p = sampleCenter - vec3(d, 0.0, 0.0);
    if (tangentWeight.x > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.x * ircTap(irc, atlas, worldPos - vec3(d, 0.0, 0.0), normal, camPos);

    p = sampleCenter + vec3(0.0, d, 0.0);
    if (tangentWeight.y > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.y * ircTap(irc, atlas, worldPos + vec3(0.0, d, 0.0), normal, camPos);
    p = sampleCenter - vec3(0.0, d, 0.0);
    if (tangentWeight.y > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.y * ircTap(irc, atlas, worldPos - vec3(0.0, d, 0.0), normal, camPos);

    p = sampleCenter + vec3(0.0, 0.0, d);
    if (tangentWeight.z > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.z * ircTap(irc, atlas, worldPos + vec3(0.0, 0.0, d), normal, camPos);
    p = sampleCenter - vec3(0.0, 0.0, d);
    if (tangentWeight.z > 0.01 && ircShortSegmentOpen(atlas, sampleCenter, p, camPos))
        sum += tangentWeight.z * ircTap(irc, atlas, worldPos - vec3(0.0, 0.0, d), normal, camPos);
#else
    sum += ircTap(irc, atlas, worldPos + vec3( d, 0.0, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(-d, 0.0, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0,  d, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, -d, 0.0), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, 0.0,  d), normal, camPos);
    sum += ircTap(irc, atlas, worldPos + vec3(0.0, 0.0, -d), normal, camPos);
#endif
    return vec4(sum.rgb / max(sum.a, 1e-4), c.a); // value = weighted mean; .a = center weight (for the giSky-fallback gate)
#endif
}

// Nearest integer cell in front of a surface, for an imageLoad feedback read from
// inside the update compute pass (the cache is bound as an image there, not a
// sampler, so we can't trilinear-filter — a point fetch is fine for the bounce).
bool ircCoordOf(usampler3D atlas, vec3 worldPos, vec3 normal, vec3 camPos, out ivec3 cell) {
    vec3 samplePos = worldPos + normal * (IRC_NORMAL_OFFSET * IRC_CELLF);
#if defined(IRC_OCCLUSION_GUARD) && defined(IRC_ANTI_LEAK_PATCH)
    if (!ircPointIsOpen(atlas, samplePos, camPos)) {
        samplePos = worldPos + normal * (0.35 * IRC_CELLF);
        if (!ircPointIsOpen(atlas, samplePos, camPos)) return false;
    }
#endif
    vec3 cF = ircCellCoordF(samplePos, camPos);
    cell = ivec3(floor(cF));
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, IRC_DIMS));
}

#endif
