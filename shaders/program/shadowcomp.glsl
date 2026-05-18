/////////////////////////////////////
// SerieVX IRC Populate Compute   //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

#if defined SHADOWCOMP
    vec3 upVec = normalize(gbufferModelView[1].xyz);
    vec3 sunVec = normalize(sunPosition);
    #include "/lib/commonVariables.glsl"
#endif

#include "/lib/colors/lightAndAmbientColors.glsl"

//////////Shadowcomp 1//////////Shadowcomp 1//////////Shadowcomp 1//////////
#if defined SHADOWCOMP && COLORED_LIGHTING_INTERNAL > 0 && COLORED_LIGHTING > 0

#define OPTIMIZATION_ACL_HALF_RATE_UPDATES
#define OPTIMIZATION_ACL_BEHIND_PLAYER

layout (local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
#if COLORED_LIGHTING_INTERNAL == 128
    const ivec3 workGroups = ivec3(16, 8, 16);
#elif COLORED_LIGHTING_INTERNAL == 192
    const ivec3 workGroups = ivec3(24, 12, 24);
#elif COLORED_LIGHTING_INTERNAL == 256
    const ivec3 workGroups = ivec3(32, 16, 32);
#elif COLORED_LIGHTING_INTERNAL == 384
    const ivec3 workGroups = ivec3(48, 24, 48);
#elif COLORED_LIGHTING_INTERNAL == 512
    const ivec3 workGroups = ivec3(64, 32, 64);
#elif COLORED_LIGHTING_INTERNAL == 768
    const ivec3 workGroups = ivec3(96, 32, 96);
#elif COLORED_LIGHTING_INTERNAL == 1024
    const ivec3 workGroups = ivec3(128, 32, 128);
#endif

// Tint colors for glass/translucent voxels (IDs 200+)
const vec3[] specialTintColor = vec3[](
    vec3(1.0, 1.0, 1.0),       // 200: White Stained Glass
    vec3(0.95, 0.65, 0.2),     // 201: Orange Stained Glass
    vec3(0.9, 0.2, 0.9),       // 202: Magenta Stained Glass
    vec3(0.4, 0.6, 0.85),      // 203: Light Blue Stained Glass
    vec3(0.9, 0.9, 0.2),       // 204: Yellow Stained Glass
    vec3(0.5, 0.8, 0.2),       // 205: Lime Stained Glass
    vec3(1.0, 0.4, 0.7),       // 206: Pink Stained Glass
    vec3(0.3, 0.3, 0.3),       // 207: Gray Stained Glass
    vec3(0.6, 0.6, 0.6),       // 208: Light Gray Stained Glass
    vec3(0.3, 0.5, 0.6),       // 209: Cyan Stained Glass
    vec3(0.5, 0.25, 0.7),      // 210: Purple Stained Glass
    vec3(0.2, 0.25, 0.7),      // 211: Blue Stained Glass
    vec3(0.45, 0.3, 0.2),      // 212: Brown Stained Glass
    vec3(0.45, 0.75, 0.35),    // 213: Green Stained Glass
    vec3(1.0, 0.05, 0.05),     // 214: Red Stained Glass
    vec3(0.1, 0.1, 0.1),       // 215: Black Stained Glass
    vec3(0.6, 0.8, 1.0),       // 216: Ice
    vec3(1.0, 1.0, 1.0),       // 217: Glass
    vec3(1.0, 1.0, 1.0),       // 218: Glass Pane
    vec3(1.0, 1.0, 1.0),       // 219
    vec3(0.95, 0.65, 0.2),     // 220: Honey Block
    vec3(0.45, 0.75, 0.35),    // 221: Slime Block
    vec3(1.0, 1.0, 1.0),       // 222
    vec3(1.0, 1.0, 1.0),       // 223
    vec3(1.0, 1.0, 1.0),       // 224
    vec3(1.0, 1.0, 1.0),       // 225
    vec3(1.0, 1.0, 1.0),       // 226
    vec3(1.0, 1.0, 1.0),       // 227
    vec3(1.0, 1.0, 1.0),       // 228
    vec3(1.0, 1.0, 1.0),       // 229
    vec3(1.0, 1.0, 1.0),       // 230
    vec3(1.0, 1.0, 1.0),       // 231
    vec3(1.0, 1.0, 1.0),       // 232
    vec3(1.0, 1.0, 1.0),       // 233
    vec3(1.0, 1.0, 1.0),       // 234
    vec3(1.0, 1.0, 1.0),       // 235
    vec3(1.0, 1.0, 1.0),       // 236
    vec3(1.0, 1.0, 1.0),       // 237
    vec3(1.0, 1.0, 1.0),       // 238
    vec3(1.0, 1.0, 1.0),       // 239
    vec3(1.0, 1.0, 1.0),       // 240
    vec3(1.0, 1.0, 1.0),       // 241
    vec3(1.0, 1.0, 1.0),       // 242
    vec3(1.0, 1.0, 1.0),       // 243
    vec3(1.0, 1.0, 1.0),       // 244
    vec3(1.0, 1.0, 1.0),       // 245
    vec3(1.0, 1.0, 1.0),       // 246
    vec3(1.0, 1.0, 1.0),       // 247
    vec3(1.0, 1.0, 1.0),       // 248
    vec3(1.0, 1.0, 1.0),       // 249
    vec3(1.0, 1.0, 1.0),       // 250
    vec3(1.0, 1.0, 1.0),       // 251
    vec3(1.0, 1.0, 1.0),       // 252
    vec3(1.0, 1.0, 1.0),       // 253
    vec3(0.15, 0.15, 0.15)     // 254: Tinted Glass
);

writeonly uniform image3D floodfill_img;
writeonly uniform image3D floodfill_img_copy;

vec4 GetLightSample(sampler3D lightSampler, ivec3 pos) {
    return texelFetch(lightSampler, pos, 0);
}

//Includes//
#include "/lib/misc/voxelization.glsl"
#include "/lib/util/spaceConversion.glsl"
#include "/lib/lighting/shadowSampling.glsl"

// Convert voxel-grid position to scene space (player-relative)
vec3 VoxelToScene(vec3 voxelPos) {
    return voxelPos - vec3(voxelVolumeSize) * 0.5
           + (floor(cameraPosition) - cameraPosition);
}

// Per-voxel hash for deterministic random ray directions that vary every frame
vec2 ProbeHash(ivec3 pos, int sampleIdx) {
    uint h = uint(pos.x) * 73856093u ^ uint(pos.y) * 19349663u ^ uint(pos.z) * 83492791u
             ^ uint(sampleIdx) * 1234567u ^ uint(frameCounter) * 7919u;
    h ^= h >> 16u; h *= 0x45d9f3bu; h ^= h >> 16u;
    uint h2 = h ^ 0x9e3779b1u;
    h2 ^= h2 >> 16u; h2 *= 0x85ebca6bu; h2 ^= h2 >> 16u;
    return vec2(float(h) / 4294967296.0, float(h2) / 4294967296.0);
}

// Inline DDA trace — Amanatides & Woo (1987).
// Returns voxelID at first hit, 0u if ray exited the voxel volume (sky),
// or 0xFFFFFFFFu if the step budget was exhausted before reaching the boundary (occluded/unknown).
uint TraceDDA(vec3 startPos, vec3 rayDir, float maxSteps, out vec3 hitVoxelPos) {
    hitVoxelPos = startPos;
    vec3 volumeSize = vec3(voxelVolumeSize);

    if (any(lessThan(startPos, vec3(0.0))) || any(greaterThanEqual(startPos, volumeSize)))
        return 0u;

    vec3  stepDir  = sign(rayDir);
    vec3  delta    = 1.0 / max(abs(rayDir), vec3(0.0001));
    ivec3 mapPos   = ivec3(floor(startPos));
    ivec3 istep    = ivec3(stepDir);
    vec3  sideDist = (stepDir * (vec3(mapPos) - startPos) + stepDir * 0.5 + 0.5) * delta;

    vec3  tExit  = (max(stepDir, vec3(0.0)) * volumeSize - startPos)
                   / (abs(rayDir) + vec3(0.0001));
    float exitT  = min(min(tExit.x, tExit.y), tExit.z);
    int   steps  = int(min(maxSteps, exitT * 1.5 + 1.0));

    for (int i = 0; i < steps; i++) {
        if (any(lessThan(mapPos, ivec3(0))) || any(greaterThanEqual(mapPos, ivec3(volumeSize))))
            return 0u;

        uint voxelData = texelFetch(voxel_sampler, mapPos, 0).r;
        if (voxelData > 0u) {
            hitVoxelPos = vec3(mapPos) + 0.5;
            return voxelData;
        }

        if (sideDist.x < sideDist.y) {
            if (sideDist.x < sideDist.z) { sideDist.x += delta.x; mapPos.x += istep.x; }
            else                          { sideDist.z += delta.z; mapPos.z += istep.z; }
        } else {
            if (sideDist.y < sideDist.z) { sideDist.y += delta.y; mapPos.y += istep.y; }
            else                          { sideDist.z += delta.z; mapPos.z += istep.z; }
        }
    }
    // Step budget exhausted before reaching the volume boundary — ray is occluded by geometry,
    // not a sky hit. Sentinel distinguishes this from a genuine volume exit (0u).
    return 0xFFFFFFFFu;
}

// Path-traced IRC probe for a single air voxel.
// Traces N uniform-sphere rays and accumulates: sky, emissive, one-bounce indirect + direct sun.
// Temporally blended against the previous frame for stability.
vec4 GetIRCProbe(ivec3 pos, vec3 voxelCenter) {
    const int N  = 4;
    vec3  accumulated = vec3(0.0);
    float alphaAccum  = 0.0;

    for (int i = 0; i < N; i++) {
        vec2 xi = ProbeHash(pos, i);

        // Uniform sphere sampling
        float cosTheta = 1.0 - 2.0 * xi.x;
        float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
        float phi      = 6.28318530718 * xi.y;
        vec3  rayDir   = vec3(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi));

        vec3 hitVoxelPos;
        uint hitVoxel = TraceDDA(voxelCenter, rayDir, 32.0, hitVoxelPos);

        if (hitVoxel == 0xFFFFFFFFu) {
            // Step budget exhausted — ray is occluded by deep geometry, not a sky hit.
            // Add nothing; prevents sky light from leaking into deep caves.

        } else if (hitVoxel == 0u) {
            // Ray exited the voxel volume — genuine sky hit.
            float skyFactor = max(rayDir.y, 0.0);
            accumulated += ambientColor * skyFactor * 2.0;
            alphaAccum  += skyFactor * 0.5;

        } else if (hitVoxel >= 2u && hitVoxel < 200u) {
            // Emissive block hit
            vec4  emissiveData = GetSpecialBlocklightColor(int(hitVoxel));
            float dist         = max(length(hitVoxelPos - voxelCenter), 0.5);
            float falloff      = 1.0 / (1.0 + dist * dist * 0.02);
            accumulated += emissiveData.rgb * falloff * PT_EMISSIVE_I * 2.0;

        } else {
            // Solid block hit — read IRC from the air voxel on the incoming side of the surface.
            // Reading the solid block's own stored value gives 0 for cave stone (in shadow), which
            // breaks propagation. The adjacent air voxel carries the diffused IRC from the network.
            vec3 adjacentAirPos = hitVoxelPos - rayDir;
            vec3 normSamplePos = clamp(adjacentAirPos / vec3(voxelVolumeSize), vec3(0.001), vec3(0.999));
            vec4 prevIRC;
            if ((frameCounter & 1) == 0) prevIRC = texture(floodfill_sampler,      normSamplePos);
            else                          prevIRC = texture(floodfill_sampler_copy, normSamplePos);
            accumulated += prevIRC.rgb * 0.7;

            vec3  hitScenePos  = VoxelToScene(hitVoxelPos);
            vec3  shadowPos    = GetShadowPos(hitScenePos);
            if (length(shadowPos.xy * 2.0 - 1.0) < 0.95) {
                float shadowSample = texture(shadowtex1, shadowPos).x;
                if (shadowSample > 0.5)
                    accumulated += lightColor * 0.5 * (1.0 - nightFactor * 0.9);
            }
        }
    }

    // Temporal blend: 15% new, 85% old — lower alpha reduces per-frame flicker from probe updates.
    vec3  posOffset = floor(previousCameraPosition) - floor(cameraPosition);
    ivec3 prevPos   = clamp(ivec3(vec3(pos) - posOffset), ivec3(0), voxelVolumeSize - 1);
    vec4  prevFrame;
    if ((frameCounter & 1) == 0) prevFrame = GetLightSample(floodfill_sampler,      prevPos);
    else                          prevFrame = GetLightSample(floodfill_sampler_copy, prevPos);

    const float blendAlpha = 0.15;
    vec3  result = mix(prevFrame.rgb, accumulated / float(N), blendAlpha);
    float alpha  = mix(prevFrame.a,   alphaAccum  / float(N), blendAlpha);

    return vec4(result, alpha);
}

