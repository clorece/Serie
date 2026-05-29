#ifndef TAA_GLSL
#define TAA_GLSL

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"



// Box clamping in YCoCg space prevents color shifting (rainbow ghosting)
vec3 RGBtoYCoCg(vec3 c) {
    return vec3(
         0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
         0.5  * c.r - 0.5 * c.b,
        -0.25 * c.r + 0.5 * c.g - 0.25 * c.b
    );
}
vec3 YCoCgtoRGB(vec3 c) {
    float tmp = c.x - c.z;
    return vec3(tmp + c.y, c.x + c.z, tmp - c.y);
}

float getLuminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 ReinhardTonemap(vec3 color) {
    return color / (1.0 + getLuminance(color));
}

vec3 ReinhardInverse(vec3 color) {
    return color / max(1.0 - getLuminance(color), 0.0001);
}


// 5-tap Catmull-Rom filter for history sampling. Prevents the progressive
// blur that occurs when using standard bilinear filtering across many frames.
vec4 textureCatmullRom(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 texPixelSize = 1.0 / texSize;
    uv = uv * texSize;

    vec2 p = floor(uv - 0.5) + 0.5;
    vec2 f = uv - p;
    vec2 f2 = f * f;
    vec2 f3 = f * f2;

    const float c = 0.5; // Sharpness
    vec2 w0 =        -c  * f3 +  2.0 * c         * f2 - c * f;
    vec2 w1 =  (2.0 - c) * f3 - (3.0 - c)        * f2         + 1.0;
    vec2 w2 = -(2.0 - c) * f3 + (3.0 -  2.0 * c) * f2 + c * f;
    vec2 w3 =         c  * f3 -                c * f2;

    vec2 w12 = w1 + w2;
    vec2 tc12 = texPixelSize * (p + w2 / w12);
    vec2 tc0 = texPixelSize * (p - 1.0);
    vec2 tc3 = texPixelSize * (p + 2.0);

    vec4 color = textureLod(tex, vec2(tc12.x, tc0.y ), 0.0) * (w12.x * w0.y ) +
                 textureLod(tex, vec2(tc0.x,  tc12.y), 0.0) * (w0.x  * w12.y) +
                 textureLod(tex, vec2(tc12.x, tc12.y), 0.0) * (w12.x * w12.y) +
                 textureLod(tex, vec2(tc3.x,  tc12.y), 0.0) * (w3.x  * w12.y) +
                 textureLod(tex, vec2(tc12.x, tc3.y ), 0.0) * (w12.x * w3.y );
                 
    return color / max(w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y, 0.0001);
}


void getVariance3x3(sampler2D currentFrame, vec2 uv, vec2 screenSize, vec3 currentColor, out vec3 avgColor, out vec3 variance) {
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    

    vec3 c0 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2(-1, -1) / screenSize, 0.0).rgb);
    vec3 c1 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2( 0, -1) / screenSize, 0.0).rgb);
    vec3 c2 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2( 1, -1) / screenSize, 0.0).rgb);
    vec3 c3 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2(-1,  0) / screenSize, 0.0).rgb);
    vec3 c4 = RGBtoYCoCg(currentColor);
    vec3 c5 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2( 1,  0) / screenSize, 0.0).rgb);
    vec3 c6 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2(-1,  1) / screenSize, 0.0).rgb);
    vec3 c7 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2( 0,  1) / screenSize, 0.0).rgb);
    vec3 c8 = RGBtoYCoCg(textureLod(currentFrame, uv + vec2( 1,  1) / screenSize, 0.0).rgb);

    m1 = c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8;
    m2 = c0*c0 + c1*c1 + c2*c2 + c3*c3 + c4*c4 + c5*c5 + c6*c6 + c7*c7 + c8*c8;
    
    avgColor = m1 / 9.0;
    variance = sqrt(max(m2 / 9.0 - avgColor * avgColor, 0.0));
}


