#ifndef GI_GLSL
#define GI_GLSL

#include "/lib/pt/rand.glsl"
#include "/lib/pt/ddaTrace.glsl"
// ao.glsl provides cosHemisphereDir, buildTBN and PI
#include "/lib/pt/ao.glsl"
// skyLut.glsl provides sampleSkyLut (directional sky from colortex13)
#include "/lib/pt/skyLut.glsl"

// Result of a GI ray traversal through the voxel grid.
struct VoxelHit {
    bool  hit;
    vec3  pos;       // world-space entry point of the hit voxel
    vec3  normal;    // surface normal of the face the ray entered through
    uint  category;
    vec3  albedo;
};

// DDA that returns hit position, face normal and voxel contents (for GI gathering).
VoxelHit traceVoxelGI(usampler2D atlas, vec3 gridOrigin, vec3 worldPos, vec3 rayDir, float maxDist) {
    VoxelHit r;
    r.hit = false; r.pos = worldPos; r.normal = vec3(0.0); r.category = VOXEL_AIR; r.albedo = vec3(0.0);

    vec3  localPos = worldPos - gridOrigin;
    ivec3 vox      = ivec3(floor(localPos));
    ivec3 stepDir  = ivec3(sign(rayDir));
    vec3  tDelta   = 1.0 / max(abs(rayDir), vec3(1e-8));

    vec3 tMax;
    for(int i=0; i<3; ++i) {
        if (rayDir[i] > 0.0) tMax[i] = (floor(localPos[i]) + 1.0 - localPos[i]) * tDelta[i];
        else if (rayDir[i] < 0.0) tMax[i] = (localPos[i] - floor(localPos[i])) * tDelta[i];
        else tMax[i] = 1e38;
    }

    vec3  lastMask = vec3(0.0);
    float tEntry   = 0.0;
    for (int i = 0; i < 80; i++) {
        if (tEntry >= maxDist) break;
        if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(VOXEL_GRID_SIZE)))) break;

        uvec4 v = texelFetch(atlas, voxelCoordToAtlas(vox), 0);
        if (v.r != VOXEL_AIR && i > 0) {
            r.hit      = true;
            r.category = v.r;
            r.albedo   = vec3(v.gba) / 255.0;
            r.pos      = worldPos + rayDir * tEntry;
            r.normal   = -vec3(stepDir) * lastMask; // face we entered through
            return r;
        }

        bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
        lastMask = vec3(mask);
        tEntry   = min(tMax.x, min(tMax.y, tMax.z));
        tMax    += vec3(mask) * tDelta;
        vox     += stepDir * ivec3(mask);
    }
    r.pos = worldPos + rayDir * tEntry;
    return r;
}

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

