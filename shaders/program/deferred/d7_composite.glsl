// ============================================================================
//  d7_composite : final scene lighting
// ----------------------------------------------------------------------------
//  Combines raw albedo (colortex0, untouched since the gbuffers) with direct
//  sunlight (shadows + contact shadows) and the denoised indirect term
//  (colortex6, produced by d0_restir -> d1..d6 denoise). Writes colortex0.
//  Sky pixels are left as-is here and replaced by d8_fog_sky.
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
uniform vec3 moonPosition;
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

const int shadowMapResolution = SHADOW_RESOLUTION;
const float shadowDistance = 160.0;
const float sunPathRotation = -40.0; // [10.0 20.0 30.0 40.0 50.0 60.0]
const float ambientOcclusionLevel = 0.5;
const float ambientStrength = 0.3;
const vec3 torchColor = vec3(0.9922, 0.6471, 0.1922);

const bool shadowHardwareFiltering = false;
const bool shadowtex1Mipmap = false;
const bool shadowtex1Nearest = false;

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;

uniform float rainStrength;
uniform vec3 cameraPosition;
uniform sampler2D colortex0;   // raw albedo
uniform sampler2D colortex1;   // view normals
uniform sampler2D colortex2;   // lightmap
uniform sampler2D colortex3;   // denoised indirect (.rgb)
uniform sampler2D colortex9;   // linear depth (.r) + luminance moments (.g, .b) + SSCS (.a)
uniform sampler2D colortex12;  // GTAO: bent normal (.xy oct) + linear depth (.z) + AO (.w)
uniform sampler2D colortex4;   // material
uniform sampler2D depthtex0;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;

float depth0 = texture(depthtex0, texCoord).r;
vec3 material = texture(colortex4, texCoord).rgb;
vec3 normal = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
vec3 lightmap = texture(colortex2, texCoord).rgb;

vec3 clipSpace;

#include "/lib/util/dither.glsl"
#include "/lib/util/positions.glsl"

vec3 getLightmap(vec3 l) {
    l.x = 1.0 * pow(l.x, 5.06);
    vec3 torchLighting = l.x * torchColor;
    vec3 skyLighting = l.y * ambientColor;
    return torchLighting + skyLighting;
}

float getNdotL(vec3 n, vec3 l) {
    float dotNL = dot(n, l);

    // Foliage (1.0: leaves, 1.1: grass, flowers, crops, vines)
    // Disables directional shading for a flat, translucent look.
    //if (material.x > 0.9 && material.x < 1.2) {
        //return max(dotNL, 0.0) * lightScatter * viewScatter;
    //    return 0.1;
    //}

    // Opaque Disney (Burley) Diffuse
    // Adds a retro-reflective peak and smoother falloff based on surface roughness.
    // We use a fixed medium roughness (0.5) for general block cohesion.
    float roughness = 0.5;
    vec3 v = normalize(-getFragPosition().xyz);
    vec3 h = normalize(l + v);
    float dotNV = clamp(dot(n, v), 1e-5, 1.0);
    float dotLH = clamp(dot(l, h), 0.0, 1.0);

    float fd90 = 0.5 + 2.0 * dotLH * dotLH * roughness;
    float lightScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - clamp(dotNL, 0.0, 1.0), 5.0);
    float viewScatter  = 1.0 + (fd90 - 1.0) * pow(1.0 - dotNV, 5.0);

    return max(dotNL, 0.0) * lightScatter * viewScatter;
}

