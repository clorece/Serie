#ifndef PT_RADIANCE_CACHE_GLSL
#define PT_RADIANCE_CACHE_GLSL

// ---------------------------------------------------------------------------
// World radiance cache (Phase 3.2): a sparse volume of irradiance probes that
// answers "what does the far field look like from here".
//
// WHAT IT IS FOR. Two questions the surface cache structurally cannot answer,
// because both arise from rays that never reach a surface:
//
//   1. A gather ray that exhausts GI_GATHER_DIST, or a surface-cache bounce ray
//      that exhausts SC_BOUNCE_DIST, has stopped in mid-air inside the grid. It
//      has no hit point, so there is no card to look up. Until now it received
//      flat sky scaled by the receiving surface's skylight -- which is why a
//      large room lit by a doorway read as a uniform blue wash rather than as
//      light from the doorway.
//   2. Distant Horizons LOD terrain sits far outside every voxel cascade, so
//      shadeDhTerrain had no traced answer at all and used a hardcoded
//      ambientColor * GI_SKY_BRIGHTNESS constant.
//
// Both now read this volume.
//
// WHY A PROBE GRID AND NOT MORE CASCADES. The surface cache was extended to
// cover coarser cascades in this same phase, and that is what fixes far HITS
// (see surfaceCache.glsl). It cannot fix either case above: a ray that stopped
// in air has no face to address, and DH terrain is past the coarsest cascade
// entirely. The two structures are complementary, exactly as they are in Lumen,
// where the surface cache and the world radiance cache coexist.
//
// COST. Deliberately tiny. RC_XZ x RC_Y x RC_XZ = 32 x 16 x 32 = 16384 probes,
// four RGBA16F texels each (L1 spherical harmonics, three bands of directional
// detail plus a constant term) = 512 KB total. At the default 16-block spacing
// that covers 512 x 256 x 512 blocks around the camera. The whole volume is one
// small compute dispatch that traces a few thousand rays per frame.
//
// ---- Storage layout --------------------------------------------------------
//
// giProbeImg is RC_XZ x (RC_Y * 4) x RC_XZ, the same "stack along Y" convention
// the voxel atlas and the surface cache use:
//
//   layer 0   .rgb = SH L0            .a = validity tag
//   layer 1   .rgb = SH L1 (y)        .a = mean hit distance
//   layer 2   .rgb = SH L1 (z)        .a = unused
//   layer 3   .rgb = SH L1 (x)        .a = unused
//
// These are RADIANCE coefficients, not irradiance. The cosine convolution is
// applied at evaluation time (rcIrradiance) because the probe has no normal of
// its own -- the caller supplies one.
//
// ---- Addressing ------------------------------------------------------------
//
// Toroidal, for the same reason the surface cache is: the volume is anchored to
// the camera, so a world-indexed slot survives camera motion and only the newly
// exposed shell goes stale. RC_XZ and RC_Y are powers of two so the wrap is a
// bitmask, and a tag in layer 0's alpha catches a slot whose world probe changed
// under it -- a stale probe reads as invalid rather than as light from 512
// blocks away.
//
// ---- Leaking ---------------------------------------------------------------
//
// The classic failure of an irradiance volume is trilinear interpolation
// dragging outdoor light through a wall from a probe on the other side. DDGI
// solves it with a per-probe octahedral depth map and a Chebyshev test. That is
// a second, larger volume and a second set of rays, and it is overkill for a
// term that only ever lands beyond GI_GATHER_DIST.
//
// Instead each probe stores the MEAN distance its rays travelled, and a probe is
// down-weighted when the point being shaded is further away than that mean. This
// is a scalar stand-in for the directional test and it catches the case that
// actually matters here: a probe buried in rock hits geometry immediately, so
// its mean distance collapses toward zero and it stops contributing to anything
// outside its own cell. It does not catch a probe in an adjacent open room, so
// callers still apply their own sky-access gate on top.
// ---------------------------------------------------------------------------

#include "/lib/options.glsl"

// Probe counts per axis. FIXED, not derived from the spacing: RC_SPACING changes
// how much world the volume covers, never how much memory it costs.
#define RC_XZ 32
#define RC_Y  16

#define RC_SH_LAYERS 4

#define RC_MASK_XZ (RC_XZ - 1)
#define RC_MASK_Y  (RC_Y  - 1)
#define RC_SHIFT_XZ 5
#define RC_SHIFT_Y  4

const ivec3 RC_PROBE_DIMS  = ivec3(RC_XZ, RC_Y, RC_XZ);
const ivec3 RC_IMAGE_DIMS  = ivec3(RC_XZ, RC_Y * RC_SH_LAYERS, RC_XZ);
#define RC_PROBE_COUNT (RC_XZ * RC_Y * RC_XZ)

