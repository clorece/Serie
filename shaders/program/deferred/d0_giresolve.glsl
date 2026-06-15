// d0_giresolve : per-pixel resolve of the world-space irradiance cache
// Replaces the entire old ReSTIR + SVGF stack (d0_restir, d0_accum, d0b_historyfix,
// d1..d4 denoise). Indirect light is now built in the shadowcomp compute passes
// (irc_shift + irc_update) directly in the cache; this pass just SAMPLES it per
// pixel — a cheap trilinear, normal-offset, occlusion-guarded lookup — and writes
// the resolved GI to colortex8 for d7_composite. No tracing, no screen-space
// history, so there is nothing to crawl or flush on disocclusion.
//   colortex8 = resolved GI (.rgb), .a = 1
//   colortex9 = GTAO (.a) + depth key (.r)   [only when AO_GTAO]

#ifdef VERTEX

#include "/lib/options.glsl"

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

#include "/lib/options.glsl"
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

#ifdef AO_GTAO
#include "/lib/pt/gtao.glsl"
#endif

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));

    float depth0 = texture(depthtex0, sampleCenter).r;

    vec4 giOut = vec4(0.0);
    vec4 aoOut = vec4(1.0, 0.0, 0.0, 1.0);

    if (depth0 < 1.0) {
        vec3 normal      = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);

        clipSpace = vec3(texCoord, depth0) * 2.0 - 1.0;
        float linDepth = getDepth(depth0);

        vec3 worldAbs = getWorldPosition().xyz + cameraPosition;

        // sky-tint ambient used as the fallback before a cell has data
        vec3 giSky = ambientColor * GI_SKY_BRIGHTNESS;
        giSky *= mix(vec3(1.0), vec3(1.25, 1.04, 0.72), GI_SKY_WARMTH);

        // spatially-filtered cache read (.rgb = smoothed irradiance, .a = center
        // cell weight used only to gate the giSky fallback for never-filled cells)
        vec4  tap      = ircTapSmooth(irradianceSampler, voxelSampler, worldAbs, normalWorld, cameraPosition);
        vec3  cacheVal = tap.rgb;
        float valid    = smoothstep(0.0, 0.5, tap.a);

        vec3 gi = mix(giSky, cacheVal, valid) * (float(GI_STRENGTH) / 100.0);

        // subtle tint toward the current sun/sky color (parity with the old resolve)
        vec3 normLightCol = lightColor / max(dot(lightColor, vec3(0.2126, 0.7152, 0.0722)), 0.1);
        gi = mix(gi, gi * normLightCol, 0.10);

        if (any(isnan(gi)) || any(isinf(gi))) gi = vec3(0.0);
        gi = max(gi, vec3(0.0));
        giOut = vec4(gi, 1.0);

        #ifdef AO_GTAO
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
            aoOut = vec4(depth0, 0.0, 0.0, blendedAO);
        #endif
    }

    #ifdef AO_GTAO
    /* RENDERTARGETS: 8,9 */
    gl_FragData[0] = giOut;
    gl_FragData[1] = aoOut;
    #else
    /* RENDERTARGETS: 8 */
    gl_FragData[0] = giOut;
    #endif
}

#endif