vec3 clipAABB(vec3 avgColor, vec3 variance, vec3 prevColor, float aggression) {
    vec3 clipMin = avgColor - variance * aggression;
    vec3 clipMax = avgColor + variance * aggression;
    
    vec3 diff = prevColor - avgColor;
    vec3 clipRatioMax = mix(vec3(1.0), (clipMax - avgColor) / diff, greaterThan(diff, clipMax - avgColor));
    vec3 clipRatioMin = mix(vec3(1.0), (clipMin - avgColor) / diff, lessThan(diff, clipMin - avgColor));
    
    diff *= clipRatioMax.x * clipRatioMax.y * clipRatioMax.z * clipRatioMin.x * clipRatioMin.y * clipRatioMin.z;
    return avgColor + diff;
}


// Uses the closest depth in a 3x3 window to prevent foreground objects from
// smearing their reprojection vectors onto the background.
float getClosestDepth(vec2 uv, vec2 screenSize) {
    float closestDepth = 2.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float d = textureLod(depthtex0, uv + vec2(x, y) / screenSize, 0.0).r;
            if (d < closestDepth) closestDepth = d;
        }
    }
    return closestDepth;
}

vec2 getPreviousUV(vec2 uv, vec2 screenSize, out vec3 velocityPixels) {
    float depth0 = getClosestDepth(uv, screenSize);
    if (depth0 >= 1.0) {
        velocityPixels = vec2(0.0, 0.0).xyy;
        return uv;
    }
    
    vec2 currentJitter = getTaaJitter(frameCounter) / screenSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) / screenSize;

    vec2 uvUnjittered = uv - currentJitter;
    vec4 clipPos = vec4(uvUnjittered * 2.0 - 1.0, depth0 * 2.0 - 1.0, 1.0);
    
    vec4 viewPosVal = gbufferProjectionInverse * clipPos;
    vec3 viewPos = viewPosVal.xyz / viewPosVal.w;
    vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    
    vec3 previousWorldPos = worldPos + (cameraPosition - previousCameraPosition);
    
    vec4 previousClipPos = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(previousWorldPos, 1.0));
    vec2 prevUV = (previousClipPos.xy / previousClipPos.w) * 0.5 + 0.5;
    
    velocityPixels = vec3((uvUnjittered - prevUV) * screenSize, 0.0);
    return prevUV + prevJitter;
}

bool inScreen(vec2 uv) {
    return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)));
}

vec4 taa(vec2 currentPos, vec2 screenSize, sampler2D currentFrame, sampler2D historyFrame) {
    vec2 uv = currentPos / screenSize;
    

    vec4 currentColorData = textureLod(currentFrame, uv, 0.0);
    vec3 currentColor = currentColorData.rgb;
    float exposureData = currentColorData.a; // Preserve auto-exposure state


    vec3 velocityPixels;
    vec2 prevUV = getPreviousUV(uv, screenSize, velocityPixels);
    
    if (!inScreen(prevUV)) {
        return currentColorData;
    }
    

    vec4 prevColorData = textureCatmullRom(historyFrame, prevUV, screenSize);
    vec3 prevColorYCoCg = RGBtoYCoCg(max(prevColorData.rgb, 0.0));
    

    vec3 avgColorYCoCg, variance;
    getVariance3x3(currentFrame, uv, screenSize, currentColor, avgColorYCoCg, variance);
    

    bool isWater = textureLod(colortex2, uv, 0.0).b > 0.5;

    // Aggression factor (lower = tighter clamp = less ghosting, more flicker)
    // Relax history clamp for water to prevent the animated waves and high-frequency
    // reflections/refractions from being clipped away (which disables TAA on water).
    float aggression = isWater ? 3.0 : 1.0; 
    

    prevColorYCoCg = clipAABB(avgColorYCoCg, variance, prevColorYCoCg, aggression);
    vec3 prevColor = max(YCoCgtoRGB(prevColorYCoCg), 0.0);
    

    float blendWeight = TAA_BLEND_WEIGHT;
    float velocityReject = clamp(pow(dot(velocityPixels.xy, velocityPixels.xy), 0.25) * 0.1, 0.0, 1.0);
    if (isWater) {
        velocityReject *= 0.25; // Keep history blending stable for water during camera movement
    }
    blendWeight *= (1.0 - velocityReject);


    vec3 tonemappedHistory = ReinhardTonemap(prevColor);
    vec3 tonemappedCurrent = ReinhardTonemap(currentColor);
    vec3 blended = mix(tonemappedCurrent, tonemappedHistory, blendWeight);
    
    return vec4(ReinhardInverse(blended), exposureData);
}

#endif