float getInfiniteShadows(vec3 viewPos, vec3 lightDir, float dither, vec3 normalView) {
    float viewDist = length(viewPos);
    
    // Adaptive Ray March settings
    float rayLength = mix(0.8, 128.0, clamp(viewDist / 512.0, 0.0, 1.0));
    int steps = int(mix(16.0, 48.0, clamp(viewDist / 512.0, 0.0, 1.0))); // Increased min steps to 16
    
    vec3 stepVec = lightDir * (rayLength / float(steps));
    float stepLen = length(stepVec);

    // Drastically reduced normal bias so the ray starts closer to the surface
    float nBias = mix(0.005, 0.2, clamp(viewDist / 512.0, 0.0, 1.0));
    vec3 rayPos = viewPos + normalView * nBias + stepVec * dither;

    float sscs = 1.0;
    
    // Dynamic thickness scales with the step length to prevent missing thin objects
    float thickness = max(stepLen * 2.0, mix(0.15, 8.0, clamp(viewDist / 512.0, 0.0, 1.0)));
    
    // Adaptive depth tolerance prevents grazing rays from failing intersection
    float distTolerance = 0.002 + abs(viewPos.z) * 0.001;

    for (int i = 0; i < steps; i++) {
        rayPos += stepVec;

        vec4 clipPos = gbufferProjection * vec4(rayPos, 1.0);
        vec3 ndcPos = clipPos.xyz / clipPos.w;
        vec2 uv = ndcPos.xy * 0.5 + 0.5;

        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

        float depth = textureLod(depthtex0, uv, 0.0).r;
        if (depth >= 1.0) break;

        vec4 sampleClip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        vec4 sampleView = gbufferProjectionInverse * sampleClip;
        float sampleZ = sampleView.z / sampleView.w;

        // Depth test with adaptive tolerance and thickness
        float zDiff = sampleZ - rayPos.z;
        if (zDiff > distTolerance && zDiff < thickness) {
            sscs = smoothstep(0.6, 1.0, float(i) / float(steps));
            break;
        }
    }

    // Fade the effect out near the screen edges to prevent "shadow pop-in"
    vec4 startClip = gbufferProjection * vec4(viewPos, 1.0);
    vec2 startUV = (startClip.xy / startClip.w) * 0.5 + 0.5;
    float edgeFade = smoothstep(0.0, 0.1, min(min(startUV.x, 1.0 - startUV.x), min(startUV.y, 1.0 - startUV.y)));

    return mix(1.0, sscs, edgeFade);
}

#include "/lib/fragment/shadows.glsl"

#ifdef AO_DENOISE
// Depth-aware bilateral filter over the GTAO buffer (colortex12). The horizon march uses few
// steps + per-pixel dither, so after temporal accumulation some high-frequency noise / stepping
// remains; this resolves it spatially without bleeding across depth edges. colortex12 stores
// .xy = oct bent normal, .z = linear depth, .w = AO.
vec4 sampleAOFiltered(vec2 uv) {
    vec4  c  = texture(colortex12, uv);
    float cd = c.z;                          // center linear depth
    if (cd <= 0.0 || cd > 1e4) return c;     // sky / invalid: leave as-is

    vec3  cBent   = octDecodeNormal(c.xy);
    float aoSum   = c.w;
    vec3  bentSum = cBent;
    float wSum    = 1.0;

    for (int y = -AO_DENOISE_RADIUS; y <= AO_DENOISE_RADIUS; y++) {
        for (int x = -AO_DENOISE_RADIUS; x <= AO_DENOISE_RADIUS; x++) {
            if (x == 0 && y == 0) continue;
            vec4 sm = texture(colortex12, uv + vec2(x, y) * texelSize * 2.0);
            if (sm.z <= 0.0 || sm.z > 1e4) continue; // skip sky / invalid neighbours
            vec3 nBent = octDecodeNormal(sm.xy);
            // edge stops: linear depth + bent-normal similarity, plus a spatial gaussian.
            float dw = exp2(-abs(sm.z - cd) / max(0.04 * cd + 0.05, 1e-3) * 6.0);
            float nw = pow(max(dot(cBent, nBent), 0.0), 8.0);
            float gw = exp2(-float(x * x + y * y) * 0.5);
            float w  = dw * nw * gw;
            aoSum   += sm.w * w;
            bentSum += nBent * w;
            wSum    += w;
        }
    }
    return vec4(octEncodeNormal(normalize(bentSum)), cd, aoSum / wSum);
}
#endif

#ifdef PT_DEBUG_VOXELS
#include "/lib/pt/voxelData.glsl"
#endif
uniform usampler2D colortex7;


