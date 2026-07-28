// dr0_reflect : opaque specular reflections on the Lumen tracing stack (Phase 3.4)
//
// Runs after d7_composite (lit scene in colortex0) and before dr1, which does
// the spatial denoise and the composite. This pass only WRITES colortex4 -- the
// demodulated reflection plus its history length -- and leaves colortex0 alone.
//
// ---- What changed from the screen-space version ---------------------------
//
// The pass this replaces (d7b_reflections, deleted in Phase 1) marched the depth
// buffer and, on a hit, sampled the PREVIOUS frame's resolved colour reprojected
// to the hit point. That gave sharp reflections of whatever happened to be on
// screen and nothing at all of what was not: no reflection of anything behind
// the camera, off the edge of the frame, or occluded from the camera's view --
// the three cases a reflection most obviously needs.
//
// Rays now go through traceVoxelCascadedCone and resolve their hits through the
// surface cache, exactly like the diffuse gather. That is the entire point of
// the Lumen architecture: once the cache is paid for, a reflection ray costs a
// DDA walk plus one texel fetch, with no shading, no shadow lookup and no
// material evaluation at the hit. It also means reflections see the whole world,
// not the visible part of it.
//
// The denoiser is deliberately kept from the old pass. It was already
// Lumen-shaped -- demodulate, temporally accumulate, blur spatially, re-modulate
// with a sharp per-texel Fresnel -- and four specific pieces of it are worth
// more than a rewrite: the G2/G1 ratio-estimator demodulation, Karis
// inverse-luma ray weighting, screen-velocity history rejection, and dr1's
// history-driven adaptive blur radius.
//
// ---- What the surface cache can and cannot give a reflection --------------
//
// The cache stores DIFFUSE outgoing radiance per voxel face. So a reflection
// shows the diffusely-lit world, correctly and from any angle, but it cannot
// show a reflection OF a reflection -- a mirror facing a mirror resolves to the
// diffuse colour of the second mirror's blocks. Lumen has the same property for
// the same reason, and it is invisible for everything except deliberately
// staged mirror pairs.
//
// ---- Requires INTEGRATED_PBR ----------------------------------------------
//
// The material this pass reads (colortex7) is written by gbuffers_terrain only
// under INTEGRATED_PBR. With that off, colortex7 clears to zero, every pixel
// takes the early-out below, and this pass costs one texture fetch per pixel and
// produces nothing. That is intentional -- it makes the reflection stack safe to
// leave enabled -- but it does mean turning SPECULAR_REFLECTIONS on by itself
// changes nothing on screen.

#ifdef VERTEX

#include "/lib/options.glsl"

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    // Scaled passes squeeze into the bottom-left corner of the full-res buffer.
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"

#define SC_READ

// Reflection rays are real cache consumers and must stamp what they resolve
// through, or the bricks a mirror is looking at go stale while the diffuse
// gather keeps only the bricks the camera looks at directly warm.
#ifdef SURFACE_CACHE_FEEDBACK
    #define SC_FEEDBACK
    #define SC_FEEDBACK_WRITE
#endif

#ifdef RADIANCE_CACHE
    #define RC_READ
#endif

#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

vec3 clipSpace; // referenced by positions.glsl; must precede the include

#include "/lib/util/positions.glsl"
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/radianceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/fragment/pbrCommon.glsl"

in vec2 texCoord;

