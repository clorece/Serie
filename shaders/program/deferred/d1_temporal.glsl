
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
        vec4 traceData = texture(colortex10, sampleCenter);
        vec3 currentRad = traceData.rgb;
        float currentHitDist = traceData.a;
        
        vec3 normal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        clipSpace = vec3(texCoord, depth0) * 2.0 - 1.0;
        
        vec3 worldAbs = getWorldPosition().xyz + cameraPosition;
        vec3 worldPrevRel = worldAbs - previousCameraPosition;
        
        vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
        vec4 clipPrev = gbufferPreviousProjection * viewPrev;
        vec2 uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;

        float expectedClipZ = clipPrev.z / clipPrev.w;
        
        vec4 history = vec4(0.0);
        bool historyValid = false;

        if (all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)))) {
            // Read previous frame history
            history = texture(colortex11, uvPrev * renderScale);
            float prevDepth = texture(depthtex2, uvPrev * renderScale).r;
            float actualClipZ = prevDepth * 2.0 - 1.0;
            
            // Rejection test
            if (abs(expectedClipZ - actualClipZ) < 0.003) {
                historyValid = true;
            }
        }

        if (any(isnan(history)) || any(isinf(history))) {
            historyValid = false;
            history = vec4(0.0);
        }

        if (historyValid) {
            float accumFrames = min(history.a + 1.0, TEMPORAL_MAX_FRAMES);
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