#include "/lib/util/positions.glsl"
#include "/lib/pt/ddaTrace.glsl"

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord).rgb;

    #ifdef SSPT_DEBUG
        // SSPT-only view: gather the screen-space path tracer in isolation (no voxel
        // fallback, no ReSTIR, no denoise, no albedo).
        //   MODE 0 (radiance): bright = SSPT found bounce light; black = miss OR dark hit.
        //   MODE 1 (coverage): GREEN = fraction of rays that HIT anything (ignores how
        //                      dark the hit was), RED tint = all rays missed -> separates
        //                      "rays escaped to sky" from "hit a dark surface".
        if (depth0 < 1.0) {
            vec3 viewPos = convertScreenSpaceToWorldSpace(unjitteredTexCoord, depth0); // view space
            vec3 originV = viewPos + normal * 0.15;                 // colortex1 is view normals
            vec2 cj      = texCoord - unjitteredTexCoord;           // TAA jitter (buffer = geom + cj)
            uint seed    = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

            vec3  acc  = vec3(0.0);
            float hits = 0.0;
            for (int i = 0; i < SSPT_DEBUG_SAMPLES; i++) {
                vec3 dir = sspt_dbgHemisphere(normal, randFloat(seed), randFloat(seed));
                vec2 uvh; float rawh;
                if (traceScreenSpace(depthtex0, gbufferProjection, originV, dir,
                                     float(SSPT_DIST), SSPT_STEPS, SSPT_THICKNESS,
                                     randFloat(seed), cj, uvh, rawh)) {
                    acc += texture(colortex5, uvh + cj).rgb;
                    hits += 1.0;
                }
            }
            float frac = hits / float(SSPT_DEBUG_SAMPLES);
            #if SSPT_DEBUG == 1
                gl_FragData[0] = vec4(1.0 - frac, frac, 0.0, 1.0);     // red=miss, green=hit
            #else
                gl_FragData[0] = vec4(acc / float(SSPT_DEBUG_SAMPLES), 1.0);
            #endif
        } else {
            gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0);
        }
        return;
    #endif

    // ---- Direct sunlight ----
    float diffuse = getNdotL(normal, lightVector);
    float skyOcc = sqrt(lightmap.y); // Loosened modulation: allows leakage until nearly 0 lightmap
    
    vec3 directShadow = getShadow();
    if (depth0 < 1.0) {
        float ditherVal = interleavedGradientNoise(floor(gl_FragCoord.xy), frameCounter);
        vec3 viewPos = getFragPosition().xyz;
        // Combine standard shadow map with infinite screen-space shadows.
        // This provides micro-contact detail and infinite-distance mountain shadows.
        directShadow *= getInfiniteShadows(viewPos, lightVector, ditherVal, normal);
    }
    vec3 direct = diffuse * lightColor * directShadow * (1.0 - (rainStrength * 0.75)) * skyOcc;

    // ---- Screen-space contact AO (GTAO, from d5_gtao) ----
    // The voxel GI already captures macro occlusion; this adds the sub-voxel contact
    // darkening the 1-block grid cannot resolve. Multiplied onto the indirect term only
    // (with a small radius) so it complements rather than double-counts the GI.
    float aoTerm = 1.0;
    vec3  bentNormalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    #ifdef AO_GTAO
        if (depth0 < 1.0) {
            #ifdef AO_DENOISE
                vec4 aoData = sampleAOFiltered(texCoord);
            #else
                vec4 aoData = texture(colortex12, texCoord);
            #endif
            aoTerm = aoData.w;
            #ifdef AO_BENT_NORMAL
                bentNormalWorld = octDecodeNormal(aoData.xy);
            #endif
        }
    #endif

    // ---- Indirect (denoised) ----
    vec3 indirect;
    #if defined(VOXEL_GI)
        vec3 gi = texture(colortex3, texCoord).rgb;
        #ifdef AO_GTAO
            #ifdef LIGHTING_AO_FULL
                gi *= aoTerm;                                       // ambient occlusion fully occludes the ambient term
            #else
                gi *= mix(1.0, aoTerm, float(AO_GI_STRENGTH) / 100.0);
            #endif
        #endif
        
        // Prevent skylight illumination from the path tracer from illuminating sunlit terrain
        gi *= vec3(1.0) - (directShadow * max(dot(normal, lightVector), 0.0));

        indirect = gi;
    #elif defined(AO_GTAO)
        // GI off, GTAO on: ambient from lightmap, occluded by contact AO.
        #ifdef AO_BENT_NORMAL
            float skyFacing  = clamp(bentNormalWorld.y * 0.5 + 0.5, 0.0, 1.0);
            vec3  torchLight = pow(clamp(lightmap.x, 0.0, 1.0), 5.06) * torchColor;
            vec3  skyLight   = ambientColor * lightmap.y * skyFacing;
            indirect = (torchLight + skyLight + vec3(ambientStrength)) * aoTerm;
        #else
            indirect = (getLightmap(lightmap) + vec3(ambientStrength)) * aoTerm;
        #endif
    #elif defined(VOXEL_AO)
        float ao = texture(colortex3, texCoord).r;
        float aoFactor = mix(1.0, ao, float(AO_STRENGTH) / 100.0);
        indirect = (getLightmap(lightmap) + vec3(ambientStrength)) * aoFactor;
    #else
        indirect = getLightmap(lightmap) + vec3(ambientStrength);
    #endif

    // ---- Optional contact AO on direct sunlight ----
    #if defined(AO_GTAO) && (AO_DIRECT_STRENGTH > 0)
        direct *= mix(1.0, aoTerm, float(AO_DIRECT_STRENGTH) / 100.0);
    #endif

    // Total irradiance = direct sun + indirect fill, weighted to set the sun-vs-ambient
    // contrast ratio, then modulated by albedo. Keeping ambient from matching the sun is
    // what stops flat shading.
    direct   *= float(LIGHTING_DIRECT)   / 100.0;
    indirect *= float(LIGHTING_INDIRECT) / 100.0;
    color = color * (direct + indirect);

    if (material.x > 1.9) {
        color *= 4.0; // emissive boost for bloom
    }

    // ---- Voxel grid debug overlay (enable PT_DEBUG_VOXELS in options.glsl) ----
    #ifdef PT_DEBUG_VOXELS
    if (depth0 < 1.0) {
        vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
        vec3 rayOrig = cameraPosition - gridOrigin;
        vec3 rayDir  = normalize(getWorldPosition().xyz);

        ivec3 voxPos = ivec3(floor(rayOrig));
        ivec3 rayStep = ivec3(sign(rayDir));
        vec3 tDelta = 1.0 / max(abs(rayDir), vec3(1e-6));
        vec3 tMax   = (vec3(voxPos) + max(vec3(rayStep), vec3(0.0)) - rayOrig) / rayDir;

        bool hit = false;
        vec3 hitAlbedo = vec3(0.0);
        for (int i = 0; i < 128; i++) {
            if (any(lessThan(voxPos, ivec3(0))) || any(greaterThanEqual(voxPos, ivec3(VOXEL_GRID_SIZE)))) break;
            VoxelSample vs = readVoxel(colortex7, voxPos);
            if (vs.category != VOXEL_AIR) { hit = true; hitAlbedo = vs.albedo; break; }
            bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
            tMax  += vec3(mask) * tDelta;
            voxPos += ivec3(mask) * rayStep;
        }
        if (hit) color = hitAlbedo;
    }
    #endif

    // DEBUG VIEW: Skylight Illumination
    // We output the raw/denoised GI buffer (colortex3) directly to the screen.
    // This allows you to see exactly the indirect light reaching the surface!
    #ifdef GI_DEBUG_VIEW
        vec3 debugIllum = texture(colortex3, texCoord).rgb;
        /* RENDERTARGETS: 0 */
        gl_FragData[0] = vec4(debugIllum, 1.0);
    #else
        /* RENDERTARGETS: 0 */
        gl_FragData[0] = vec4(color, 1.0);
    #endif
}

#endif
