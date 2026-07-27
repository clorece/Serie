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

    // --- gather -------------------------------------------------------------
    ivec2 pix    = ivec2(gl_FragCoord.xy);
    float eyeAlt = ptEyeAltitude();
    uint  seed   = pixelSeed(pix, frameCounter);

    // Lift the origin off the surface so the first voxel stepped is the air in
    // front of it, not the block the pixel belongs to.
    vec3 origin = worldPos + worldNormal * 0.05;

    vec3 incoming = vec3(0.0);
    for (int r = 0; r < GI_GATHER_RAYS; ++r) {
        #ifdef GI_BLUE_NOISE
            vec3 dir = stbnCosineHemisphere(worldNormal, pix, frameCounter * GI_GATHER_RAYS + r);
        #else
            vec3 dir = cosHemisphereDir(worldNormal, randFloat(seed), randFloat(seed));
        #endif

        VoxelHit h = traceVoxelCascaded(origin, dir, float(GI_GATHER_DIST), true);

        if (h.hit) {
            incoming += scLookup(h.pos, h.normal) + h.emission;
        } else {
            // sampleSky_fast, never sampleSky: the latter carries the sun and
            // moon discs (x1000 and x100) and one ray clipping a disc is a
            // guaranteed firefly.
            incoming += sampleSky_fast(dir, eyeAlt) * float(GI_SKY_BRIGHTNESS) + h.emission;
        }
    }

    // Cosine-weighted sampling means the plain mean already IS the
    // cosine-weighted mean incident radiance = irradiance / PI, which is exactly
    // the unit d7_composite wants (it does albedo * indirect, not
    // albedo/PI * indirect). No 1/pdf, no NdotL, no extra 1/PI.
    vec3 gi = incoming / float(GI_GATHER_RAYS);

    // GI_STRENGTH is the producer's responsibility; LIGHTING_INDIRECT is d7's.
    gi *= float(GI_STRENGTH) / 100.0;

    float lum = dot(gi, vec3(0.2126, 0.7152, 0.0722));
    if (GI_FIREFLY_MAX < 1000.0 && lum > GI_FIREFLY_MAX) gi *= GI_FIREFLY_MAX / lum;

    // --- temporal accumulation ---------------------------------------------
    // Reproject through the previous frame's camera. Both matrices are
    // un-jittered, and the GI buffer is indexed by logical uv, so no jitter
    // enters this path at all.
    vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
    vec4 prevClip   = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 prevUV     = (prevClip.xy / prevClip.w) * 0.5 + 0.5;

    float histLen = 0.0;
    vec3  history = gi;

    if (prevClip.w > 0.0 && all(greaterThanEqual(prevUV, vec2(0.0))) && all(lessThan(prevUV, vec2(1.0)))) {
        vec4 h8  = texture(colortex8,  prevUV * renderScale);
        vec4 h15 = texture(colortex15, prevUV * renderScale);

        vec3  prevNormal = octDecodeNormal(h15.xy);
        float prevDepth  = h15.z;

        // Disocclusion gates: same plane, same surface orientation.
        bool depthOk  = abs(prevDepth - linDepth) < max(linDepth, 1.0) * GI_REJECT_DEPTH;
        bool normalOk = dot(prevNormal, worldNormal) > GI_REJECT_NORMAL;

        if (depthOk && normalOk) {
            histLen = min(h8.a + 1.0, float(GI_ACCUM_FRAMES));
            history = h8.rgb;
        }
    }

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
