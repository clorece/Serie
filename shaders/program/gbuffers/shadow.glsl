#ifdef VERTEX

#include "/lib/options.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/entityBvh.glsl"



/*
Shadow Source Code By saada2006:
https://github.com/saada2006/MinecraftShaderProgramming
*/

out vec2 texCoord;
flat out vec2 vMidTexCoord;
flat out vec3 voxelCenter;
flat out vec3 voxelNormal;
flat out uint voxelBlockCategory;
flat out uint voxelShapeId;   // index into the BLAS shape table (0 = full cube)
flat out uint voxelLightMatId;  // special-blocklight material, valid for VOXEL_LIGHT
flat out uint entitySlotId;   // hashed slot this entity accumulates its AABB into
flat out float isEntityGeom;  // 1 = mob/player/item geometry (not a block or block entity)
out vec3 fragWorldRel;        // per-fragment world position, camera-relative
flat out int biomeTintedBlock;
flat out float isBlockGeom; // 1 = real block (at_midBlock valid -> mid-texcoord write gate usable)
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

    // Entities/block-entities run through this same shadow program but get
    // default-zero block attributes (at_midBlock == 0, mc_midTexCoord == 0).
    // For them the mid-texcoord write gate in the fragment stage would be
    // meaningless and silently drop their voxels — flag real block geometry
    // (at_midBlock is the vertex->block-center offset: nonzero for blocks).
    isBlockGeom = any(notEqual(at_midBlock, vec3(0.0))) ? 1.0 : 0.0;

    // Entity capture for the per-frame BVH. Blocks carry at_midBlock and block
    // entities carry blockEntityId, so anything with neither is a mob, player or
    // dropped item -- exactly the geometry the static voxel grid excludes.
    //
    // Entities are drawn with their own transform, so the model-view translation
    // is the entity's render origin. Iris only exposes an entity *type* id, which
    // would merge every pig into one box; the origin distinguishes instances.
    isEntityGeom = (isBlockGeom < 0.5 && blockEntityId == 0) ? 1.0 : 0.0;
    vec3 entityOrigin = (shadowModelViewInverse * vec4(gl_ModelViewMatrix[3].xyz, 1.0)).xyz;
    entitySlotId = entitySlot(entityOrigin);
    fragWorldRel = position.xyz - cameraPosition.xyz;


    voxelNormal = normalize(mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal));

    // Classify block category + sub-block shape from the block id.
    //
    // Shaped blocks now use a single wide encoding written by
    // scripts/gen_block_shapes.py:
    //
    //     id = 40000 + shapeId*16 + matClass
    //
    // The old 20000+shape / 30000+mat*100+shape ranges capped shapes at 99,
    // which could not hold the 761 shapes derived from Minecraft's own models.
    // matClass is for terrain.glsl's PBR and is ignored here.
    float eid = mc_Entity.x;
    voxelShapeId  = 0u;
    voxelLightMatId = 0u;

    if      (eid == 10000.0) voxelBlockCategory = VOXEL_FOLIAGE; // leaves
    #ifdef EXCLUDE_BLOCKLIGHTS_VOXELIZATION
    else if (eid >= 10100.0 && eid <= 10199.0) voxelBlockCategory = VOXEL_AIR;
    #else
    else if (eid >= 10100.0 && eid <= 10199.0) {
        voxelBlockCategory = VOXEL_LIGHT; // mat goes in the payload
        voxelLightMatId = uint(round(eid - 10100.0));
    }
    #endif
    else if (eid == 10001.0) voxelBlockCategory = VOXEL_EMISSIVE;
    #ifdef VOXEL_SHAPES
    else if (eid >= float(SHAPE_ID_BASE)) {
        voxelBlockCategory = VOXEL_OPAQUE;
        voxelShapeId = uint(round(eid - float(SHAPE_ID_BASE))) >> 4u;
    }
    else if (blockEntityId >= SHAPE_ID_BASE) {
        voxelBlockCategory = VOXEL_OPAQUE;
        voxelShapeId = uint(blockEntityId - SHAPE_ID_BASE) >> 4u;
    }
    #else
    // Shapes disabled: shaped blocks fall back to excluded, as before.
    else if (eid >= float(SHAPE_ID_BASE)) voxelBlockCategory = VOXEL_AIR;
    else if (blockEntityId >= SHAPE_ID_BASE) voxelBlockCategory = VOXEL_AIR;
    #endif
    else if (eid == 10002.0 || eid == 10004.0 || eid == 10005.0 || eid == 10006.0 || eid == 10007.0 || entityId == 10002 || blockEntityId == 10002) voxelBlockCategory = VOXEL_AIR; // grass, flowers, transparents, water
    else if (eid >= 22001.0 && eid <= 22008.0) voxelBlockCategory = VOXEL_AIR; // rails: reflective yet must not occlude GI
    else                     voxelBlockCategory = VOXEL_OPAQUE; // 21001-21016 land here (PBR + normal voxel)

    // Guard against a shape id wider than the packed voxel word can hold; a
    // truncated id would index a wrong (or nonexistent) box list.
    if (voxelShapeId > VOX_MAX_SHAPE_ID) voxelShapeId = 0u;

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
#include "/lib/pt/voxelCascade.glsl"
#include "/lib/pt/entityBvh.glsl"

