// ============================================================================
//  d0_accum : spatiotemporal accumulation for indirect light
// ----------------------------------------------------------------------------
//  Reads the noisy raw GI from d0_restir (colortex3) and blends it with the
//  history (colortex8) using bilateral reprojection and YCoCg neighborhood
//  clamping to suppress ghosting.
//
//  Output: colortex8 = accumulated GI (.rgb) + history length (.a)
//          colortex9 = linear depth (.r) + luminance moments (.g, .b)
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
#include "/lib/pt/denoise.glsl"

in vec2 texCoord;

uniform sampler2D colortex1;   // normals
uniform sampler2D colortex2;   // lightmap
uniform sampler2D colortex3;   // raw noisy GI (from d0_restir)
uniform sampler2D colortex6;   // raw moments (from d0_restir)
uniform sampler2D colortex8;   // GI history
uniform sampler2D colortex9;   // moments history
uniform sampler2D colortex15;  // normal history
uniform sampler2D depthtex0;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

vec3 clipSpace;
#include "/lib/util/positions.glsl"

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    vec2 uvUnjittered = texCoord - currentJitter;
    float depth0 = texture(depthtex0, uvUnjittered).r;
    
    if (depth0 >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        gl_FragData[1] = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }

    clipSpace = vec3(uvUnjittered, depth0) * 2.0 - 1.0;

    vec3  normal = normalize(texture(colortex1, uvUnjittered).rgb * 2.0 - 1.0);
    vec3  normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3  worldRel = getWorldPosition().xyz;
    
    vec3  rawGI = texture(colortex3, texCoord).rgb;
    vec4  p6    = texture(colortex6, texCoord);
    float lr    = p6.g;

    // Reproject
    vec3 worldPrevRel = worldRel;
    if (depth0 >= 0.7) {
        worldPrevRel += (cameraPosition - previousCameraPosition);
    }
    
    vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
    vec4 clipPrev = gbufferPreviousProjection * viewPrev;
    vec2 uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
    uvPrev += prevJitter;
    float expectedClipZ = clipPrev.z / clipPrev.w;

    vec3  blendedGI = rawGI;
    float giHist    = 1.0;
    float giM1      = lr;
    float giM2      = lr * lr;

    bool validReproj = all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)));

    if (validReproj) {
        vec4 prev8, p9_tmp;
        if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, prev8, p9_tmp)) {
            if (prev8.a > 0.5) {
                giHist = min(prev8.a + 1.0, float(GI_ACCUM_FRAMES));

                // 1. Box Clamping (YCoCg) - Modern anti-ghosting
                vec3 clampedHistory = clipHistory(prev8.rgb, rawGI, colortex3, texCoord);

                // 2. Variance-based rejection (Soft)
                float prevStd = sqrt(max(p9_tmp.b - p9_tmp.g * p9_tmp.g, 0.0));
                float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9_tmp.g + 0.01;
                float reject  = clamp((abs(lr - p9_tmp.g) - tol) / (tol + 1e-3), 0.0, 1.0);
                
                float motion = length(cameraPosition - previousCameraPosition);
                reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);
                reject *= reject;

                giHist = mix(giHist, 1.0, reject);
                float a = 1.0 / giHist;

                blendedGI = mix(clampedHistory, rawGI, a);
                giM1 = mix(p9_tmp.g, lr,      a);
                giM2 = mix(p9_tmp.b, lr * lr, a);
            }
        }
    }

    /* RENDERTARGETS: 8,9 */
    gl_FragData[0] = vec4(blendedGI, giHist);
    gl_FragData[1] = vec4(depth0, giM1, giM2, 1.0);
}

#endif
