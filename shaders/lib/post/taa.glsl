#ifndef TAA_GLSL
#define TAA_GLSL

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

uniform sampler2D depthtex0;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferModelViewInverse;

// High-quality Luminance and Reinhard Tonemapping Helpers
float getLuminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 ReinhardTonemap(vec3 color) {
    return color / (1.0 + getLuminance(color));
}

vec3 ReinhardInverse(vec3 color) {
    return color / max(1.0 - getLuminance(color), 0.0001);
}

#include "/lib/util/sampling.glsl"

// 3x3 Neighborhood gathering for variance clipping and sharpening
void getNeighborhoodStats(sampler2D currentFrame, vec2 uv, vec2 screenSize, out vec3 mean, out vec3 std, out vec4 minColor, out vec4 maxColor, out vec4 left, out vec4 right, out vec4 up, out vec4 down) {
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    
    vec4 center = texture(currentFrame, uv);
    minColor = center;
    maxColor = center;
    
    left = center; right = center; up = center; down = center;
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(float(x), float(y)) / screenSize;
            vec4 c = texture(currentFrame, uv + offset);
            
            m1 += c.rgb;
            m2 += c.rgb * c.rgb;
            
            minColor = min(minColor, c);
            maxColor = max(maxColor, c);
            
            if (x == -1 && y == 0) left = c;
            else if (x == 1 && y == 0) right = c;
            else if (x == 0 && y == 1) up = c;
            else if (x == 0 && y == -1) down = c;
        }
    }
    
    mean = m1 / 9.0;
    std  = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
}

// Reprojection math
vec2 getPreviousUV(vec2 uv) {
    float depth0 = texture(depthtex0, uv).r;
    
    vec2 currentJitter = getTaaJitter(frameCounter) / vec2(viewWidth, viewHeight);
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) / vec2(viewWidth, viewHeight);

    // Unjitter the current UV to get the true unjittered clip space position
    vec2 uvUnjittered = uv - currentJitter;
    vec4 clipPos = vec4(uvUnjittered * 2.0 - 1.0, depth0 * 2.0 - 1.0, 1.0);
    
    // View space position (unjittered matrices assumed)
    vec4 viewPosVal = gbufferProjectionInverse * clipPos;
    vec3 viewPos = viewPosVal.xyz / viewPosVal.w;
    
    // World space position relative to current camera
    vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    
    // If it's a sky pixel, translation shouldn't affect reprojection
    vec3 cameraOffset = (depth0 == 1.0) ? vec3(0.0) : (cameraPosition - previousCameraPosition);
    vec3 previousWorldPos = worldPos + cameraOffset;
    
    // Project to previous screen coordinates
    vec4 previousClipPos = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(previousWorldPos, 1.0));
    vec2 prevUV = (previousClipPos.xy / previousClipPos.w) * 0.5 + 0.5;
    
    // Re-jitter to match the previous frame's subpixel offset in the history buffer
    return prevUV + prevJitter;
}

bool inScreen(vec2 uv) {
    return uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
}

vec4 taa(vec2 currentPos, vec2 screenSize, sampler2D currentFrame, sampler2D historyFrame) {
    vec2 uv = currentPos / screenSize;
    
    // Sample current color
    vec4 currentColor = texture(currentFrame, uv);
    
    // Determine the previous UV coordinate using accurate jittered reprojection
    vec2 prevUV = getPreviousUV(uv);
    
    // Determine whether history is valid
    float blendFactor = taaBlendWeight;
    if (!inScreen(prevUV)) {
        blendFactor = 0.0;
    }
    
    // Sample the history frame using high-fidelity Catmull-Rom filtering
    vec4 prevColor = textureCatmullRom(historyFrame, prevUV, screenSize);
    
    // Get neighborhood statistics for variance clipping and sharpening
    vec3 mean, std;
    vec4 minColor, maxColor, left, right, up, down;
    getNeighborhoodStats(currentFrame, uv, screenSize, mean, std, minColor, maxColor, left, right, up, down);
    
    // Variance clipping: clamp history to mean +/- N*std
    // This is more robust than AABB clamping and reduces both ghosting and flickering.
    float gamma = 1.25; // Clipping tightness: lower = less ghosting, more flicker
    vec3 clampMin = mean - std * gamma;
    vec3 clampMax = mean + std * gamma;
    
    // Also use the AABB to ensure we don't go outside the extreme neighborhood bounds
    prevColor.rgb = clamp(prevColor.rgb, clampMin, clampMax);
    prevColor = clamp(prevColor, minColor, maxColor);
    
    // Blend current frame and history in Reinhard Tonemapped space to prevent glowing/flickering highlights
    vec3 tonemappedHistory = ReinhardTonemap(prevColor.rgb);
    vec3 tonemappedCurrent = ReinhardTonemap(currentColor.rgb);
    vec3 blended = mix(tonemappedCurrent, tonemappedHistory, blendFactor * 1.0);
    vec4 blendedColor = vec4(ReinhardInverse(blended), currentColor.a);
    
    // Compute 5-tap high-pass sharpening detail to counteract blending blur
    vec4 detail = currentColor * 4.0 - (left + right + up + down);
    
    // Apply sharpening detail and clamp the final output to the neighborhood bounds to prevent ringing artifacts
    vec4 finalColor = blendedColor + detail * taaSharpenAmount;
    return clamp(finalColor, minColor, maxColor);
}

#endif