//Program//
void main() {
    ivec3 pos  = ivec3(gl_GlobalInvocationID);
    vec3  posM = vec3(pos) / vec3(voxelVolumeSize);

    vec3  posOffset   = floor(previousCameraPosition) - floor(cameraPosition);
    ivec3 previousPos = clamp(ivec3(vec3(pos) - posOffset), ivec3(0), voxelVolumeSize - 1);

    // --- Optimization: skip voxels behind the player ---
    ivec3 absPosFromCenter = abs(pos - voxelVolumeSize / 2);
    if (absPosFromCenter.x + absPosFromCenter.y + absPosFromCenter.z > 16) {
        #ifdef OPTIMIZATION_ACL_BEHIND_PLAYER
            vec4 viewPos = gbufferProjectionInverse * vec4(0.0, 0.0, 1.0, 1.0);
            viewPos /= viewPos.w;
            vec3 nPlayerPos = normalize(mat3(gbufferModelViewInverse) * viewPos.xyz);
            if (dot(normalize(posM - 0.5), nPlayerPos) < 0.0) {
                vec4 prevVal = ((frameCounter & 1) == 0)
                    ? GetLightSample(floodfill_sampler,      previousPos)
                    : GetLightSample(floodfill_sampler_copy, previousPos);
                if ((frameCounter & 1) == 0) imageStore(floodfill_img_copy, pos, prevVal);
                else                         imageStore(floodfill_img,      pos, prevVal);
                return;
            }
        #endif
    }

    // --- Optimization: half-rate updates ---
    #ifdef OPTIMIZATION_ACL_HALF_RATE_UPDATES
        if ((frameCounter & 1) == 0 && posM.x < 0.5) {
            imageStore(floodfill_img_copy, pos, GetLightSample(floodfill_sampler, previousPos));
            return;
        }
        if ((frameCounter & 1) != 0 && posM.x > 0.5) {
            imageStore(floodfill_img, pos, GetLightSample(floodfill_sampler_copy, previousPos));
            return;
        }
    #endif

    uint voxel = texelFetch(voxel_sampler, pos, 0).r;
    vec4 result = vec4(0.0);

    if (voxel == 1u) {
        // Solid block — reflect direct sun for neighbor IRC sampling
        uint packedColor = texelFetch(voxel_color_sampler, pos, 0).r;
        vec3 blockAlbedo = vec3(0.5);
        if (packedColor != 0u) {
            float r = float(packedColor & 0x3FFu) / 1023.0;
            float g = float((packedColor >> 10) & 0x3FFu) / 1023.0;
            float b = float((packedColor >> 20) & 0x3FFu) / 1023.0;
            blockAlbedo = vec3(r * r, g * g, b * b);
        }

        vec3  scenePos  = VoxelToScene(vec3(pos));
        vec3  shadowPos = GetShadowPos(scenePos);
        bool  inSun     = false;
        if (length(shadowPos.xy * 2.0 - 1.0) < 0.95)
            inSun = texture(shadowtex1, shadowPos).x > 0.5;

        vec3 reflectedLight = vec3(0.0);
        if (inSun)
            reflectedLight = blockAlbedo * lightColor * (1.0 - nightFactor * 0.9);

        result = vec4(reflectedLight, 0.1);

    } else if (voxel >= 2u && voxel < 200u) {
        // Emissive block — inject source radiance
        vec4 color = GetSpecialBlocklightColor(int(voxel));
        color.rgb *= 4.0 * PT_EMISSIVE_I;
        result = vec4(pow(color.rgb, vec3(2.0)), color.a);

    } else {
        // Air or translucent — path-traced IRC probe
        vec3 voxelCenter = vec3(pos) + 0.5;
        result = GetIRCProbe(pos, voxelCenter);

        if (voxel >= 200u) {
            vec3 tint  = specialTintColor[min(voxel - 200u, uint(specialTintColor.length()) - 1u)];
            result.rgb *= tint;
        }
    }

    if ((frameCounter & 1) == 0) imageStore(floodfill_img_copy, pos, result);
    else                         imageStore(floodfill_img,      pos, result);
}

#else
// Fallback: minimal compute shader when colored lighting is disabled
#ifdef SHADOWCOMP
layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);
void main() {}
#endif

#endif
