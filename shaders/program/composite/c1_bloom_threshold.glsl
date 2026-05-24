#include "/lib/options.glsl"

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

in vec2 texCoord;

uniform sampler2D colortex0; // Resolved HDR scene color (contains exposure in alpha)
uniform sampler2D depthtex0; // Depth buffer

#include "/lib/util/common.glsl"
#include "/lib/post/bloom.glsl"

void main() {
    vec3 sceneColor = texture(colortex0, texCoord).rgb;
    
    // ----------------------------------------------------
    // FETCH DYNAMIC AUTO EXPOSURE FROM PASS 0
    // ----------------------------------------------------
    float exposure = texelFetch(colortex0, ivec2(0), 0).a;
    if (exposure <= 0.001 || isnan(exposure) || isinf(exposure)) {
        exposure = 1.3;
    }
    
    // ----------------------------------------------------
    // SOFT-KNEE BLOOM EXTRACTION
    // ----------------------------------------------------
    vec3 bloomColor = vec3(0.0);
    
    #ifdef BLOOM
    float depth0 = texture(depthtex0, texCoord).r;
    
    // ----------------------------------------------------
    // HDR BLOOM EXTRACTION
    // ----------------------------------------------------
    // Thresholding in HDR space (before auto-exposure) allows colored highlights 
    // to bloom based on their intrinsic energy, not just their final screen brightness.
    float threshold = (depth0 == 1.0) ? 0.4 : 0.7;
    float knee = (depth0 == 1.0) ? 0.2 : 0.3;
    
    bloomColor = SoftThreshold(sceneColor, threshold, knee);
    #endif

    // Write outputs
    /* DRAWBUFFERS:35 */
    // gl_FragData[0] -> colortex3 (bright-pass extraction)
    gl_FragData[0] = vec4(bloomColor, 1.0);
    
    // gl_FragData[1] -> colortex5 (TAA history + auto exposure stored in alpha)
    gl_FragData[1] = vec4(sceneColor, exposure);
}

#endif
