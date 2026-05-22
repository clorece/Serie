// ============================================================================
//  d8_fog_sky : atmosphere — applied AFTER the path-tracing chain
// ----------------------------------------------------------------------------
//  Replaces sky pixels with the procedural sky and (optionally) applies fog to
//  the composited scene colour. Runs last in the deferred stage so the GI/denoise
//  passes operate on geometry only and never have to fight the sky.
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;

uniform int worldTime;
uniform vec3 sunPosition;
uniform vec3 upPosition;

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

const int gcolorFormat	= RGBA16;

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;
in vec3 upVector;
in vec3 sunVector;
in vec3 moonVector;

uniform sampler2D colortex0;
uniform sampler2D colortex6;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D shadowtex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

float depth0 = texture(depthtex0, texCoord).x;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/fragment/fog.glsl"

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord).rgb;

    // --- Space Transformation ---
	vec3 fragPosition = getFragPosition().xyz;
    vec3 viewDir = normalize(fragPosition);
    vec3 worldDir = mat3(gbufferModelViewInverse) * viewDir;

    vec3 worldSunDir = mat3(gbufferModelViewInverse) * sunVector;
    vec3 worldMoonDir = mat3(gbufferModelViewInverse) * moonVector;

    // Assume sea level is at Y=64
    float eyeAltitude = cameraPosition.y - 64.0;

    float dist = length(fragPosition);
    //color = getFog(worldDir, dist, worldSunDir, worldMoonDir, eyeAltitude, color);

    if (depth0 == 1.0) {
        color = getSky(worldDir, worldSunDir, worldMoonDir, eyeAltitude);
    }

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
