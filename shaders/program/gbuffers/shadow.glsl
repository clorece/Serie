#ifdef VERTEX

#include "/lib/options.glsl"

const float PI = 3.14159265359;

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

    // World-space surface normal, used to identify faces
    voxelNormal = normalize(mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal));

    // Classify block category from entity ID
    float eid = mc_Entity.x;
    if      (eid == 10000.0) voxelBlockCategory = 2u; // foliage 2 (leaves) - Voxelized
    else if (eid == 10001.0) voxelBlockCategory = 3u; // emissive
    else if (eid == 10002.0 || eid == 10004.0 || eid == 10005.0 || entityId == 10002 || blockEntityId == 10002) voxelBlockCategory = 0u; // excluded (entities, grass, flowers, transparents, etc.) -> VOXEL_AIR
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


// Image binding for writes MUST use the colorimgN alias, not colortexN.
// colortexN is the sampler (read) name; imageStore to colortexN is a silent no-op in Iris.
layout(rgba8ui) uniform writeonly uimage2D colorimg7;

void main() {
    // Check alpha for discard using per-fragment sampling (needed for leaves/foliage)
    // to maintain the correct block shape in the voxel grid.
    vec4 texFrag = texture(texture, texCoord);
    if (texFrag.a < 0.1) {
        discard;
    }

    // Sample at the middle of the texture tile for a stable, representative block color.
    // This prevents the per-texel "rainbow" flicker and noise in the voxel grid.
    // We use the stable color for EVERYTHING to ensure every fragment writes the same value.
    vec4 tex = texture(texture, vMidTexCoord);
    if (tex.a < 0.1) {
        // If the tile center is transparent, use the fragment color as a fallback
        // but this should be rare for solid blocks.
        tex = texFrag;
    }

    // Pack: .r = block category, .gba = block albedo color (for GI color bleed).
    // gl_Color carries biome/vertex tint, but some Iris shadow configs don't supply it
    // (it comes back as 0, which would zero the whole albedo). Fall back to the untinted
    // texture colour when no tint is present so the grid never stores black.
    vec3 tint = gl_Color.rgb;
    vec3 albedo = tex.rgb * (all(lessThan(tint, vec3(0.004))) ? vec3(1.0) : tint);

    if (biomeTintedBlock == 1) {
        // For grass blocks, use the biome tint directly as the albedo (averaged color).
        // Fall back to a default grass green if the tint is missing.
        albedo = all(lessThan(tint, vec3(0.004))) ? vec3(0.48, 0.61, 0.28) : tint;
    } else if (biomeTintedBlock == 2) {
        // For leaves, we use the texture color * biome tint.
        // If tint is missing (black) or default (white) in the shadow pass, 
        // use a fallback foliage green to ensure they aren't grey.
        vec3 leafTint = (all(lessThan(tint, vec3(0.004))) || all(greaterThan(tint, vec3(0.999)))) ? vec3(0.38, 0.58, 0.18) : tint;
        albedo = tex.rgb * leafTint;
    }

    uint finalCategory = voxelBlockCategory;

    uvec4 voxelData = uvec4(finalCategory, uvec3(clamp(albedo, 0.0, 1.0) * 255.0 + 0.5));

    // For biome-tinted ground (grass_block): skip untinted faces (dirt sides/bottom)
    // so only the green-tinted top face writes its color to the voxel atlas.
    // Use the world-space normal to identify the top face (upward pointing).
    // Leaves (biomeTintedBlock == 2) should not skip faces.
    bool isTopFace = voxelNormal.y > 0.5;
    bool skipVoxelWrite = ((biomeTintedBlock == 1) && !isTopFace) || (finalCategory == 0u);

    // Write this fragment into the voxel atlas.
    // The atlas is cleared to VOXEL_AIR (0) each frame by colortex7Clear.
    // Using 'flat' voxelCenter and 'flat' vMidTexCoord ensures all fragments of a block
    // write the EXACT same data to the EXACT same voxel coordinate.
    ivec3 voxelCoord;
    vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
    if (!skipVoxelWrite && worldToVoxel(voxelCenter, gridOrigin, voxelCoord)) {
        imageStore(colorimg7, voxelCoordToAtlas(voxelCoord), voxelData);
    }

    gl_FragData[0] = tex;
}

#endif
