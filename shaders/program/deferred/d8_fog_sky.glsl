// d8_fog_sky : atmosphere — applied AFTER the path-tracing chain
// Replaces sky pixels with the procedural sky and (optionally) applies fog to
// the composited scene colour. Runs last in the deferred stage so the GI/denoise
// passes operate on geometry only and never have to fight the sky.

#ifdef VERTEX

#include "/lib/options.glsl"

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

    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
    
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/util/time.glsl"

const int gcolorFormat	= RGBA16F;

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;
in vec3 upVector;
in vec3 sunVector;
in vec3 moonVector;


float depth0 = texture(depthtex0, texCoord * renderScale).x;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/fragment/clouds.glsl"

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord * renderScale).rgb;


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

        float cloudMidAlt = (CLOUDS_LAYER_BOTTOM + CLOUDS_LAYER_TOP) * 0.5;
        vec3  ambient     = getSkyAmbient(cloudMidAlt);

        TimeState t = getTimeState();
        vec3  lightDir = t.activeLightDir;
        
        vec3 exoSun  = vec3(1.0, 1.0, 1.1) * SUN_ILLUMINANCE;
        vec3 exoMoon = vec3(0.65, 0.85, 1.0) * MOON_ILLUMINANCE * 10.0;
        
        // We must NOT use t.shadowFade here, because shadowFade returns to 1.0 at night 
        // to render moon shadows. We need a simple day/night mix factor.
        float isDay = smoothstep(-0.1, 0.1, t.sunUp);
        vec3 lightCol = mix(exoMoon, exoSun, isDay) * 1.5;

        vec4 cloud = raymarchClouds(cameraPosition, worldDir, lightDir, lightCol, ambient);
        color = color * cloud.a + cloud.rgb;
        #endif
    }
    #ifndef VOLUMETRIC_LIGHT
    else {

        AerialPerspective ap = computeAerialPerspective(
            worldDir, worldSunDir, worldMoonDir, eyeAltitude, dist);
        color = color * ap.transmittance + ap.scatter;
    }
    #endif

    /* RENDERTARGETS: 0 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
