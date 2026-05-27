// ============================================================================
//  d5_gtao : screen-space ground-truth ambient occlusion
// ----------------------------------------------------------------------------
//  Runs after the GI denoise chain (d1..d4) and before final lighting (d7).
//  Computes a short-radius GTAO term + bent normal from depthtex0 + view
//  normals (colortex1), temporally accumulates it (reprojection + disocclusion
//  reject) and writes colortex12:
//      .xy = octahedral world-space bent normal
//      .z  = linear depth (for next-frame disocclusion)
//      .w  = AO  (1 = fully lit)
//  d7_composite multiplies this contact AO onto the indirect term.
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/util/dither.glsl"

in vec2 texCoord;

uniform sampler2D depthtex0;
uniform sampler2D colortex1;    // view normals
uniform sampler2D colortex12;   // previous-frame AO history
uniform sampler2D colortex14;   // history length storage (.z = AO hist)

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

#include "/lib/pt/gtao.glsl"

void main() {
    vec2 currentJitter = getTaaJitter() * texelSize;
    vec2 uvUnjittered  = texCoord - currentJitter;
    float depth0       = texture(depthtex0, uvUnjittered).r;

    // Sky / hand: no occlusion, store an upward bent normal so reads stay sane.
    if (depth0 >= 1.0) {
        gl_FragData[0] = vec4(octEncodeNormal(vec3(0.0, 1.0, 0.0)), 1e5, 1.0);
        return;
    }

    vec3 viewNormal = normalize(texture(colortex1, uvUnjittered).rgb * 2.0 - 1.0);
    vec3 viewPos    = gtaoViewPosFromDepth(uvUnjittered, depth0);

    // Spatial dither: IGN gives a good per-pixel pattern. 
    // Freezing the frame parameter prevents the GTAO from jittering, which removes the need 
    // for aggressive temporal reprojection that causes ghosting.
    vec2 aoDither = vec2(
        fract(interleavedGradientNoise(gl_FragCoord.xy,                 0)),
        fract(interleavedGradientNoise(gl_FragCoord.xy + vec2(97.0, 31.0), 0))
    );

    vec3 bentView;
    float aoRaw = computeGtao(depthtex0, viewPos, viewNormal, texCoord - currentJitter, aoDither, bentView);
    vec3 bentWorld = normalize(mat3(gbufferModelViewInverse) * bentView);

    float linDepth = getDepth(depth0);

    // ---- Temporal reprojection (camera-relative world space, mirrors d0_restir) ----
    // Per-pixel AO history length used to live in colortex14.z, but colortex14 is now
    // the irradiance cache atlas. AO uses a fixed exponential blend instead (loses some
    // disocclusion-snap responsiveness; the depth gate below still rejects on big jumps,
    // and the aoDelta-based reject still cuts ghosting on moving contact shadows).
    float aoOut   = aoRaw;
    vec3  bentOut = bentWorld;

    vec3 worldRel     = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPrevRel = worldRel;
    if (depth0 >= 0.7) {
        // Environment: account for camera movement.
        worldPrevRel += (cameraPosition - previousCameraPosition);
    } else {
        // View-model (hand): pinned to the camera, so don't subtract global motion.
    }

    vec4 clipPrev     = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(worldPrevRel, 1.0));
    vec2 uvPrev       = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
    uvPrev += getTaaJitter(frameCounter - 1) * texelSize;

    if (all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)))) {
        vec4 hist = texture(colortex12, uvPrev);
        float prevDepth = hist.z;
        // Disocclusion: reject history when the surface depth jumped.
        float depthTol = 0.05 * linDepth + 0.10;
        if (abs(prevDepth - linDepth) < depthTol) {
            // Fixed exponential blend (effective history ~AO_ACCUM_FRAMES frames).
            float alpha = 1.0 / float(AO_ACCUM_FRAMES);

            // Loosen blending when AO changes a lot (moving contact shadows) to cut ghosting.
            float aoDelta = abs(aoRaw - hist.w);
            float reject  = clamp(aoDelta * 4.0 - 0.5, 0.0, 1.0);
            alpha = mix(alpha, 1.0, reject * reject);

            aoOut   = mix(hist.w, aoRaw, alpha);
            bentOut = normalize(mix(octDecodeNormal(hist.xy), bentWorld, alpha));
        }
    }

    /* RENDERTARGETS: 12 */
    gl_FragData[0] = vec4(octEncodeNormal(bentOut), linDepth, clamp(aoOut, 0.0, 1.0));
}

#endif
