#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"

in vec2 texCoord;
   

#include "/lib/util/common.glsl"
#include "/lib/post/taa.glsl"

void main() {
    vec2 currentPos = texCoord / texelSize;

    #ifdef TAA
        vec4 finalColor = taa(currentPos, vec2(viewWidth, viewHeight), colortex0, colortex5);
    #else
        vec4 finalColor = texture(colortex0, min(texCoord * renderScale, vec2(renderScale) - 1.0 / vec2(viewWidth, viewHeight)));
    #endif

    #if TAA_DEBUG > 0
    {
        vec2 sUV  = min(texCoord * renderScale, vec2(renderScale) - 1.0 / vec2(viewWidth, viewHeight));
        vec3 src  = texture(colortex0, sUV).rgb;
        vec3 outc = finalColor.rgb;

        float srcMaxRB = max(src.r,  src.b);
        float outMaxRB = max(outc.r, outc.b);
        float srcDef = (srcMaxRB > 0.02) ? clamp(1.0 - src.g  / max(srcMaxRB, 1e-5), 0.0, 1.0) : 0.0;
        float outDef = (outMaxRB > 0.02) ? clamp(1.0 - outc.g / max(outMaxRB, 1e-5), 0.0, 1.0) : 0.0;
        bool srcBad = any(isnan(src))  || any(isinf(src));
        bool outBad = any(isnan(outc)) || any(isinf(outc));

        #if TAA_DEBUG == 1
            finalColor.rgb = src;                                         // raw source, as-is
        #elif TAA_DEBUG == 2
            if (srcBad)            finalColor.rgb = vec3(1.0, 0.0, 0.0);  // RED   = NaN/Inf in SOURCE
            else if (srcDef > 0.6) finalColor.rgb = vec3(0.0, 1.0, 0.0);  // GREEN = magenta in SOURCE
            else                   finalColor.rgb = src * 0.15;           // dim context
        #elif TAA_DEBUG == 3
            if (outBad)            finalColor.rgb = vec3(1.0, 0.0, 0.0);  // RED   = NaN/Inf in OUTPUT
            else if (outDef > 0.6) finalColor.rgb = vec3(0.0, 1.0, 0.0);  // GREEN = magenta in OUTPUT
            else                   finalColor.rgb = outc * 0.15;
        #elif TAA_DEBUG == 4
            finalColor.rgb = vec3(srcDef);                               // SOURCE green-deficit heatmap
        #endif
    }
    #endif

    float prevExposure = texelFetch(colortex5, ivec2(0), 0).a;
    if (prevExposure <= 0.001 || isnan(prevExposure) || isinf(prevExposure)) {
        prevExposure = 1.0;
    }
    
    float exposure = prevExposure;
    
    #ifdef AUTO_EXPOSURE
    if (ivec2(gl_FragCoord.xy) == ivec2(0)) {
        float sumLuma = 0.0;
        float totalWeight = 0.0;

        for (float x = -0.01; x <= 0.011; x += 0.01) {
            for (float y = -0.01; y <= 0.011; y += 0.01) {
                vec2 uv = vec2(0.5) + vec2(x, y);
                vec3 rawColor = texture(colortex0, uv * renderScale).rgb;
                float luma = dot(rawColor, vec3(0.2126, 0.7152, 0.0722));
                
                sumLuma += log2(max(luma, 0.0001));
                totalWeight += 1.0;
            }
        }
        
        float avgLuma = exp2(sumLuma / totalWeight);
        avgLuma = clamp(avgLuma, 0.001, 10.0);

        float targetExposure = AUTO_EXPOSURE_TARGET / avgLuma;
        

        targetExposure = clamp(targetExposure, AUTO_EXPOSURE_MIN, AUTO_EXPOSURE_MAX);

        float rate = targetExposure > prevExposure ? 1.0 : 2.0;
        rate *= AUTO_EXPOSURE_SPEED;
        exposure = mix(prevExposure, targetExposure, 1.0 - exp(-rate * frameTime));
    }
    #else
    exposure = EXPOSURE;
    #endif
    
    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(finalColor.rgb, exposure);
}

#endif
