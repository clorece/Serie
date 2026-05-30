#ifdef VERTEX

#include "/lib/options.glsl"



/*
Shadow Source Code By saada2006:
https://github.com/saada2006/MinecraftShaderProgramming
*/

out vec2 texCoord;
flat out vec2 vMidTexCoord;
flat out vec3 voxelCenter;
flat out vec3 voxelNormal;
flat out uint voxelBlockCategory;
flat out int biomeTintedBlock;
out float skyLight;



attribute vec4 mc_Entity;
attribute vec3 at_midBlock;
attribute vec2 mc_midTexCoord;

vec3 wind(vec3 position) {
    position.xy += abs(sin(2.0 * PI * (frameTimeCounter * 0.7 + position.x /  11.0 + position.y / 5.0)) * 0.0015);
    return position;
}

void main() {
    texCoord = gl_MultiTexCoord0.xy;
    vMidTexCoord = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).st;
    gl_Position = ftransform();

    // Use the projection inverse to recover world-space position.
    // Adding at_midBlock/64.0 snaps the sample point to the exact block center.
    vec4 position = gl_Position;
	position = shadowProjectionInverse * position;
	position = shadowModelViewInverse * position;
	position.xyz += cameraPosition.xyz;

    voxelCenter = position.xyz + at_midBlock / 64.0;


    voxelNormal = normalize(mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal));

    // Classify block category from entity ID
    float eid = mc_Entity.x;
    if      (eid == 10000.0) voxelBlockCategory = 2u; // foliage 2 (leaves) - Voxelized
    #ifdef EXCLUDE_BLOCKLIGHTS_VOXELIZATION
    else if (eid >= 10100.0 && eid <= 10199.0) voxelBlockCategory = 0u; // excluded from voxel grid entirely
    #else
    else if (eid >= 10100.0 && eid <= 10199.0) voxelBlockCategory = 100u + uint(round(eid - 10100.0)); // special block light (mat stored as 100 + mat)
    #endif
    else if (eid == 10001.0) voxelBlockCategory = 3u; // emissive (fallback)
    else if (eid == 10002.0 || eid == 10004.0 || eid == 10005.0 || eid == 10006.0 || eid == 10007.0 || entityId == 10002 || blockEntityId == 10002) voxelBlockCategory = 0u; // excluded (entities, grass, flowers, transparents, water, etc.) -> VOXEL_AIR
    else                     voxelBlockCategory = 1u; // opaque (default)

    // Flag blocks that need special voxel coloring or face skipping.
    // 1 = grass_block (10003), 2 = leaves (10000)
    biomeTintedBlock = (eid == 10003.0) ? 1 : ((eid == 10000.0) ? 2 : 0);

    position.xyz -= cameraPosition.xyz;
	position = shadowModelView * position;
	position = shadowProjection * position;

	gl_Position = position;

	float dist = sqrt(gl_Position.x * gl_Position.x + gl_Position.y * gl_Position.y);
	float distortFactor = (1.0 - SHADOW_MAP_BIAS) + dist * SHADOW_MAP_BIAS;

	gl_Position.xy *= 1.0 / distortFactor;

    gl_FrontColor = gl_Color;
    skyLight = gl_MultiTexCoord1.y * (1.0 / 240.0);
}

#endif

#ifdef FRAGMENT

/*
Shadow Source Code By saada2006:
https://github.com/saada2006/MinecraftShaderProgramming
*/

#include "/lib/options.glsl"
#include "/lib/pt/voxelData.glsl"

in vec2 texCoord;
flat in vec2 vMidTexCoord;
flat in vec3 voxelCenter;
flat in vec3 voxelNormal;
flat in uint voxelBlockCategory;
flat in int biomeTintedBlock;
in float skyLight;

// Image binding for writes MUST use the colorimgN alias, not colortexN.
// colortexN is the sampler (read) name; imageStore to colortexN is a silent no-op in Iris.
layout(rgba8ui) uniform writeonly uimage2D colorimg7;

void main() {
    // check alpha for discard using per-fragment sampling (needed for leaves/foliage) to maintain the correct block shape in the voxel grid.
    vec4 texFrag = texture(texture, texCoord);
    if (texFrag.a < 0.1) {
        discard;
    }

    vec4 tex = texture(texture, vMidTexCoord);
    if (tex.a < 0.1) {
        // if the tile center is transparent, use the fragment color as a fallback but this should be rare for solid blocks
        tex = texFrag;
    }

    vec3 tint = gl_Color.rgb;
    vec3 albedo = tex.rgb * (all(lessThan(tint, vec3(0.004))) ? vec3(1.0) : tint);

    if (biomeTintedBlock == 1) {

        albedo = all(lessThan(tint, vec3(0.004))) ? vec3(0.48, 0.61, 0.28) : tint;
    } else if (biomeTintedBlock == 2) {

        vec3 leafTint = (all(lessThan(tint, vec3(0.004))) || all(greaterThan(tint, vec3(0.999)))) ? vec3(0.38, 0.58, 0.18) : tint;
        albedo = tex.rgb * leafTint;
    }

    uint finalCategory = voxelBlockCategory;

    // scale down blocklight emission outdoors under the open sky during the day.
    if (finalCategory == 3u || finalCategory >= 100u) {
        vec3 sunVec = normalize(sunPosition);
        vec3 upVec  = normalize(upPosition);
        float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
        if (sunUp > 0.1 && skyLight > 0.85) {
            finalCategory = 0u; // exclude from voxelization / set as AIR (no emission)
        }
    }

    uvec4 voxelData = uvec4(finalCategory, uvec3(clamp(albedo, 0.0, 1.0) * 255.0 + 0.5));

    bool isTopFace = voxelNormal.y > 0.5;
    bool skipVoxelWrite = ((biomeTintedBlock == 1) && !isTopFace) || (finalCategory == 0u);

    ivec3 voxelCoord;
    vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
    if (!skipVoxelWrite && worldToVoxel(voxelCenter, gridOrigin, voxelCoord)) {
        imageStore(colorimg7, voxelCoordToAtlas(voxelCoord), voxelData);
    }

    gl_FragData[0] = tex;
}

#endif
