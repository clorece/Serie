// dg0_gather : final gather + temporal accumulation
//
// Per pixel, casts a few cosine-weighted rays and resolves each one through the
// surface cache instead of shading it. That is the whole reason this is cheap
// enough to do per pixel: a ray costs a DDA walk plus one texel fetch, with no
// lighting, no shadow lookup and no material evaluation at the hit. The cache is
// already temporally converged, so the variance here is far below what the old
// 1-spp ReSTIR path produced, and a light temporal accumulation is enough --
// there is no a-trous chain behind this.
//
// Writes:
//   colortex8  .rgb accumulated GI (albedo-demodulated), .a history length
//   colortex15 .xy  oct-encoded WORLD normal, .z linear depth
//
// colortex15 is the reprojection key. Nothing wrote it after the ReSTIR chain
// was deleted, so this pass re-establishes it.
//
// ---- Jitter convention (the top source of silent breakage here) ------------
// G-buffers are rasterised WITH the TAA jitter; GI buffers are indexed by
// LOGICAL, un-jittered uv, because that is how d7_composite reads them
// (texture(buf, unjitteredTexCoord * renderScale)).
//
// So for this fragment at texCoord U:
//   - U *is* the logical position, and the GI written here belongs to it.
//   - the surface at logical U sits at U + jitter in the jittered G-buffer, so
//     every G-buffer read is offset by +jitter.
//   - position reconstruction feeds the LOGICAL uv to clip space, because
//     gbufferProjectionInverse is the un-jittered projection.

#include "/lib/options.glsl"

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    // Scaled passes squeeze into the bottom-left corner of the full-res buffer.
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#define SC_READ

// Feedback: this pass is the PRIMARY source of surface-cache update requests.
// Every ray that resolves through the cache stamps the brick it read, and
// sc1_surface_direct refuses to spend work on bricks nothing has stamped. That
// makes the cache's cost track what the camera can actually see rather than the
// size of the volume. Must come after options.glsl (which defines
// SURFACE_CACHE_FEEDBACK) and before surfaceCache.glsl (which reads these).
#ifdef SURFACE_CACHE_FEEDBACK
    #define SC_FEEDBACK
    #define SC_FEEDBACK_WRITE
#endif

#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"
#include "/lib/pt/reproject.glsl"
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/pt/skySH.glsl"

in vec2 texCoord;

