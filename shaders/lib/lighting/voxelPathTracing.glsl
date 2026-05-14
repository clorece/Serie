#ifndef VOXEL_PATH_TRACING_GLSL
#define VOXEL_PATH_TRACING_GLSL

#include "/lib/misc/voxelization.glsl"

const float PHI = 1.618033988749895;
const float PHI_INV = 0.618033988749895;
const float PHI2_INV = 0.38196601125010515;

float rand(float dither, int i) {
    return fract(dither + float(i) * 0.61803398875);
}

float randWithSeed(float dither, int seed) {
    return fract(dither * 12.9898 + float(seed) * 78.233);
}

vec2 R2Sequence(int n, int seed) {
    float u = fract(float(n) * PHI_INV + fract(float(seed) * PHI_INV));
    float v = fract(float(n) * PHI2_INV + fract(float(seed) * PHI2_INV));
    return vec2(u, v);
}

vec2 CranleyPattersonRotation(vec2 sample, float dither) {
    vec2 shift = vec2(
        fract(dither * 12.9898),
        fract(dither * 78.233)
    );
    return fract(sample + shift);
}

vec3 SampleHemisphereCosine(vec2 Xi) {
    float theta = 6.28318530718 * Xi.y;
    float r = sqrt(Xi.x);
    
    vec3 hemi = vec3(
        r * cos(theta),
        r * sin(theta),
        sqrt(1.0 - Xi.x)
    );
    
    return hemi;
}

void BuildOrthonormalBasis(vec3 normal, out vec3 tangent, out vec3 bitangent) {
    if (abs(normal.y) < 0.999) {
        tangent = normalize(cross(vec3(0.0, 1.0, 0.0), normal));
    } else {
        tangent = normalize(cross(vec3(1.0, 0.0, 0.0), normal));
    }
    bitangent = cross(normal, tangent);
}

vec3 RayDirection(vec3 normal, float dither, int i) {
    vec2 Xi = R2Sequence(i, int(dither * 7919.0));
        Xi = CranleyPattersonRotation(Xi, dither);
    
    vec3 hemiDir = SampleHemisphereCosine(Xi);
    
    vec3 T, B;
    BuildOrthonormalBasis(normal, T, B);

    return normalize(T * hemiDir.x + B * hemiDir.y + normal * hemiDir.z);
}