in vec2 texCoord;
flat in vec2 vMidTexCoord;
flat in vec3 voxelCenter;
flat in vec3 voxelNormal;
flat in uint voxelBlockCategory;
flat in uint voxelShapeId;
flat in uint voxelLightMatId;
flat in uint entitySlotId;
flat in float isEntityGeom;
in vec3 fragWorldRel;
flat in int biomeTintedBlock;
flat in float isBlockGeom;
in float skyLight;

layout(r32ui) uniform writeonly uimage3D voxelImg;
layout(r8ui) uniform writeonly uimage3D brickImg;
layout(r8ui) uniform writeonly uimage3D superBrickImg;

void main() {
    // check alpha for discard using per-fragment sampling (needed for leaves/foliage) to maintain the correct block shape in the voxel grid.
    vec4 texFrag = texture(texture, texCoord);
    if (texFrag.a < 0.1) {
        discard;
    }

    vec4 tex = texture(texture, vMidTexCoord);
    bool midTransparent = tex.a < 0.1; // remembered for the voxel-write gate below
    if (midTransparent) {
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

    // Grow this entity's slot AABB. Fixed point because GLSL has no float
    // atomics; the bias in entityEncode keeps values positive so min/max stay
    // ordered. Bounds are camera-relative to hold precision far from origin.
    if (isEntityGeom > 0.5) {
        uint s3 = entitySlotId * 3u;
        atomicMin(entityBvh.slotMin[s3 + 0u], entityEncode(fragWorldRel.x));
        atomicMin(entityBvh.slotMin[s3 + 1u], entityEncode(fragWorldRel.y));
        atomicMin(entityBvh.slotMin[s3 + 2u], entityEncode(fragWorldRel.z));
        atomicMax(entityBvh.slotMax[s3 + 0u], entityEncode(fragWorldRel.x));
        atomicMax(entityBvh.slotMax[s3 + 1u], entityEncode(fragWorldRel.y));
        atomicMax(entityBvh.slotMax[s3 + 2u], entityEncode(fragWorldRel.z));
        entityBvh.slotUsed[entitySlotId] = 1u;
    }

    uint finalCategory = voxelBlockCategory;

    // scale down blocklight emission outdoors under the open sky during the day.
    if (finalCategory == VOXEL_EMISSIVE || finalCategory == VOXEL_LIGHT) {
        vec3 sunVec = normalize(sunPosition);
        vec3 upVec  = normalize(upPosition);
        float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
        if (sunUp > 0.1 && skyLight > 0.85) {
            finalCategory = VOXEL_AIR; // exclude from voxelization (no emission)
        }
    }

    // Emitters carry their material in the payload instead of an albedo; their
    // colour comes from GetSpecialBlocklightColor(mat) at trace time.
    uint payload = (finalCategory == VOXEL_LIGHT)
                 ? (voxelLightMatId & 127u)
                 : packAlbedo565(albedo);
    uint voxelWord = packVoxel(finalCategory, voxelShapeId, payload);

    bool isTopFace = voxelNormal.y > 0.5;

    bool centerFrag = all(lessThanEqual(abs(texCoord - vMidTexCoord), fwidth(texCoord)));
    bool skipVoxelWrite = ((biomeTintedBlock == 1) && !isTopFace) || (finalCategory == VOXEL_AIR)
                       || !(centerFrag || midTransparent || isBlockGeom < 0.5);

    if (!skipVoxelWrite) {
        // Write every cascade the block falls inside. Coarser cascades collapse
        // many blocks into one voxel, so the last writer wins for albedo/shape;
        // that is fine because only occupancy is consulted beyond cascade 0.
        for (int k = 0; k < VOXEL_CASCADES; ++k) {
            ivec3 coord;
            if (!worldToCascade(voxelCenter, k, coord)) continue;
            // Shapes are meaningless once a voxel spans several blocks.
            uint w = (k == 0) ? voxelWord : packVoxel(finalCategory, 0u, payload);
            imageStore(voxelImg,      cascadeAtlasCoord(coord, k), uvec4(w));
            imageStore(brickImg,      cascadeBrickCoord(coord, k), uvec4(1u));
            imageStore(superBrickImg, cascadeSuperCoord(coord, k), uvec4(1u));
        }
    }

    gl_FragData[0] = tex;
}

#endif