// Trace ONE GI ray and return the incoming radiance from that direction.
vec3 giRayRadiance(
    usampler2D atlas, vec3 camPos, vec3 gridOrigin,
    vec3 origin, vec3 dir, vec3 sunDir, vec3 sunColor, vec3 skyColor, sampler2D skyLut,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV,
    out vec3 hitPos, out vec3 hitNormal, out vec3 hitAlbedo, out bool wasHit, out uint hitCategory,
    float skyLightmap
) {
    VoxelHit h = traceVoxelGI(atlas, gridOrigin, origin, dir, float(GI_RADIUS));

    // Smooth the lightmap to avoid harsh transitions in the PT
    float skyOcc = max(skyLightmap, 0.0);
    //skyOcc = sqrt(skyOcc); 

    if (h.hit) {
        wasHit      = true;
        hitCategory = h.category;
        vec3 rad = vec3(0.0);

        if (h.category == VOXEL_EMISSIVE) {
            hitPos    = h.pos;
            hitNormal = h.normal;
            hitAlbedo = vec3(0.0);
            return h.albedo * float(GI_EMISSION);
        }

        hitAlbedo = h.albedo;

        float ndl = max(dot(h.normal, sunDir), 0.0);
        if (ndl > 0.0) {
            bool occluded = traceVoxelRay(atlas, h.pos + h.normal * 0.1, sunDir, float(GI_RADIUS), camPos, depthtex0, gbufferProj, gbufferMV);
            if (!occluded) rad += h.albedo * sunColor * ndl * skyOcc;
        }

        // Sky probe: shoot one DDA ray from the bounce surface toward the sky.
        vec3  skyProbeRaw    = h.normal + vec3(0.0, 1.0, 0.0);
        float skyProbeLenSq  = dot(skyProbeRaw, skyProbeRaw);
        if (skyProbeLenSq > 1e-4) {
            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
            float lambertWeight = dot(h.normal, skyProbeDir);
            bool  skyEscape     = !traceVoxelRay(atlas, h.pos + h.normal * 0.15, skyProbeDir, float(GI_SKY_PROBE_DIST), camPos, depthtex0, gbufferProj, gbufferMV);
            #ifdef GI_SKY_DIRECTIONAL
                vec3 probeSky = sampleSkyLut(skyLut, skyProbeDir) * GI_SKY_BRIGHTNESS;
            #else
                vec3 probeSky = skyColor;
            #endif
            if (skyEscape) rad += h.albedo * probeSky * lambertWeight * GI_BOUNCE_SKY * skyOcc;
        }

        hitPos    = h.pos;
        hitNormal = h.normal;
        return rad;
    }
    
    // --- Hybrid Screen-Space Fallback ---
    // If the ray escapes the voxel bounds, seamlessly trace it against the screen-space
    // depth buffer to pick up infinite-distance geometry (mountains, trees outside radius).
    vec3 ssrtHitNormal;
    if (screenSpaceRayTrace(h.pos, dir, 256.0, camPos, gbufferProj, gbufferMV, depthtex0, h.albedo, ssrtHitNormal, hitPos)) {
        wasHit = true;
        hitCategory = VOXEL_OPAQUE;
        hitNormal = ssrtHitNormal;
        hitAlbedo = vec3(0.0);
        
        // Approximate the hit UV to sample the radiance buffer
        vec4 clipEnd = gbufferProj * (gbufferMV * vec4(hitPos - camPos, 1.0));
        vec3 ndcEnd = clipEnd.xyz / clipEnd.w;
        vec2 hitUV = ndcEnd.xy * 0.5 + 0.5;
        
        // Sample previous frame's lit scene for multi-bounce GI
        vec3 rad = textureLod(colortex5, hitUV, 0.0).rgb;
        return rad;
    }

    wasHit      = false;
    hitCategory = VOXEL_AIR;
    hitPos      = h.pos;
    hitNormal   = -dir; 
    hitAlbedo   = vec3(0.0);
    #ifdef GI_SKY_DIRECTIONAL
        vec3 skyRad = sampleSkyLut(skyLut, dir) * GI_SKY_BRIGHTNESS * skyOcc;
    #else
        vec3 skyRad = skyColor * skyOcc;
    #endif
    // Modulate the escaped sky light so downward rays return dark (simulating ground) 
    // rather than glowing brightly, keeping NdotL consistent outside the voxel grid.
    return skyRad * smoothstep(-0.2, 0.4, dir.y);
}

// Multi-sample diffuse GI for the non-ReSTIR path.
vec3 computeGI(
    usampler2D atlas, vec3 worldPos, vec3 normal, inout uint seed, vec3 camPos,
    vec3 sunDir, vec3 sunColor, vec3 skyColor, sampler2D skyLut, float skyLightmap,
    sampler2D depthtex0, sampler2D colortex5, sampler2D colortex1, mat4 gbufferProj, mat4 gbufferMV
) {
    vec3 gridOrigin = floor(camPos) - vec3(VOXEL_RADIUS);
    vec3 origin = worldPos + normal * 0.1;
    vec3 acc    = vec3(0.0);

    for (int i = 0; i < GI_SAMPLES; i++) {
        vec3 dir = cosHemisphereDir(normal, randFloat(seed), randFloat(seed));
        vec3 hitPos; vec3 hitNormal; vec3 hitAlbedo; bool wasHit; uint hitCat;
        acc += giRayRadiance(atlas, camPos, gridOrigin, origin, dir, sunDir, sunColor, skyColor, skyLut, depthtex0, colortex5, colortex1, gbufferProj, gbufferMV, hitPos, hitNormal, hitAlbedo, wasHit, hitCat, skyLightmap);
    }
    return acc / float(GI_SAMPLES);
}

#endif
