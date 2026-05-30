// d8_fog_sky : atmosphere — applied AFTER the path-tracing chain
// Replaces sky pixels with the procedural sky and (optionally) applies fog to
// the composited scene colour. Runs last in the deferred stage so the GI/denoise
// passes operate on geometry only and never have to fight the sky.

#ifdef VERTEX

out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;


void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

const int gcolorFormat	= RGBA16F;

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;
in vec3 upVector;
in vec3 sunVector;
in vec3 moonVector;


float depth0 = texture(depthtex0, texCoord).x;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/fragment/clouds.glsl"
// fog.glsl + atmosphere.glsl deleted — legacy raymarch superseded by the LUT path.

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord).rgb;


	vec3 fragPosition = getFragPosition().xyz;
    vec3 viewDir = normalize(fragPosition);
    vec3 worldDir = mat3(gbufferModelViewInverse) * viewDir;

    vec3 worldSunDir = mat3(gbufferModelViewInverse) * sunVector;
    vec3 worldMoonDir = mat3(gbufferModelViewInverse) * moonVector;

    // Assume sea level is at Y=64
    float eyeAltitude = cameraPosition.y - 64.0;

    float dist = length(fragPosition);

    if (depth0 == 1.0) {
        color = getSky(worldDir, worldSunDir, worldMoonDir, eyeAltitude);

        #ifdef CLOUDS
        // Pick the active celestial light. At night the sun is below the
        // horizon — feeding worldSunDir + SUN_COLOR_BASE into the per-step
        // T-LUT inside raymarchClouds samples the atmosphere at negative
        // cosLightZenith, which returns the boundary-extrapolated sunset
        // tint → clouds end up red at midnight. Switch to moon below the
        // horizon, and scale by the existing sun/moon activity factors so
        // direct cloud light fades smoothly through twilight.
        float cloudMidAlt = (CLOUDS_LAYER_BOTTOM + CLOUDS_LAYER_TOP) * 0.5;
        vec3  ambient     = getSkyAmbient(cloudMidAlt);

        // Activity factors mirror colors.glsl (which lives in vertex scope —
        // its `sunActivity` / `moonActivity` aren't accessible here, so we
        // compute the same smoothstep curves inline. worldSunDir.y is
        // equivalent to sunUp = dot(sunVector, upVector).
        bool  moonlit       = worldSunDir.y < -0.04;
        float cloudSunAct   = smoothstep(-0.1, 0.16, worldSunDir.y);
        float cloudMoonAct  = smoothstep(-0.1, 0.10, worldMoonDir.y);
        vec3  lightDir      = moonlit ? worldMoonDir : worldSunDir;
        vec3  lightCol      = moonlit
                            ? MOON_COLOR_BASE * cloudMoonAct
                            : SUN_COLOR_BASE  * cloudSunAct;

        vec4 cloud = raymarchClouds(cameraPosition, worldDir, lightDir, lightCol, ambient);
        color = color * cloud.a + cloud.rgb;
        #endif
    }
    #ifndef VOLUMETRIC_LIGHT
    else {
        // Aerial perspective: 8-step march from camera to surface samples the
        // T-LUT for sun visibility per step, then `color = scene * T + scatter`.
        // Distant terrain dissolves into the same sky color at depth==1.
        // When VOLUMETRIC_LIGHT is on, d9_vl handles this with shadow-aware
        // integration (god rays); skip here to avoid double-integration.
        AerialPerspective ap = computeAerialPerspective(
            worldDir, worldSunDir, worldMoonDir, eyeAltitude, dist);
        color = color * ap.transmittance + ap.scatter;
    }
    #endif

    /* RENDERTARGETS: 0 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
