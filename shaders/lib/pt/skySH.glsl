#ifndef PT_SKY_SH_GLSL
#define PT_SKY_SH_GLSL

// ---------------------------------------------------------------------------
// Sky radiance projected onto second-order spherical harmonics, rebuilt once
// per frame.
//
// WHY. Every ray that misses geometry asks the sky what colour it is, and
// sampleSky_fast answers with four texelFetches into the 256x256 atmosphere LUT
// plus a handful of transcendentals. That runs per missed ray in BOTH the final
// gather and the surface cache's bounce loop, and misses are the common case in
// open terrain. Nine coefficients replace all of it with about twenty FMAs and
// no memory traffic at all.
//
// It is also LESS NOISY, which is the part worth understanding. The sky term is
// a Monte Carlo estimate over very few rays; sampling a LUT gives each ray an
// independent value carrying the LUT's own high-frequency detail, and that
// detail is variance the temporal filter then has to remove. SH is a smooth
// analytic function, so the same ray count lands on a cleaner answer. For
// DIFFUSE gathering that detail was never going to survive the cosine integral
// anyway -- this throws it away up front instead of paying for it and then
// filtering it out.
//
// WHAT IT COSTS. Second-order SH cannot represent a sharp edge, and the sky has
// one: the ground/horizon split at rd.y ~ 0. The reconstruction smooths that
// transition and, being a truncated series, rings slightly negative just past it
// -- hence the clamp in skySHRadiance, which is load-bearing, not defensive.
//
// The projection was checked numerically against a WORST-CASE hard step with
// 6.7:1 sky-to-ground contrast (the real sky is far smoother):
//
//   constant sky reconstructs to 1.0000 +/- 0.0002   -- normalisation is exact
//   mean radiance over the sphere        0.000% error -- no overall brightness shift
//   per-direction, straight up           +21%         -- the classic L2 overshoot
//   per-direction, straight down         rings to -0.06, clamped to 0
//
// Per-DIRECTION error looks alarming, but the gather does not consume single
// directions -- it consumes the cosine-weighted hemisphere integral, where the
// overshoot and the undershoot cancel:
//
//   floor   (up-facing)   +0.0%
//   wall    (side-facing) -0.7%
//   45 deg                -0.2%
//   ceiling (down-facing) +4.3%
//
// So the only orientation that moves meaningfully is a ceiling, which gets
// slightly more bounce -- defensible, since the real sky is not a hard step to
// begin with. GI_SKY_SH turns this off and restores the exact LUT path if that
// is not wanted.
//
// This is only for DIFFUSE ray misses. Anything that renders the sky itself, or
// needs the sun/moon discs, must keep using the LUT.
// ---------------------------------------------------------------------------

layout(std430, binding = 3) buffer SkyShBuffer {
    // vec4 rather than vec3: std430 pads a vec3 to 16 bytes in an array anyway,
    // so being explicit avoids any layout ambiguity between the writer and the
    // readers. Only .rgb carries data.
    vec4 L[9];
} skySH;

// Real second-order SH basis. The choice of polar axis is irrelevant as long as
// projection and evaluation use the same one -- it is a complete orthonormal
// basis either way -- so this is the textbook z-up form used verbatim.
void skySHBasis(vec3 d, out float Y[9]) {
    Y[0] = 0.282095;
    Y[1] = 0.488603 * d.y;
    Y[2] = 0.488603 * d.z;
    Y[3] = 0.488603 * d.x;
    Y[4] = 1.092548 * d.x * d.y;
    Y[5] = 1.092548 * d.y * d.z;
    Y[6] = 0.315392 * (3.0 * d.z * d.z - 1.0);
    Y[7] = 1.092548 * d.x * d.z;
    Y[8] = 0.546274 * (d.x * d.x - d.y * d.y);
}

// Reconstructed sky RADIANCE along d -- a drop-in replacement for
// sampleSky_fast in a diffuse ray-miss, not an irradiance evaluation. The
// caller still applies its own occlusion weighting, so the per-ray directional
// structure the tracer provides is untouched.
vec3 skySHRadiance(vec3 d) {
    float Y[9];
    skySHBasis(d, Y);

    vec3 r = skySH.L[0].rgb * Y[0];
    r += skySH.L[1].rgb * Y[1];
    r += skySH.L[2].rgb * Y[2];
    r += skySH.L[3].rgb * Y[3];
    r += skySH.L[4].rgb * Y[4];
    r += skySH.L[5].rgb * Y[5];
    r += skySH.L[6].rgb * Y[6];
    r += skySH.L[7].rgb * Y[7];
    r += skySH.L[8].rgb * Y[8];

    // A truncated series overshoots at the horizon step and can dip below zero.
    // Negative radiance would subtract light from the gather and, through the
    // surface cache's feedback loop, keep subtracting it.
    return max(r, vec3(0.0));
}

#endif