// ---- Grid geometry ---------------------------------------------------------

// Probe grid coordinate containing a world position (may be outside the window).
ivec3 rcProbeCoord(vec3 worldPos) {
    return ivec3(floor(worldPos / float(RC_SPACING)));
}

// Minimum corner of the window, in probe coordinates. Snapped to whole probes so
// the lattice stays still as the camera moves -- the same reason
// cascadeOrigin() snaps.
ivec3 rcOriginProbe() {
    return ivec3(floor(cameraPosition / float(RC_SPACING))) - RC_PROBE_DIMS / 2;
}

vec3 rcProbeWorldPos(ivec3 pg) {
    return (vec3(pg) + 0.5) * float(RC_SPACING);
}

bool rcInWindow(ivec3 pg) {
    ivec3 org = rcOriginProbe();
    return all(greaterThanEqual(pg, org)) && all(lessThan(pg, org + RC_PROBE_DIMS));
}

// ---- Toroidal addressing ---------------------------------------------------

ivec3 rcWrap(ivec3 pg) {
    return ivec3(pg.x & RC_MASK_XZ, pg.y & RC_MASK_Y, pg.z & RC_MASK_XZ);
}

ivec3 rcImageCoord(ivec3 pg, int layer) {
    ivec3 t = rcWrap(pg);
    return ivec3(t.x, t.y + layer * RC_Y, t.z);
}

// Same two-bits-per-axis scheme as scTag: exact in an fp16 alpha, and two slots
// sharing a tag would have to sit 4*RC_XZ probes apart, far outside the window.
float rcTag(ivec3 pg) {
    uint tx = uint(pg.x >> RC_SHIFT_XZ) & 3u;
    uint ty = uint(pg.y >> RC_SHIFT_Y ) & 3u;
    uint tz = uint(pg.z >> RC_SHIFT_XZ) & 3u;
    return float(tx | (ty << 2) | (tz << 4));
}

// Inverse of the wrap: the unique probe inside the window whose slot is `slot`.
ivec3 rcSlotToProbe(ivec3 slot, ivec3 org) {
    return ivec3(org.x + ((slot.x - org.x) & RC_MASK_XZ),
                 org.y + ((slot.y - org.y) & RC_MASK_Y ),
                 org.z + ((slot.z - org.z) & RC_MASK_XZ));
}

// ---- SH ---------------------------------------------------------------------
//
// L1 real spherical harmonics, same convention (and same polar axis) as
// lib/pt/skySH.glsl so the two can be reasoned about together.
//
//   Y0 = 0.282095
//   Y1 = 0.488603 * y      Y2 = 0.488603 * z      Y3 = 0.488603 * x
//
// Projection is a Monte Carlo integral over UNIFORM sphere directions, so each
// sample carries 4*PI/N. Reconstruction to irradiance uses the Ramamoorthi
// convolution coefficients A0 = PI, A1 = 2*PI/3.

struct RcSH { vec3 l0; vec3 l1y; vec3 l1z; vec3 l1x; float meanDist; };

RcSH rcSHZero() {
    RcSH s;
    s.l0 = vec3(0.0); s.l1y = vec3(0.0); s.l1z = vec3(0.0); s.l1x = vec3(0.0);
    s.meanDist = 0.0;
    return s;
}

// Accumulate one uniform-sphere radiance sample.
void rcSHAccum(inout RcSH s, vec3 dir, vec3 radiance) {
    s.l0  += radiance * 0.282095;
    s.l1y += radiance * (0.488603 * dir.y);
    s.l1z += radiance * (0.488603 * dir.z);
    s.l1x += radiance * (0.488603 * dir.x);
}

void rcSHScale(inout RcSH s, float f) {
    s.l0 *= f; s.l1y *= f; s.l1z *= f; s.l1x *= f;
}

// Cosine-weighted MEAN INCIDENT RADIANCE about n, i.e. irradiance / PI.
//
// That unit, not irradiance, because every consumer here is substituting this
// for radiance values it would otherwise have summed over cosine-distributed
// rays -- the gather, the surface cache bounce loop, and the d7 indirect seam
// all work in irradiance/PI. Folding the 1/PI in at the single point of
// evaluation is the only way to keep that contract in one place.
//
//   E(n)/PI = L0*Y0(n) + (2/3) * (L1y*Y1(n) + L1z*Y2(n) + L1x*Y3(n))
vec3 rcSHRadiance(RcSH s, vec3 n) {
    vec3 r = s.l0 * 0.282095
           + (s.l1y * (0.488603 * n.y)
           +  s.l1z * (0.488603 * n.z)
           +  s.l1x * (0.488603 * n.x)) * (2.0 / 3.0);
    // A truncated series can ring negative where the radiance field has a sharp
    // edge. Negative radiance would subtract light, and through the surface
    // cache's feedback loop it would keep subtracting it.
    return max(r, vec3(0.0));
}

