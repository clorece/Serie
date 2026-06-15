
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

#define STEP_SIZE 1.0
#define INPUT_TEX colortex11

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 sampleCenter  = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));

    float depth0 = texture(depthtex0, sampleCenter).r;
    vec4 spatialOut = vec4(0.0);

    vec2 unjitteredCoord = texCoord * renderScale;

    if (depth0 < 1.0) {
        vec3 centerNormal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
        
        vec2 clipXY = sampleCenter / renderScale * 2.0 - 1.0;
        vec4 fragPos = gbufferProjectionInverse * vec4(clipXY, depth0 * 2.0 - 1.0, 1.0);
        vec3 viewPos = fragPos.xyz / fragPos.w;
        vec3 viewDir = normalize(viewPos);
        
        vec4 centerData = texture(INPUT_TEX, unjitteredCoord);
        vec3 sumCol = centerData.rgb;
        float sumW = 1.0;
        
        float centerLuma = luma(centerData.rgb);

        const float kernel[3] = float[3](1.0, 2.0/3.0, 1.0/6.0);

        if (length(centerNormal) > 0.001) {
            float VdotN = max(dot(centerNormal, -viewDir), 0.0);
            vec2 normalTransDir = normalize(centerNormal.xy + 1e-10);
            float stretch = clamp(1.0 - VdotN, 0.0, 1.0);
            float m1 = 0.0;
            float m2 = 0.0;
            float vW = 0.0;
            float centerDepthLin = getDepth(depth0);
            for (int vy = -1; vy <= 1; vy++) {
                for (int vx = -1; vx <= 1; vx++) {
                    vec2 vOffset = vec2(vx, vy) * texelSize * renderScale;
                    float vDepth = texture(depthtex0, sampleCenter + vOffset).r;
                    
                    if (abs(centerDepthLin - getDepth(vDepth)) < 0.1) {
                        float vLum = luma(texture(INPUT_TEX, unjitteredCoord + vOffset).rgb);
                        m1 += vLum;
                        m2 += vLum * vLum;
                        vW += 1.0;
                    }
                }
            }
            float stdDev = 1.0;
            if (vW > 0.1) {
                m1 /= vW;
                m2 /= vW;
                stdDev = sqrt(max(m2 - m1 * m1, 0.0));
            }
            
            float frameFactor = 1.0 + min(centerData.a, 32.0) * 0.2; // 1.0 to 7.4
            float lumaStrictness = frameFactor / max(max(centerLuma, 0.05) * stdDev * 10.0, 0.01);
            for (int y = -2; y <= 2; y++) {
                for (int x = -2; x <= 2; x++) {
                    if (x == 0 && y == 0) continue;
                    
                    vec2 baseOffset = vec2(x, y) * STEP_SIZE;
                    float normalTransWeight = -dot(baseOffset, normalTransDir) * stretch;
                    baseOffset += normalTransDir * normalTransWeight;
                    
                    vec2 offset = baseOffset * texelSize;
                    vec2 sampleCoord = sampleCenter + offset;
                    vec2 sampleUnjittered = unjitteredCoord + offset;
                    
                    if (any(lessThan(sampleCoord, vec2(0.0))) || any(greaterThanEqual(sampleCoord, vec2(1.0)))) continue;
                    
                    float sampleDepth0 = texture(depthtex0, sampleCoord).r;
                    vec3 sampleNormal = normalize(texture(colortex1, sampleCoord).rgb * 2.0 - 1.0);
                    
                    float wNormal = pow(max(dot(centerNormal, sampleNormal), 0.0), 32.0);
                    
                    vec2 sClipXY = sampleCoord / renderScale * 2.0 - 1.0;
                    vec4 sampleFragPos = gbufferProjectionInverse * vec4(sClipXY, sampleDepth0 * 2.0 - 1.0, 1.0);
                    vec3 sampleViewPos = sampleFragPos.xyz / sampleFragPos.w;
                    
                    vec3 posDiff = sampleViewPos - viewPos;
                    float depthGradient = dot(posDiff, centerNormal);
                    float wDepth = exp(-abs(depthGradient) * max(30.0 / -viewPos.z, 5.0));
                    
                    vec4 sampleData = texture(INPUT_TEX, sampleUnjittered);
                    float sampleLuma = luma(sampleData.rgb);
                    float wLuma = exp(-abs(centerLuma - sampleLuma) * lumaStrictness);
                    
                    float w = kernel[abs(x)] * kernel[abs(y)] * wNormal * wDepth * wLuma;
                    
                    sumCol += sampleData.rgb * w;
                    sumW += w;
                }
            }
        }
        
        spatialOut.rgb = sumCol / max(sumW, 1e-5);
        spatialOut.a = centerData.a; 
        
        if (any(isnan(spatialOut)) || any(isinf(spatialOut))) {
            spatialOut = vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    /* RENDERTARGETS: 6 */
    gl_FragData[0] = spatialOut;
}
#endif
