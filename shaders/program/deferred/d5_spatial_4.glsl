
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

#define STEP_SIZE 8.0
#define INPUT_TEX colortex6

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));

    float depth0 = texture(depthtex0, sampleCenter).r;
    vec4 spatialOut = vec4(0.0);

    if (depth0 < 1.0) {
        vec3 centerNormal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        clipSpace = vec3(texCoord, depth0) * 2.0 - 1.0;
        float centerDepth = getDepth(depth0);
        
        vec4 centerData = texture(INPUT_TEX, sampleCenter);
        vec3 sumCol = centerData.rgb;
        float sumW = 1.0;
        
        float centerLuma = luma(centerData.rgb);

        const float kernel[3] = float[3](1.0, 2.0/3.0, 1.0/6.0);

        if (length(centerNormal) > 0.001) {
            for (int y = -2; y <= 2; y++) {
                for (int x = -2; x <= 2; x++) {
                    if (x == 0 && y == 0) continue;
                    
                    vec2 offset = vec2(x, y) * STEP_SIZE * texelSize;
                    vec2 sampleCoord = sampleCenter + offset;
                    
                    if (any(lessThan(sampleCoord, vec2(0.0))) || any(greaterThanEqual(sampleCoord, vec2(1.0)))) continue;
                    
                    float sampleDepth0 = texture(depthtex0, sampleCoord).r;
                    vec3 sampleNormal = normalize(texture(colortex1, sampleCoord).rgb * 2.0 - 1.0);
                    
                    float wNormal = pow(max(dot(centerNormal, sampleNormal), 0.0), 32.0);
                    
                    // Depth weight
                    float dDepth = abs(centerDepth - getDepth(sampleDepth0));
                    float wDepth = exp(-dDepth * 1000.0); // Simple depth rejection
                    
                    vec4 sampleData = texture(INPUT_TEX, sampleCoord);
                    float sampleLuma = luma(sampleData.rgb);
                    float wLuma = exp(-abs(centerLuma - sampleLuma) * 4.0); // Simple luma rejection
                    
                    float w = kernel[abs(x)] * kernel[abs(y)] * wNormal * wDepth * wLuma;
                    
                    sumCol += sampleData.rgb * w;
                    sumW += w;
                }
            }
        }
        
        spatialOut.rgb = sumCol / max(sumW, 1e-5);
        spatialOut.a = centerData.a; // Pass through accum frames or whatever
        
        if (any(isnan(spatialOut)) || any(isinf(spatialOut))) {
            spatialOut = vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    /* RENDERTARGETS: 8 */
    gl_FragData[0] = spatialOut;
}
#endif
