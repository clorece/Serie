
// d1_temporal: Temporal Accumulation (Phase 2 of SVGF)
// Reprojects the previous frame's colortex11 and blends with current colortex10.

#include "/lib/options.glsl"

#ifdef VERTEX
out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}
#endif

#ifdef FRAGMENT
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

in vec2 texCoord;
vec3 clipSpace;
#include "/lib/util/positions.glsl"

#define TEMPORAL_MAX_FRAMES float(GID_TEMPORAL_MAX_FRAMES)

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));

    float depth0 = texture(depthtex0, sampleCenter).r;
    vec4 temporalOut = vec4(0.0);

    if (depth0 < 1.0) {
        vec4 traceData = texture(colortex10, texCoord * renderScale);
        vec3 currentRad = traceData.rgb;
        
        vec3 normal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        clipSpace = vec3(texCoord + currentJitter, depth0) * 2.0 - 1.0;
        
        // Energy-preserving planar firefly clamp.
        // Gather the luminance mean/stddev of geometrically-similar neighbours,
        // then rescale (not min-clip) this pixel's radiance only if it spikes
        // above mean + K*stddev. Working in LUMA preserves chroma; rescaling
        // instead of a flat min keeps sparse-light energy that the old
        // "min(rad, 1.5*avg)" used to crush.
        float lm1 = 0.0, lm2 = 0.0;
        float validNeighbors = 0.0;

        vec2 clipXY = sampleCenter / renderScale * 2.0 - 1.0;
        vec4 fragPos = gbufferProjectionInverse * vec4(clipXY, depth0 * 2.0 - 1.0, 1.0);
        vec3 viewPos = fragPos.xyz / fragPos.w;

        for(int y = -1; y <= 1; y++) {
            for(int x = -1; x <= 1; x++) {
                if (x == 0 && y == 0) continue;
                vec2 offset = vec2(x, y) * texelSize * renderScale;

                float sDepth = texture(depthtex0, sampleCenter + offset).r;
                vec3 sNormal = normalize(texture(colortex1, sampleCenter + offset).rgb * 2.0 - 1.0);

                vec2 sClipXY = (sampleCenter + offset) / renderScale * 2.0 - 1.0;
                vec4 sFragPos = gbufferProjectionInverse * vec4(sClipXY, sDepth * 2.0 - 1.0, 1.0);
                vec3 sViewPos = sFragPos.xyz / sFragPos.w;

                vec3 posDiff = sViewPos - viewPos;
                float depthGradient = dot(posDiff, normal);

                if (abs(depthGradient) < 0.3 && dot(normal, sNormal) > 0.5) {
                    float sL = luma(texture(colortex10, texCoord * renderScale + offset).rgb);
                    lm1 += sL;
                    lm2 += sL * sL;
                    validNeighbors += 1.0;
                }
            }
        }

        if (GID_CLAMP_K < 1000.0 && validNeighbors > 0.0) {
            lm1 /= validNeighbors;
            lm2 /= validNeighbors;
            float sigma = sqrt(max(lm2 - lm1 * lm1, 0.0));
            // Relative headroom: in dark/low-variance regions sigma -> 0, which would
            // crush every sample above the dark mean each frame (sparse light never
            // settles -> dark boiling). Floor the allowed deviation at a fraction of
            // the local mean so genuine faint light survives and only true fireflies
            // (>> local brightness) get rescaled.
            float maxLuma = lm1 + GID_CLAMP_K * max(sigma, lm1 * 0.5);
            float curLuma = luma(currentRad);
            if (curLuma > maxLuma && curLuma > 1e-4) {
                currentRad *= maxLuma / curLuma; // rescale, keep chroma + as much energy as the clamp allows
            }
        }

        vec3 worldAbs = getWorldPosition().xyz + cameraPosition;
        vec3 worldPrevRel = worldAbs - previousCameraPosition;
        
        vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
        vec4 clipPrev = gbufferPreviousProjection * viewPrev;
        vec2 uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
        
        vec4 history = vec4(0.0);
        float weights = 0.0;
        float maxWeight = 0.0;

        vec3 worldNormal = mat3(gbufferModelViewInverse) * normal;
        vec3 viewNormalPrev = mat3(gbufferPreviousModelView) * worldNormal;

        if (all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)))) {
            vec2 prevTexCoord = uvPrev * renderScale * vec2(viewWidth, viewHeight) - 0.5;
            vec2 prevTexel = floor(prevTexCoord);
            vec2 fracPos = fract(prevTexCoord);

            for (int i = 0; i < 4; i++) {
                vec2 offset = vec2(i & 1, i >> 1);
                vec2 sampleCoord = (prevTexel + offset + 0.5) / vec2(viewWidth, viewHeight);
                
                float bilWeight = (1.0 - abs(offset.x - fracPos.x)) * (1.0 - abs(offset.y - fracPos.y));

                vec4 tapHistory = texture(colortex11, sampleCoord);
                float tapDepth = texture(depthtex2, sampleCoord).r;
                
                vec4 tapClipPrev = vec4(sampleCoord / renderScale * 2.0 - 1.0, tapDepth * 2.0 - 1.0, 1.0);
                vec4 tapViewPrev = gbufferProjectionInverse * tapClipPrev;
                tapViewPrev.xyz /= tapViewPrev.w;
                
                vec3 posDiff = viewPrev.xyz - tapViewPrev.xyz;
                float depthGradient = dot(posDiff, viewNormalPrev);
                // Motion/disocclusion rejection. depthGradient is the tap's distance
                // from this surface's plane (along the normal). Two competing needs:
                //   - keep SAME-surface history through camera motion (loose band,
                //     scaled by GID_MOTION_TOLERANCE) -> low motion noise;
                //   - never accept a DIFFERENT surface behind a silhouette (a bg wall
                //     a few blocks back) -> else its lighting leaks into the edge and
                //     flickers. So the band is hard-capped to a small fraction of view
                //     distance, independent of GID_MOTION_TOLERANCE.
                float depthTol = (max(-tapViewPrev.z * 1.5e-2, 0.0) + 0.35) * GID_MOTION_TOLERANCE;
                depthTol = min(depthTol, -tapViewPrev.z * 0.06 + 0.35); // bg-leak cap
                float depthWeight = step(abs(depthGradient), depthTol);
                
                // History-adaptive normal rejection: a freshly-seeded tap (low
                // tapHistory.a) is accepted loosely so disoccluded/edge pixels can
                // bootstrap a history, while a long-converged tap is rejected sharply
                // to keep edges crisp. This replaces the old fixed pow-128 that
                // rejected history at every curved edge -> permanent 1-spp fireflies.
                float tapConv = clamp(tapHistory.a / TEMPORAL_MAX_FRAMES, 0.0, 1.0);
                float normalExp = mix(GID_NORMAL_EXP_MIN, GID_NORMAL_EXP_MAX, tapConv);
                float normalWeight = pow(max(dot(normal, viewNormalPrev), 0.0), normalExp);
                
                float skyWeight = tapDepth < 1.0 ? 1.0 : 0.0;
                float geomWeight = depthWeight * skyWeight * normalWeight;
                
                maxWeight = max(maxWeight, geomWeight);
                
                float tapWeight = bilWeight * geomWeight;
                history += tapHistory * tapWeight;
                weights += tapWeight;
            }
            
            if (weights > 1e-5) {
                history /= weights;
            } else {
                maxWeight = 0.0;
            }
        }

        // Reject uninitialized / garbage history. Mesa/radeonsi (unlike the Windows
        // AMD driver) does NOT zero a clear=false image at (re)allocation, and
        // frameCounter never resets on a shader reload, so the frame-0 zero-guard
        // doesn't fire. A garbage accumulation age (.a) reads large -> blendWeight
        // collapses -> the temporal resolve LOCKS onto VRAM garbage, giving random
        // flat-vs-correct GI on every reload. Anything outside the real age range
        // [0, maxFrames] or with negative radiance was never validly written.
        if (any(isnan(history)) || any(isinf(history))
            || history.a < 0.0 || history.a > 300.0
            || any(lessThan(history.rgb, vec3(0.0)))) {
            maxWeight = 0.0;
            history = vec4(0.0);
        }

        if (maxWeight > 0.01) {
            
            // Frametime-adaptive accumulation cap. The cap is
            // a frame COUNT, but what we actually want is a fixed real-TIME integration
            // window. At high FPS each frame is a smaller time-slice, so allow more frames
            // (up to 3x) to reach the same wall-clock smoothing; at low FPS stay at the
            // baseline so GI doesn't over-ghost. Net: cleaner GI when fast, no extra lag
            // when slow — and the response rate to lighting changes is FPS-independent.
            float maxFrames = min(TEMPORAL_MAX_FRAMES * clamp(0.01666667 / max(frameTime, 1e-4), 1.0, 3.0), 256.0);
            float accumFrames = min(history.a * maxWeight + 1.0, maxFrames);
            float blendWeight = 1.0 / accumFrames;
            
            // Tonemapped (Karis) temporal resolve. A plain mix() lets a transient
            // 1-spp firefly (luma >> history) spike the accumulator, then it lingers
            // for the whole window. Weighting each term by 1/(1+luma) makes a bright
            // outlier contribute far less than its raw value, so it averages away
            // instead of blooming — WITHOUT a hard luminance clamp that also crushes
            // genuinely bright, stable GI (the GID_FIREFLY_MAX=0.1 "flat" problem).
            // Stable signal keeps balanced weights -> converged mean + full dynamic
            // range preserved; this is the firefly handling done in tonemapped/SDR
            // space rather than as a source clamp.
            float wC = blendWeight         / (1.0 + luma(currentRad));
            float wH = (1.0 - blendWeight) / (1.0 + luma(history.rgb));
            temporalOut.rgb = (currentRad * wC + history.rgb * wH) / max(wC + wH, 1e-6);
            temporalOut.a = accumFrames;
        } else {
            temporalOut.rgb = currentRad;
            temporalOut.a = 1.0;
        }

        if (any(isnan(temporalOut)) || any(isinf(temporalOut))) {
            temporalOut = vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    /* RENDERTARGETS: 11 */
    gl_FragData[0] = temporalOut;
}
#endif