// ---- Access ----------------------------------------------------------------
// RC_READ  -> sampler3D giProbeSampler, for consumers.
// RC_IMAGE -> image3D  giProbeImg,      for the update pass.

#ifdef RC_READ
uniform sampler3D giProbeSampler;

// One probe, or an all-zero SH with meanDist 0 when the slot is stale. A
// meanDist of 0 makes rcSample() reject it, so an invalid probe can never
// contribute -- there is no separate validity flag to forget to check.
RcSH rcFetch(ivec3 pg) {
    RcSH s = rcSHZero();
    vec4 c0 = texelFetch(giProbeSampler, rcImageCoord(pg, 0), 0);
    if (abs(c0.a - rcTag(pg)) >= 0.5) return s;
    vec4 c1 = texelFetch(giProbeSampler, rcImageCoord(pg, 1), 0);
    s.l0  = c0.rgb;
    s.l1y = c1.rgb;
    s.l1z = texelFetch(giProbeSampler, rcImageCoord(pg, 2), 0).rgb;
    s.l1x = texelFetch(giProbeSampler, rcImageCoord(pg, 3), 0).rgb;
    s.meanDist = c1.a;
    return s;
}

// Trilinearly interpolated far-field radiance about n at a world position.
// Returns false when nothing usable covers the point, so the caller can keep its
// own fallback rather than being handed a plausible-looking zero.
bool rcSample(vec3 worldPos, vec3 n, out vec3 radiance) {
    radiance = vec3(0.0);

    vec3  grid = worldPos / float(RC_SPACING) - 0.5;
    ivec3 base = ivec3(floor(grid));
    vec3  frac = grid - vec3(base);

    vec3  sum  = vec3(0.0);
    float wsum = 0.0;

    for (int i = 0; i < 8; ++i) {
        ivec3 off = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        ivec3 pg  = base + off;
        if (!rcInWindow(pg)) continue;

        RcSH p = rcFetch(pg);
        if (p.meanDist <= 0.0) continue;   // stale slot, or never traced

        vec3  tri = mix(1.0 - frac, frac, vec3(off));
        float w   = tri.x * tri.y * tri.z;
        if (w <= 0.0) continue;

        // Face the probe. A probe behind the surface being shaded is looking at
        // the wrong side of it; the smooth wrap (rather than a hard cut) keeps
        // the weight field continuous so the volume does not band.
        vec3  toProbe = rcProbeWorldPos(pg) - worldPos;
        float d       = length(toProbe);
        if (d > 1e-4) {
            float facing = dot(toProbe / d, n) * 0.5 + 0.5;
            w *= facing * facing + 0.2;
        }

        // Scalar stand-in for DDGI's Chebyshev visibility test. A probe whose
        // rays die immediately is inside geometry; one further from us than its
        // own mean ray length is probably behind a wall.
        w *= clamp(p.meanDist / max(d, 1e-4), 0.0, 1.0);

        sum  += rcSHRadiance(p, n) * w;
        wsum += w;
    }

    if (wsum <= 1e-5) return false;
    radiance = sum / wsum;
    return true;
}
#endif

#ifdef RC_IMAGE
layout(rgba16f) uniform image3D giProbeImg;

RcSH rcImageFetch(ivec3 pg) {
    RcSH s = rcSHZero();
    vec4 c0 = imageLoad(giProbeImg, rcImageCoord(pg, 0));
    if (abs(c0.a - rcTag(pg)) >= 0.5) return s;
    vec4 c1 = imageLoad(giProbeImg, rcImageCoord(pg, 1));
    s.l0  = c0.rgb;
    s.l1y = c1.rgb;
    s.l1z = imageLoad(giProbeImg, rcImageCoord(pg, 2)).rgb;
    s.l1x = imageLoad(giProbeImg, rcImageCoord(pg, 3)).rgb;
    s.meanDist = c1.a;
    return s;
}

void rcImageStore(ivec3 pg, RcSH s) {
    float tag = rcTag(pg);
    imageStore(giProbeImg, rcImageCoord(pg, 0), vec4(s.l0,  tag));
    imageStore(giProbeImg, rcImageCoord(pg, 1), vec4(s.l1y, s.meanDist));
    imageStore(giProbeImg, rcImageCoord(pg, 2), vec4(s.l1z, 0.0));
    imageStore(giProbeImg, rcImageCoord(pg, 3), vec4(s.l1x, 0.0));
}
#endif

#endif