void main() {
    /* RENDERTARGETS: 8,15 */

    vec2 jitterUV  = getTaaJitter() / vec2(viewWidth, viewHeight);
    vec2 logicalUV = texCoord;                       // this fragment IS logical
    vec2 gbufUV    = (texCoord + jitterUV) * renderScale;

    float depth = texture(depthtex0, gbufUV).r;

    // Sky: no indirect, and a depth key that can never match a surface.
    if (depth >= 1.0) {
        gl_FragData[0] = vec4(0.0, 0.0, 0.0, 0.0);
        gl_FragData[1] = vec4(0.0, 0.0, far, 0.0);
        return;
    }

    // --- reconstruct the surface -------------------------------------------
    vec4 clip = gbufferProjectionInverse * vec4(vec3(logicalUV, depth) * 2.0 - 1.0, 1.0);
    vec3 viewPos   = clip.xyz / clip.w;
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPos  = playerPos + cameraPosition;
    float linDepth = -viewPos.z;

    // colortex1 holds VIEW normals; the voxel world is world space.
    vec3 viewNormal  = normalize(texture(colortex1, gbufUV).rgb * 2.0 - 1.0);
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);

    // How much sky this surface can actually see. Vanilla's skylight lightmap is
    // the cheapest sound answer available and it is exactly zero deep in a cave.
    // Rays that die on GI_GATHER_DIST without escaping the grid know nothing
    // about the far field; charging them full sky is what floods a large cave,
    // because in a big enough room almost every ray exhausts its budget in open
    // air. Gating by real sky access is what makes the surface-cache bounce
    // visible at all -- unclamped sky is several times brighter than it, and
    // GI_STRENGTH scales both together so it can never be tuned out.
    float skyVis = texture(colortex2, gbufUV).g;
    skyVis = pow(clamp(skyVis, 0.0, 1.0), GI_SKY_LEAK_FALLOFF);

    // --- reprojection -------------------------------------------------------
    // Done BEFORE the gather, because how converged this pixel already is
    // decides how many rays it is worth casting. Nothing here depends on the
    // gather's result: reprojection needs only the surface, and when histLen is
    // 0 the blend weight below is exactly 1, so the history value is unused.
    //
    // Both matrices are un-jittered and the GI buffer is indexed by logical uv,
    // so no jitter enters this path at all.
    vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
    vec4 prevClip   = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 prevUV     = (prevClip.xy / prevClip.w) * 0.5 + 0.5;

    float histLen  = 0.0;
    float histKeep = 0.0;   // the stored length, un-incremented, for the skip path
    vec3  history  = vec3(0.0);

    if (prevClip.w > 0.0 && all(greaterThanEqual(prevUV, vec2(0.0))) && all(lessThan(prevUV, vec2(1.0)))) {
        vec4 h8  = texture(colortex8,  prevUV * renderScale);
        vec4 h15 = texture(colortex15, prevUV * renderScale);

        vec3  prevNormal = octDecodeNormal(h15.xy);
        float prevDepth  = h15.z;

        // Disocclusion gates: same plane, same surface orientation.
        bool depthOk  = abs(prevDepth - linDepth) < max(linDepth, 1.0) * GI_REJECT_DEPTH;
        bool normalOk = dot(prevNormal, worldNormal) > GI_REJECT_NORMAL;

        if (depthOk && normalOk) {
            histKeep = min(h8.a, float(GI_ACCUM_FRAMES));
            histLen  = min(h8.a + 1.0, float(GI_ACCUM_FRAMES));
            history  = h8.rgb;
        }
    }

    ivec2 pix = ivec2(gl_FragCoord.xy);

    // --- skip fully converged, near-static pixels ---------------------------
    // A pixel at GI_ACCUM_FRAMES is blending each new estimate at alpha = 1/33,
    // so it is already 97% resampled history -- tracing it again this frame
    // moves it by almost nothing. Letting such pixels trace only one frame in
    // GI_SKIP_PERIOD is close to free and takes a large bite out of the gather
    // in any scene that is not entirely in motion.
    //
    // Two guards make this safe:
    //   - only FULLY converged pixels qualify, so anything disoccluded, newly
    //     visible, or on moving geometry always traces;
    //   - only near-static ones, because a pixel that skips writes back
    //     bilinearly resampled history, and under sustained motion resampling
    //     without ever refreshing would slowly smear. (Converged pixels already
    //     resample every frame regardless, so this guard is belt-and-braces --
    //     the blur is inherent to temporal accumulation, not to skipping.)
    //
    // Which pixels skip is hashed per pixel so the skipped set is scattered
    // rather than a coherent pattern that could read as structure.
    #ifdef GI_CONVERGED_SKIP
    if (histLen >= float(GI_ACCUM_FRAMES)) {
        vec2 motionPx = (prevUV - logicalUV) * vec2(viewWidth, viewHeight) * renderScale;
        if (dot(motionPx, motionPx) < float(GI_SKIP_MOTION * GI_SKIP_MOTION)) {
            uint phase = pixelSeed(pix, 0);
            if (((phase + uint(frameCounter)) % uint(GI_SKIP_PERIOD)) != 0u) {
                // Write the history straight back, and do NOT advance the length:
                // no sample was added, so the pixel is exactly as converged as it
                // was. colortex15 still has to carry THIS frame's key.
                gl_FragData[0] = vec4(history, histKeep);
                gl_FragData[1] = vec4(octEncodeNormal(worldNormal), linDepth, 0.0);
                return;
            }
        }
    }
    #endif

    // --- gather -------------------------------------------------------------
    float eyeAlt = ptEyeAltitude();
    uint  seed   = pixelSeed(pix, frameCounter);

    // Lift the origin off the surface so the first voxel stepped is the air in
    // front of it, not the block the pixel belongs to.
    vec3 origin = worldPos + worldNormal * 0.05;

    // Adaptive ray budget. A pixel with a long history is already averaging many
    // frames of samples and gains very little from more this frame; a fresh or
    // just-disoccluded pixel has nothing and needs the full budget. Lumen varies
    // its screen-probe budget on the same principle.
    //
    // The point of this is to make a HIGHER GI_GATHER_RAYS affordable: the full
    // count is then paid only at disocclusions and on moving geometry, which is
    // a small and shrinking fraction of the screen, instead of on every pixel
    // every frame. At GI_GATHER_RAYS 1 the whole thing compiles out and the
    // loop bound stays constant.
    int rays = GI_GATHER_RAYS;
    #if GI_GATHER_RAYS > 1
        float conv = clamp(histLen / float(GI_ADAPTIVE_FRAMES), 0.0, 1.0);
        rays = max(int(mix(float(GI_GATHER_RAYS), 1.0, conv) + 0.5), 1);
    #endif

    vec3  incoming = vec3(0.0);
    float occlusion = 0.0;   // short-range AO, accumulated from these same rays

    for (int r = 0; r < rays; ++r) {
        #ifdef GI_BLUE_NOISE
            vec3 dir = stbnCosineHemisphere(worldNormal, pix, frameCounter * GI_GATHER_RAYS + r);
        #else
            vec3 dir = cosHemisphereDir(worldNormal, randFloat(seed), randFloat(seed));
        #endif

        VoxelHit h = traceVoxelCascaded(origin, dir, float(GI_GATHER_DIST), true);

        if (h.hit) {
            incoming += scLookup(h.pos, h.normal) + h.emission;

            // Short-range ambient occlusion, from the ray we already cast.
            //
            // WHY THIS IS NEEDED. Ray occlusion alone barely darkens anything in
            // daylight: a ray that hits a nearby block resolves it through the
            // surface cache, and that cache holds direct + albedo*indirect -- so
            // a SUNLIT occluder returns a value comparable to the sky it just
            // replaced. Geometry blocks the ray without meaningfully lowering
            // what the ray returns, so creases, corners and block seams come back
            // nearly as bright as open ground and the result reads as flat.
            //
            // Lumen has exactly this problem and solves it the same way, with a
            // separate Short-Range AO term applied on top of the probe gather --
            // traced GI at probe density cannot resolve contact-scale occlusion,
            // so it is reintroduced explicitly. This pack lost its equivalent
            // when GTAO was deleted in Phase 1 and nothing replaced it.
            //
            // Free here: no extra rays, just the hit distance we already have.
            #ifdef GI_CONTACT_AO
                float hitDist = distance(h.pos, origin);
                occlusion += 1.0 - smoothstep(0.0, float(GI_AO_RADIUS), hitDist);
            #endif
        } else {
            // A ray that genuinely left the cascades can see the sky and nothing
            // can occlude it. One that merely ran out of budget is still inside
            // the grid, so it gets the sky only in proportion to how much sky
            // this surface actually has access to.
            //
            // sampleSky_fast, never sampleSky: the latter carries the sun and
            // moon discs (x1000 and x100) and one ray clipping a disc is a
            // guaranteed firefly.
            float skyWeight = h.escaped ? 1.0 : skyVis;
            #ifdef GI_SKY_SH
                vec3 skyRad = skySHRadiance(dir);
            #else
                vec3 skyRad = sampleSky_fast(dir, eyeAlt);
            #endif
            incoming += skyRad * float(GI_SKY_BRIGHTNESS) * skyWeight + h.emission;
        }
    }

    // Cosine-weighted sampling means the plain mean already IS the
    // cosine-weighted mean incident radiance = irradiance / PI, which is exactly
    // the unit d7_composite wants (it does albedo * indirect, not
    // albedo/PI * indirect). No 1/pdf, no NdotL, no extra 1/PI.
    // Divide by the rays actually cast, not the configured maximum.
    vec3 gi = incoming / float(rays);

    // Apply the short-range AO. The rays are cosine-distributed, so the mean of
    // the per-ray weights above is already a properly cosine-weighted occluded
    // fraction rather than something that needs re-normalising.
    //
    // It goes on BEFORE the temporal accumulation deliberately: a one- or
    // two-ray occlusion estimate is far too noisy to use raw, and folding it in
    // here means the existing history does the denoising instead of needing a
    // filter of its own.
    #ifdef GI_CONTACT_AO
        float ao = 1.0 - (occlusion / float(rays)) * float(GI_AO_STRENGTH);
        gi *= max(ao, 0.0);
    #endif

    // GI_STRENGTH is the producer's responsibility; LIGHTING_INDIRECT is d7's.
    gi *= float(GI_STRENGTH) / 100.0;

    float lum = dot(gi, vec3(0.2126, 0.7152, 0.0722));
    if (GI_FIREFLY_MAX < 1000.0 && lum > GI_FIREFLY_MAX) gi *= GI_FIREFLY_MAX / lum;

    // --- temporal accumulation ---------------------------------------------
    // histLen / history came from the reprojection above, which had to run
    // before the gather so the ray budget could depend on it.
    float alpha = 1.0 / max(histLen + 1.0, 1.0);
    vec3  accum = mix(history, gi, alpha);

    // --- disocclusion fill --------------------------------------------------
    // Pixels that never build history -- silhouette edges, convex corners, fresh
    // disocclusions -- would otherwise show the raw few-ray estimate. Pool the
    // settled GI of geometrically similar neighbours from the previous frame's
    // buffers instead. Converged pixels pass through untouched.
    ivec2 pixMax = ivec2(vec2(viewWidth, viewHeight) * renderScale) - 1;
    float fixAmt;
    accum = historyFixGI(colortex8, colortex15, pix, pixMax,
                         accum, histLen, worldNormal, linDepth, fixAmt);

    gl_FragData[0] = vec4(accum, histLen);
    gl_FragData[1] = vec4(octEncodeNormal(worldNormal), linDepth, 0.0);
}

#endif
