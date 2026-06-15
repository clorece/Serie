
// d0_trace: Per-pixel Ray Dispatch (Phase 1 of SVGF)
// Replaces the IRC resolve with actual path tracing.
// Traces 1 ray per pixel using the voxel grid and samples the IRC only as a multi-bounce fallback.

#include "/lib/options.glsl"

#ifdef VERTEX
out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
}
#endif

#ifdef FRAGMENT
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/pt/voxelData.glsl"
#include "/lib/pt/irc.glsl"
#include "/lib/pt/rand.glsl"

#ifdef AO_GTAO
#include "/lib/pt/gtao.glsl"
#endif

#define GI_SAMPLES 1
#include "/lib/pt/gi.glsl"

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));

    float depth0 = texture(depthtex0, sampleCenter).r;
    vec4 traceOut = vec4(0.0);
    vec4 aoOut = vec4(1.0, 0.0, 0.0, 1.0);

    if (depth0 < 1.0) {
        vec3 normal      = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        
        if (length(normal) > 0.001) { // Guard against empty sky normal
            vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);

            clipSpace = vec3(texCoord, depth0) * 2.0 - 1.0;
            vec3 worldAbs = getWorldPosition().xyz + cameraPosition;
            vec3 gridOrigin = floor(cameraPosition) - VOXEL_RADIUS_VEC;

            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);
            
            vec3 skyTint = ambientColor * GI_SKY_BRIGHTNESS;
            skyTint *= mix(vec3(1.0), vec3(1.25, 1.04, 0.72), GI_SKY_WARMTH);

            // Generate ray
            vec3 dir = cosHemisphereDir(normalWorld, randFloat(seed), randFloat(seed));
            vec3 origin = worldAbs + normalWorld * 0.1;

            vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCat; vec3 rayEmission;
            float dither = randFloat(seed);
            
            // Use lightmap coordinate for sky occlusion (from colortex2)
            vec4 lightmapData = texture(colortex2, sampleCenter);
            float skyLightmap = lightmapData.y; // Assuming y is skylight

            vec3 rad = giRayRadiance(
                voxelSampler, cameraPosition, gridOrigin, origin, dir, lightVector, lightColor, skyTint,
                depthtex0, colortex5, colortex1, gbufferProjection, gbufferModelView,
                hitPos, hitNormal, wasHit, hitCat, rayEmission, skyLightmap, dither
            );
            
            rad += rayEmission;

            // Multi-bounce fallback: Sample IRC at the hit point
            if (wasHit) {
                vec4 tap = ircTapSmooth(irradianceSampler, voxelSampler, hitPos, hitNormal, cameraPosition);
                rad += tap.rgb * (tap.a > 0.0 ? 1.0 : 0.0) * 0.5; // Arbitrary attenuation for multi-bounce
            }

            // Apply strength
            rad *= (float(GI_STRENGTH) / 100.0);
            
            // Color tinting to match SerieVX style
            vec3 normLightCol = lightColor / max(dot(lightColor, vec3(0.2126, 0.7152, 0.0722)), 0.1);
            rad = mix(rad, rad * normLightCol, 0.10);

            if (any(isnan(rad)) || any(isinf(rad))) rad = vec3(0.0);
            rad = max(rad, vec3(0.0));
            
            float hitDist = wasHit ? distance(origin, hitPos) : -1.0;
            if (isnan(hitDist) || isinf(hitDist)) hitDist = -1.0;
            
            traceOut = vec4(rad, hitDist);

            #ifdef AO_GTAO
                float linDepth = getDepth(depth0);
                float rawAO = computeGTAO(texCoord, linDepth, normalWorld, frameCounter);

                // light temporal accumulation of the (noisy) AO in screen space
                float blendedAO = rawAO;
                vec3  worldPrevRel = getWorldPosition().xyz + (cameraPosition - previousCameraPosition);
                vec4  viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
                vec4  clipPrev = gbufferPreviousProjection * viewPrev;
                vec2  uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
                if (all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)))) {
                    vec4 p9 = texture(colortex9, uvPrev * renderScale);
                    float expectedClipZ = clipPrev.z / clipPrev.w;
                    float actualClipZ   = p9.r * 2.0 - 1.0;
                    if (abs(expectedClipZ - actualClipZ) < 0.003 && p9.a > 0.0) {
                        blendedAO = mix(p9.a, rawAO, 1.0 / 16.0);
                    }
                }
                if (isnan(blendedAO) || isinf(blendedAO)) blendedAO = 1.0;
                aoOut = vec4(depth0, 0.0, 0.0, blendedAO);
            #endif
        }
    }

    #ifdef AO_GTAO
    /* RENDERTARGETS: 10,9 */
    gl_FragData[0] = traceOut;
    gl_FragData[1] = aoOut;
    #else
    /* RENDERTARGETS: 10 */
    gl_FragData[0] = traceOut;
    #endif
}
#endif