#if COLORED_LIGHTING_INTERNAL > 0
    vec3 GetVoxelSkylight(vec3 scenePos, vec3 normal) {
        vec3 voxelPos = SceneToVoxel(scenePos);
        vec3 volumeSize = vec3(voxelVolumeSize);
        
        // Check if inside voxel volume
        if (!CheckInsideVoxelVolume(voxelPos)) {
            return vec3(1.0);
        }

        vec3 normalizedPos = voxelPos / volumeSize;
        vec4 lightVolume = GetLightVolume(normalizedPos);

        vec3 offsetPos = voxelPos + normal * 2.0;
        offsetPos = clamp(offsetPos, vec3(0.5), volumeSize - 0.5);
        vec3 normalizedOffsetPos = offsetPos / volumeSize;
        vec4 lightVolumeOffset = GetLightVolume(normalizedOffsetPos);
        
        float skyExposure = max(lightVolume.a, lightVolumeOffset.a);

        vec3 upSamplePos = voxelPos + vec3(0.0, 4.0, 0.0);
        if (all(greaterThan(upSamplePos, vec3(0.5))) && all(lessThan(upSamplePos, volumeSize - 0.5))) {
            uint aboveVoxel = texelFetch(voxel_sampler, ivec3(upSamplePos), 0).r;
            if (aboveVoxel >= 1u && aboveVoxel < 200u) {
                skyExposure *= 0.3;
            }
        }
        
        return vec3(skyExposure);
    }
    
    float GetVoxelAO(vec3 scenePos, vec3 normal, float dither) {
        vec3 voxelPos = SceneToVoxel(scenePos);
        vec3 volumeSize = vec3(voxelVolumeSize);

        if (!CheckInsideVoxelVolume(voxelPos)) {
            return 0.0;
        }
        
        float occlusion = 0.0;
        float totalWeight = 0.0;
        
        const int VOXEL_AO_SAMPLES = 8;
        const float VOXEL_AO_RADIUS = 1.0;
        
        vec3 tangent, bitangent;
        BuildOrthonormalBasis(normal, tangent, bitangent);
        
        for (int i = 0; i < VOXEL_AO_SAMPLES; i++) {
            vec2 Xi = R2Sequence(i, int(dither * 1000.0));
            Xi = CranleyPattersonRotation(Xi, dither);
            vec3 sampleDir = SampleHemisphereCosine(Xi);
            sampleDir = normalize(tangent * sampleDir.x + bitangent * sampleDir.y + normal * sampleDir.z);

            for (float dist = 1.0; dist <= VOXEL_AO_RADIUS; dist += 1.0) {
                vec3 samplePos = voxelPos + sampleDir * dist;
                
                if (any(lessThan(samplePos, vec3(0.5))) || any(greaterThanEqual(samplePos, volumeSize - 0.5))) {
                    continue;
                }
                
                uint voxelData = texelFetch(voxel_sampler, ivec3(samplePos), 0).r;

                if (voxelData == 1u) {
                    float weight = 1.0 - (dist / VOXEL_AO_RADIUS);
                    weight = weight * weight;
                    occlusion += weight;
                    totalWeight += weight;
                    break;
                }
                totalWeight += (1.0 - dist / VOXEL_AO_RADIUS) * 0.5;
            }
        }
        
        if (totalWeight > 0.0) {
            occlusion /= totalWeight;
        }
        
        return clamp(occlusion, 0.0, 1.0);
    }
    

    struct VoxelRayResult {
        bool hitSky;        // Ray escaped to sky
        bool hitSolid;      // Ray hit solid geometry
        bool hitEmissive;   // Ray hit an emissive block
        vec3 light;         // Accumulated light from direct emissive discovery
        vec3 emissiveColor; // Color of the emissive block hit (if any)
        float distance;     // Distance traveled
        uint hitVoxelID;    // Voxel ID of the block hit
    };
    
    VoxelRayResult TraceVoxelRay(vec3 scenePos, vec3 rayDir, float maxDist, float dither) {
        VoxelRayResult result;
        result.hitSky = false;
        result.hitSolid = false;
        result.hitEmissive = false;
        result.light = vec3(0.0);
        result.emissiveColor = vec3(0.0);
        result.distance = 0.0;
        result.hitVoxelID = 0u;
        
        vec3 volumeSize = vec3(voxelVolumeSize);
        vec3 voxelPos = SceneToVoxel(scenePos);
        
        if (!CheckInsideVoxelVolume(voxelPos)) {
            result.hitSky = true;
            return result;
        }
        
        vec3 rayDirSign = sign(rayDir);
        vec3 rayDirAbs = abs(rayDir);
        vec3 deltaDist = 1.0 / max(rayDirAbs, vec3(0.0001));
        
        ivec3 mapPos = ivec3(floor(voxelPos));
        ivec3 step = ivec3(rayDirSign);
        
        vec3 sideDist = (rayDirSign * (vec3(mapPos) - voxelPos) + rayDirSign * 0.5 + 0.5) * deltaDist;
        
        int maxSteps = int(min(maxDist * 1.5, 128.0));
        float distTraveled = 0.0;
        
        for (int i = 0; i < maxSteps; i++) {
            // Check bounds
            if (any(lessThan(mapPos, ivec3(0))) || any(greaterThanEqual(mapPos, ivec3(volumeSize)))) {
                result.hitSky = true;
                break;
            }
            
            uint voxelData = texelFetch(voxel_sampler, mapPos, 0).r;
            
            // Hit solid non-emissive block
            if (voxelData == 1u) {
                result.hitSolid = true;
                result.distance = distTraveled;
                break;
            }
            
            // Hit emissive block (IDs 2-199)
            if (voxelData >= 2u && voxelData < 200u) {
                vec4 emissiveData = GetSpecialBlocklightColor(int(voxelData));
                float emissiveDist = max(distTraveled, 0.5);
                // Inverse-square falloff with minimum floor to prevent extreme values
                float falloff = 1.0 / (1.0 + emissiveDist * emissiveDist * 0.05);
                result.light += emissiveData.rgb * falloff * PT_EMISSIVE_I;
                result.emissiveColor = emissiveData.rgb;
                result.hitEmissive = true;
                result.hitVoxelID = voxelData;
                result.hitSolid = true; // Emissive blocks are solid for ray termination
                result.distance = distTraveled;
                break;
            }
            
            // Translucent blocks (IDs 200+): tint light passing through
            if (voxelData >= 200u && voxelData <= 254u) {
                // Light passing through colored glass gets tinted
                // (absorbed but ray continues)
            }
            
            // DDA step
            if (sideDist.x < sideDist.y) {
                if (sideDist.x < sideDist.z) {
                    distTraveled = sideDist.x;
                    sideDist.x += deltaDist.x;
                    mapPos.x += step.x;
                } else {
                    distTraveled = sideDist.z;
                    sideDist.z += deltaDist.z;
                    mapPos.z += step.z;
                }
            } else {
                if (sideDist.y < sideDist.z) {
                    distTraveled = sideDist.y;
                    sideDist.y += deltaDist.y;
                    mapPos.y += step.y;
                } else {
                    distTraveled = sideDist.z;
                    sideDist.z += deltaDist.z;
                    mapPos.z += step.z;
                }
            }
            
            result.distance = distTraveled;
        }
        
        return result;
    }
    
    vec3 GetVoxelAlbedo(vec3 scenePos) {
        vec3 voxelPos = SceneToVoxel(scenePos);
        
        if (!CheckInsideVoxelVolume(voxelPos)) return vec3(0.5);

        uint packedColor = texelFetch(voxel_color_sampler, ivec3(voxelPos), 0).r;
        
        if (packedColor == 0u) return vec3(0.5); // Fallback
        
        float r = float(packedColor & 0xFFu) / 255.0;
        float g = float((packedColor >> 8) & 0xFFu) / 255.0;
        float b = float((packedColor >> 16) & 0xFFu) / 255.0;
        
        return vec3(r, g, b);
    }
    
    struct VoxelHitResult {
        bool hit;
        bool isEmissive;    // Whether the hit block is an emissive source
        vec3 hitPos;
        vec3 hitNormal;
        uint voxelID;
        vec3 light;         // Direct light at this hit (emissive color if emissive)
        vec3 emissiveColor; // Raw emissive color for the block
    };
    
    VoxelHitResult TraceVoxelHit(vec3 scenePos, vec3 rayDir, float maxDist) {
        VoxelHitResult result;
        result.hit = false;
        result.isEmissive = false;
        result.hitPos = vec3(0.0);
        result.hitNormal = vec3(0.0);
        result.voxelID = 0u;
        result.light = vec3(0.0);
        result.emissiveColor = vec3(0.0);
        
        vec3 volumeSize = vec3(voxelVolumeSize);
        vec3 voxelPos = SceneToVoxel(scenePos);
        
        // Check if starting position is inside volume
        if (!CheckInsideVoxelVolume(voxelPos)) {
            return result;
        }
        
        vec3 rayDirSign = sign(rayDir);
        vec3 rayDirAbs = abs(rayDir);
        vec3 deltaDist = 1.0 / max(rayDirAbs, vec3(0.0001));
        
        ivec3 mapPos = ivec3(floor(voxelPos));
        ivec3 step = ivec3(rayDirSign);
        
        vec3 sideDist = (rayDirSign * (vec3(mapPos) - voxelPos) + rayDirSign * 0.5 + 0.5) * deltaDist;
        
        int maxSteps = int(min(maxDist, 256.0));
        vec3 mask = vec3(0.0);
        
        for (int i = 0; i < maxSteps; i++) {
            if (any(lessThan(mapPos, ivec3(0))) || any(greaterThanEqual(mapPos, ivec3(volumeSize)))) {
                break;
            }
            
            uint voxelData = texelFetch(voxel_sampler, mapPos, 0).r;

            if (voxelData > 0u) {
                result.hit = true;
                result.voxelID = voxelData;
                result.hitNormal = -vec3(step) * mask;
                
                // Detect emissive blocks (IDs 2-199)
                if (voxelData >= 2u && voxelData < 200u) {
                    result.isEmissive = true;
                    vec4 emissiveData = GetSpecialBlocklightColor(int(voxelData));
                    result.emissiveColor = emissiveData.rgb;
                    result.light = emissiveData.rgb * PT_EMISSIVE_I;
                }

                float dist = 0.0;
                if (mask.x > 0.5) dist = (sideDist.x - deltaDist.x);
                else if (mask.y > 0.5) dist = (sideDist.y - deltaDist.y);
                else dist = (sideDist.z - deltaDist.z);
                
                result.hitPos = scenePos + rayDir * dist;
                result.hitPos += result.hitNormal * 0.001;
                
                break;
            }
            
            mask = vec3(0.0);
            if (sideDist.x < sideDist.y) {
                if (sideDist.x < sideDist.z) {
                    sideDist.x += deltaDist.x;
                    mapPos.x += step.x;
                    mask.x = 1.0;
                } else {
                    sideDist.z += deltaDist.z;
                    mapPos.z += step.z;
                    mask.z = 1.0;
                }
            } else {
                if (sideDist.y < sideDist.z) {
                    sideDist.y += deltaDist.y;
                    mapPos.y += step.y;
                    mask.y = 1.0;
                } else {
                    sideDist.z += deltaDist.z;
                    mapPos.z += step.z;
                    mask.z = 1.0;
                }
            }
        }
        
        return result;
    }

    bool TraceVoxelShadow(vec3 scenePos, vec3 rayDir, float maxDist, out vec3 absorption) {
        absorption = vec3(1.0);
        
        vec3 volumeSize = vec3(voxelVolumeSize);
        vec3 voxelPos = SceneToVoxel(scenePos);
        
        if (!CheckInsideVoxelVolume(voxelPos)) {
            return false;
        }
        
        vec3 stepSizes = 1.0 / abs(rayDir);
        vec3 stepDir = sign(rayDir);
        vec3 nextDist = (stepDir * 0.5 + 0.5 - fract(voxelPos)) / rayDir;
        
        ivec3 mapPos = ivec3(floor(voxelPos));
        int maxSteps = int(min(maxDist, 64.0));
        
        for (int i = 0; i < maxSteps; i++) {
            float closestDist = min(min(nextDist.x, nextDist.y), nextDist.z);
            vec3 stepAxis = vec3(lessThanEqual(nextDist, vec3(closestDist)));
            mapPos += ivec3(stepAxis * stepDir);
            nextDist += stepSizes * stepAxis;
            
            if (any(lessThan(mapPos, ivec3(0))) || any(greaterThanEqual(mapPos, ivec3(volumeSize)))) {
                break;
            }
            
            uint voxelData = texelFetch(voxel_sampler, mapPos, 0).r;
            
            // solid block hit
            if (voxelData == 1u) {
                return true;
            }
            
            // translucent blocks (glass) - attenuate and continue
            if (voxelData >= 200u && voxelData <= 218u) {
                absorption *= 0.85;
            }
        }
        
        return false;
    }
    
    bool TraceVoxelShadow(vec3 scenePos, vec3 rayDir, float maxDist) {
        vec3 unused;
        return TraceVoxelShadow(scenePos, rayDir, maxDist, unused);
    }
#endif

#endif // VOXEL_PATH_TRACING_GLSL
