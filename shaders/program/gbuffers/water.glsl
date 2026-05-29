#include "/lib/options.glsl"

// gbuffers_water : deferred water G-buffer writer.
//
// Blending is OFF (see shaders.properties) and the program writes colortex1 +
// colortex2 (DRAWBUFFERS:12), NOT colortex0 — so colortex0's lit scene is left
// untouched and composite `c_water` gets an intact refraction background.
//
// Water (block id 10006) stores its view-space wave normal in colortex1.rgb and a
// water flag in colortex2.b (= 1.0). colortex2 is the lightmap buffer, but it is
// only read by the deferred chain (d0_restir / d7), which runs BEFORE this pass, so
// it is free to repurpose afterward. The flag is used instead of colortex1.a + a
// depth test because (a) emissive blocks also carry colortex1.a=1.0 and (b) this
// pack's depthtex1 doesn't separate translucents, so a depth test can't isolate
// water. colortex2.b is 0 for all opaque geometry -> unambiguous water mask.
// Glass / ice render invisible for now (they no longer write colortex0); basic
// glass shading can be added to c_water later.

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

out vec2 texCoord;
out vec2 lightmapCoord;
out vec3 viewNormal;
out vec3 worldPos;
out vec4 color;
flat out float isWater;

attribute vec4 mc_Entity;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    color = gl_Color;
    viewNormal = normalize(gl_NormalMatrix * gl_Normal);
    lightmapCoord = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;

    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;

    isWater = (mc_Entity.x == 10006.0) ? 1.0 : 0.0;

    #ifdef TAA
        gl_Position.xy += getTaaJitter() * 2.0 * gl_Position.w / vec2(viewWidth, viewHeight);
    #endif
}

#endif

#ifdef FRAGMENT

#include "/lib/util/common.glsl"
#include "/lib/fragment/water.glsl"

in vec2 texCoord;
in vec2 lightmapCoord;
in vec3 viewNormal;
in vec3 worldPos;
in vec4 color;
flat in float isWater;

/* DRAWBUFFERS:12 */

void main() {
    vec4 albedo = texture(texture, texCoord) * color;

    // Blend is off, so discard cutout/transparent texels (e.g. glass-pane holes)
    // instead of writing them as occluding surfaces. Never discard water: its
    // vertex-colour alpha can be low and the surface must always be present.
    if (isWater < 0.5 && albedo.a < 0.1) discard;

    if (isWater > 0.5) {
        vec3 worldGeoN = normalize(mat3(gbufferModelViewInverse) * viewNormal);
        vec3 worldN = worldGeoN;

        #ifdef WATER_WAVES
        {
            float t = frameTimeCounter * WATER_WAVE_SPEED;

            // Distance LOD: fade waves toward flat and widen the finite-difference footprint
            // with range, so distant water doesn't alias / reveal the tiling pattern.
            float camDist = length(worldPos - cameraPosition);
            float lod = clamp(camDist / WATER_NORMAL_FADE, 0.0, 1.0);
            float strength = WATER_NORMAL_STRENGTH * (1.0 - 0.85 * lod);
            float eps = mix(0.10, 0.45, lod);

            // Tangent-plane perturbation works for any face orientation (flat tops, flowing
            // water, and vertical water side faces all get waves).
            worldN = waterSurfaceNormal(worldPos, worldGeoN, t, WATER_WAVE_AMPLITUDE, strength, eps);
        }
        #endif

        vec3 viewWaveN = normalize(mat3(gbufferModelView) * worldN);
        gl_FragData[0] = vec4(viewWaveN * 0.5 + 0.5, 1.0);     // colortex1: wave normal
        gl_FragData[1] = vec4(lightmapCoord, 1.0, 1.0);        // colortex2: .rg lightmap, .b=1 water flag
    } else {
        gl_FragData[0] = vec4(viewNormal * 0.5 + 0.5, 0.5);    // colortex1: glass/ice normal
        gl_FragData[1] = vec4(lightmapCoord, 0.0, 1.0);        // colortex2: .rg lightmap, .b=0 (not water)
    }
}

#endif