void main() {
    /* RENDERTARGETS: 4 */

    vec2 uv = texCoord;

    vec4  mat        = texture(colortex7, uv * renderScale);
    float smoothness = pbrSmoothness(mat.a);
    float depth      = texture(depthtex0, uv * renderScale).r;

    // Only PBR pixels smooth enough to show a reflection do any work.
    // REFLECTION_SMOOTHNESS_MIN doubles as the performance cutoff: raise it to
    // skip the matte families (dirt/wood/wool/rough stone).
    //
    // dr1 repeats this exact test. The two must agree or a pixel gets a
    // composite built on a colortex4 value this pass never wrote.
    if (depth >= 1.0 || !pbrIsPBR(mat.a) || smoothness < REFLECTION_SMOOTHNESS_MIN) {
        gl_FragData[0] = vec4(0.0); // also resets the reflection history
        return;
    }

    vec2 unjit = uv;
    #ifdef TAA
        unjit -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif

    // Position reconstruction always feeds the LOGICAL uv to clip space, because
    // gbufferProjectionInverse is the un-jittered projection. The G-buffers
    // themselves are rasterised jittered and so are read at uv.
    vec3 viewPos   = convertScreenSpaceToWorldSpace(unjit, depth);
    vec3 N         = normalize(texture(colortex1, uv * renderScale).rgb * 2.0 - 1.0);
    vec3 V         = normalize(-viewPos);   // surface -> camera
    vec3 I         = normalize(viewPos);    // camera -> surface

    vec3 playerPos   = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPos    = playerPos + cameraPosition;
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * N);

    float roughness = 1.0 - smoothness;
    float alpha     = max(roughness * roughness, 1e-4);
    float alphaSq   = alpha * alpha;
    float NoV       = clamp(dot(N, V), 1e-3, 1.0);
    bool  isMetal   = pbrIsMetal(mat.a);

    // Steep skylight gate: indoor metals reflect the room, not the sky.
    float skylight = clamp(texture(colortex2, uv * renderScale).g, 0.0, 1.0);
    float skyGate  = pow(clamp(skylight / 0.75, 0.0, 1.0), REFLECTION_SKY_FADE);

    // This surface's own diffuse GI, as the last-resort environment for a ray
    // that neither hit anything nor has a far-field answer.
    vec3 giAmbient = vec3(0.0);
    #ifdef VOXEL_GI
        giAmbient = texture(colortex8, unjit * renderScale).rgb;
    #endif

    float eyeAlt = cameraPosition.y - 64.0;
    mat3  tbn    = tbnFromNormal(N);
    vec3  Vt     = V * tbn;   // view dir in tangent space

    // Cone stepping scaled by roughness. A near-mirror must keep cascade-0 detail
    // all the way out or its reflection visibly coarsens with distance; a rough
    // surface is integrating over a wide lobe anyway and cannot resolve what the
    // promotion throws away. Zero disables promotion entirely (see voxelTrace).
    float coneBase = float(REFLECTION_CONE_BASE) * roughness;

    vec3  reflection = vec3(0.0);
    float reflWsum   = 0.0;
    uint  seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

    for (int s = 0; s < REFLECTION_RAYS; s++) {
        vec2 hash = vec2(randFloat(seed), randFloat(seed));
        vec3 Ht   = sampleGGXVNDF(Vt, alpha, hash);
        vec3 H    = tbn * Ht;        // microfacet normal, view space
        vec3 rdir = reflect(I, H);   // reflected ray, view space

        float NoL = dot(N, rdir);
        if (NoL <= 1e-3) continue;

        vec3 worldRdir = normalize(mat3(gbufferModelViewInverse) * rdir);

        // Lift the origin off the surface so the first voxel stepped is the air
        // in front of it rather than the block the pixel belongs to.
        VoxelHit h = traceVoxelCascadedCone(worldPos + worldNormal * 0.05, worldRdir,
                                            float(REFLECTION_DIST), true, coneBase);

        vec3 radiance;
        // scHasCoverage, not h.hit: a hit the cache does not cover (an entity
        // box, or a ray past cascade SC_CASCADES-1) has nothing to look up, and
        // must fall through to the environment rather than reflect black.
        if (h.hit && scHasCoverage(h.cascade)) {
            // The whole point: resolve the hit through the cache instead of
            // shading it, at the cascade that RESOLVED it. Emitters passed on the
            // way are additive, so a torch just out of frame still shows up in a
            // polished floor.
            radiance = scLookupAt(h.pos, h.normal, h.cascade) + h.emission;
        } else {
            // Sky reflection strength is scaled globally, and further for
            // dielectrics so they keep their F0-driven scene reflection without
            // the flat sky wash.
            float skyMul = REFLECTION_SKY_STRENGTH * (isMetal ? 1.0 : PBR_DIELECTRIC_REFLECT);
            vec3  sky    = getSkyReflection(worldRdir, eyeAlt) * skyMul;

            if (h.escaped) {
                // Left the cascades outright: nothing can occlude it, the sky is
                // simply the answer.
                radiance = sky;
            } else {
                // Ran out of REFLECTION_DIST inside the grid. The far field is
                // unknown from here, which is exactly what the radiance cache is
                // for; the old pass had nothing better than the shading surface's
                // own diffuse GI, which is a different point in space entirely.
                radiance = mix(giAmbient, sky, skyGate);
                #ifdef RADIANCE_CACHE
                {
                    vec3 rcRad;
                    if (rcSample(h.pos, worldRdir, rcRad)) radiance = rcRad;
                }
                #endif
            }
            radiance += h.emission;
        }

        // Hard ceiling on pathological HDR spikes before they enter the average.
        radiance = min(radiance, vec3(REFLECTION_FIREFLY_CLAMP));

        // DEMODULATED: accumulate the environment reflection WITHOUT the metal
        // albedo tint, carrying only the VNDF geometry weight. The per-texel tint
        // (= the block texture) is re-applied sharp in dr1, AFTER the temporal and
        // spatial denoise, so blurring the reflection never smears the texture.
        // The weight is the G2/G1 ratio estimator (height-correlated Smith),
        // bounded at 1; F is the tint and is deliberately not here.
        float v1 = smithGGX_v1(NoV, alphaSq);
        float v2 = smithGGX_v2(NoL, NoV, alphaSq);
        vec3  sampleRefl = radiance * (2.0 * NoL * v2 / max(v1, 1e-6));

        // Karis firefly-free averaging: weight each ray by inverse luma so one
        // ray catching a bright emitter cannot dominate the mean as a sparkle.
        // Self-correcting -- on a smooth surface every ray hits the same thing,
        // the weights are equal, and a legitimately bright reflection is not
        // dimmed; only where rays diverge is the lone outlier suppressed.
        float w = 1.0 / (1.0 + dot(sampleRefl, vec3(0.2126, 0.7152, 0.0722)) * REFLECTION_FIREFLY_WEIGHT);
        reflection += sampleRefl * w;
        reflWsum   += w;
    }
    reflection /= max(reflWsum, 1e-6);
    if (any(isnan(reflection))) reflection = vec3(0.0);

    // --- Temporal accumulation ----------------------------------------------
    float histLenOut = 1.0;
    #ifdef REFLECTION_DENOISE
    {
        // Reproject this surface by camera motion. Both matrices are un-jittered
        // and the reflection buffer is indexed by logical uv, so no jitter enters
        // this path -- the same convention dg0_gather follows.
        vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
        vec4 clipPrev   = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
        vec2 uvPrev     = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;

        float histLen  = 0.0;
        vec3  histRefl = reflection;
        vec2  pad = 1.5 / vec2(viewWidth, viewHeight);

        if (clipPrev.w > 0.0 && all(greaterThanEqual(uvPrev, pad)) && all(lessThan(uvPrev, 1.0 - pad))) {
            // Disocclusion: the surface now at uvPrev must be this one.
            float dPrev = texture(depthtex0, uvPrev * renderScale).r;
            if (dPrev < 1.0) {
                vec3 prevView = convertScreenSpaceToWorldSpace(uvPrev, dPrev);
                vec3 prevRel  = (gbufferModelViewInverse * vec4(prevView, 1.0)).xyz;
                if (distance(prevRel, playerPos) < 0.05 * length(viewPos) + 0.25) {
                    vec4 h = texture(colortex4, uvPrev * renderScale);
                    histRefl = h.rgb;
                    histLen  = h.a;
                }
            }
        }

        // Reflections are view-dependent: the reflected content changes as the
        // view changes even when the surface reprojects perfectly, and
        // accumulating stale reflections is what smears them. Reject history by
        // how far the surface moved ON SCREEN, which captures camera rotation and
        // parallax that a world-position delta misses. Smoother surfaces are more
        // view-dependent, so they reject harder.
        float velPx  = length((uvPrev - unjit) * vec2(viewWidth, viewHeight));
        float reject = smoothstep(2.0, mix(16.0, 7.0, smoothness), velPx);
        histLen *= 1.0 - reject;

        histLen    = min(histLen + 1.0, float(REFLECTION_ACCUM_FRAMES));
        reflection = mix(histRefl, reflection, 1.0 / histLen);
        histLenOut = histLen;
    }
    #endif

    // colortex4: the DEMODULATED environment reflection (no tint) for dr1 to
    // blur, plus the history length that drives dr1's adaptive radius.
    gl_FragData[0] = vec4(reflection, histLenOut);
}

#endif
