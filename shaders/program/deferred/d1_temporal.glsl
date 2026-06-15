
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

#define TEMPORAL_MAX_FRAMES 32.0

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
        
        // Aggressive Planar Firefly Clamp
        vec3 m1 = vec3(0.0);
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
                    vec3 sRad = texture(colortex10, texCoord * renderScale + offset).rgb;
                    m1 += sRad;
                    validNeighbors += 1.0;
                }
            }
        }
        
        if (validNeighbors > 0.0) {
            m1 /= validNeighbors;
            currentRad = min(currentRad, m1 * 1.5); // Brutal 1.5x average clamp
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
                float depthWeight = step(abs(depthGradient), max(-tapViewPrev.z * 4e-3, 0.0) + 0.2); // Tighter motion rejection
                
                float normalWeight = pow(max(dot(normal, viewNormalPrev), 0.0), 128.0); // Extreme edge rejection
                
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

        if (any(isnan(history)) || any(isinf(history))) {
            maxWeight = 0.0;
            history = vec4(0.0);
        }

        if (maxWeight > 0.01) {
            
            float accumFrames = min(history.a * maxWeight + 1.0, TEMPORAL_MAX_FRAMES);
            float blendWeight = 1.0 / accumFrames;
            
            temporalOut.rgb = mix(history.rgb, currentRad, blendWeight);
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
