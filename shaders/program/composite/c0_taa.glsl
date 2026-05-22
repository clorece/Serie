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
   
uniform sampler2D colortex0;
uniform sampler2D colortex5;
uniform float frameTime;

#include "/lib/util/common.glsl"
#include "/lib/post/taa.glsl"

void main() {
    vec2 currentPos = texCoord / texelSize;

    #ifdef TAA
        vec4 finalColor = taa(currentPos, vec2(viewWidth, viewHeight), colortex0, colortex5);
    #else
        vec4 finalColor = texture(colortex0, texCoord);
    #endif
    
    // ----------------------------------------------------
    // CAMERA-LIKE TEMPORAL AUTO EXPOSURE (Pass 0)
    // ----------------------------------------------------
    float prevExposure = texelFetch(colortex5, ivec2(0), 0).a;
    if (prevExposure <= 0.001 || isnan(prevExposure) || isinf(prevExposure)) {
        prevExposure = 1.0;
    }
    
    float exposure = prevExposure;
    
    #ifdef AUTO_EXPOSURE
    // Compute exposure only at pixel (0,0) to keep cost at zero
    if (ivec2(gl_FragCoord.xy) == ivec2(0)) {
        float sumLuma = 0.0;
        float totalWeight = 0.0;
        
        // Sample screen-space coordinates in a uniform 9x9 grid (avoiding UI edges)
        for (float x = 0.15; x < 0.9; x += 0.09) {
            for (float y = 0.15; y < 0.9; y += 0.09) {
                vec2 uv = vec2(x, y);
                vec3 rawColor = texture(colortex0, uv).rgb;
                float luma = dot(rawColor, vec3(0.2126, 0.7152, 0.0722));
                
                // Photographic center-weighted metering
                float distToCenter = distance(uv, vec2(0.5)) * 2.0; // 0 to ~1.4
                float weight = mix(1.0, exp(-distToCenter * distToCenter * 2.0), AUTO_EXPOSURE_CENTER_WEIGHT);
                
                sumLuma += luma * weight;
                totalWeight += weight;
            }
        }
        
        float avgLuma = sumLuma / totalWeight;
        avgLuma = clamp(avgLuma, 0.001, 10.0);
        
        // Calibration constant target for middle-gray exposure balance
        float targetExposure = AUTO_EXPOSURE_TARGET / avgLuma;
        
        // Enforce physical constraints on exposure scale
        targetExposure = clamp(targetExposure, AUTO_EXPOSURE_MIN, AUTO_EXPOSURE_MAX);
        
        // Adapt faster when going dark -> bright than bright -> dark to simulate eye pupils
        float rate = targetExposure > prevExposure ? 1.0 : 2.0;
        rate *= AUTO_EXPOSURE_SPEED;
        exposure = mix(prevExposure, targetExposure, 1.0 - exp(-rate * frameTime));
    }
    #else
    exposure = EXPOSURE; // Match fallback exposure
    #endif
    
    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(finalColor.rgb, exposure);
}

#endif
