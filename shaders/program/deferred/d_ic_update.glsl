// ============================================================================
//  d_ic_update : world-space irradiance cache probe update
// ----------------------------------------------------------------------------
//  One fragment per probe. Each probe shoots IC_RAYS_PER_PROBE uniform-sphere
//  rays through the voxel grid. On a hit it computes direct sun + sky-probe
//  shading at the hit surface, then samples the PREVIOUS frame's IC at the
//  hit point for the multi-bounce term (this is the infinite-bounce trick:
//  prev frame's IC was lit by its own prev-prev frame, etc.). On a miss it
//  samples the directional sky LUT.
//
//  The result is temporally blended with the prior probe value with a 1/N
//  weight (N = clamped history length). Pixels outside the atlas region are
//  passed through unchanged so colortex14's other bytes stay untouched.
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
#include "/lib/pt/voxelData.glsl"
#include "/lib/pt/ircache.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/skyLut.glsl"
#include "/lib/pt/ddaTrace.glsl"

float icLuma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;

uniform usampler2D colortex7;    // voxel atlas
uniform sampler2D  colortex14;   // IC atlas (this pass is the sole writer; reads see prev frame)
uniform sampler2D  colortex13;   // directional sky LUT
uniform sampler2D  depthtex0;
uniform vec3       cameraPosition;
uniform vec3       previousCameraPosition;
uniform mat4       gbufferProjection;
uniform mat4       gbufferModelView;
uniform mat4       gbufferModelViewInverse;
uniform int        frameCounter;

// Same per-voxel-face DDA used elsewhere in the pack. Inlined so we can grab
// hit position + face normal without the giRayRadiance wrapper's framework.
struct ProbeHit {
    bool  hit;
    vec3  pos;
    vec3  normal;
    uint  category;
    vec3  albedo;
};

ProbeHit probeTrace(usampler2D atlas, vec3 gridOrigin, vec3 worldPos, vec3 rayDir, float maxDist) {
    ProbeHit r;
    r.hit = false; r.pos = worldPos; r.normal = vec3(0.0);
    r.category = VOXEL_AIR; r.albedo = vec3(0.0);

    vec3  localPos = worldPos - gridOrigin;
    ivec3 vox      = ivec3(floor(localPos));
    ivec3 stepDir  = ivec3(sign(rayDir));
    vec3  tDelta   = 1.0 / max(abs(rayDir), vec3(1e-8));
    vec3  tMax;
    for (int i = 0; i < 3; ++i) {
        if (rayDir[i] > 0.0)      tMax[i] = (floor(localPos[i]) + 1.0 - localPos[i]) * tDelta[i];
        else if (rayDir[i] < 0.0) tMax[i] = (localPos[i] - floor(localPos[i])) * tDelta[i];
        else                       tMax[i] = 1e38;
    }
    vec3  lastMask = vec3(0.0);
    float tEntry   = 0.0;
    for (int i = 0; i < 48; i++) {
        if (tEntry >= maxDist) break;
        if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(VOXEL_GRID_SIZE)))) break;

        uvec4 v = texelFetch(atlas, voxelCoordToAtlas(vox), 0);
        if (v.r != VOXEL_AIR && i > 0) {
            r.hit      = true;
            r.category = v.r;
            r.albedo   = vec3(v.gba) / 255.0;
            r.pos      = worldPos + rayDir * tEntry;
            r.normal   = -vec3(stepDir) * lastMask;
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

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);

    // Pass through pixels outside the atlas region so the rest of colortex14
    // retains whatever it held (currently nothing uses those bytes).
    ivec3 pc;
    if (!icAtlasToCoord(px, pc)) {
        /* RENDERTARGETS: 14 */
        gl_FragData[0] = texelFetch(colortex14, px, 0);
        return;
    }

    // Current and previous cascade anchors. The atlas we read was written last
    // frame anchored at prevOrigin; we are writing this frame anchored at
    // currentOrigin. Probes that occupy the same world position across the two
    // frames live at coords shifted by `delta` between the two atlases.
    vec3 currentOrigin = icGridOrigin(cameraPosition);
    vec3 prevOrigin    = icGridOrigin(previousCameraPosition);
    ivec3 originDelta  = ivec3(currentOrigin - prevOrigin);

    vec3 probeWorld = currentOrigin + vec3(pc) + vec3(0.5);
    vec3 voxGridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);

    // Probes inside solid voxels can't gather useful light; zero them.
    #ifdef IC_SKIP_SOLID_PROBES
    {
        ivec3 voxCoord;
        if (worldToVoxel(probeWorld, voxGridOrigin, voxCoord)) {
            uint vt = texelFetch(colortex7, voxelCoordToAtlas(voxCoord), 0).r;
            if (vt != VOXEL_AIR && vt != VOXEL_FOLIAGE) {
                /* RENDERTARGETS: 14 */
                gl_FragData[0] = vec4(0.0);
                return;
            }
        }
    }
    #endif

    uint seed = pcgHash(uint(pc.x) * 1973u + uint(pc.y) * 9277u + uint(pc.z) * 26699u + uint(frameCounter) * 60493u);
    vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
    vec3 giSky = ambientColor * GI_SKY_BRIGHTNESS;

    ivec3 prevCoord = pc + originDelta;
    bool validPrev = all(greaterThanEqual(prevCoord, ivec3(0)))
                  && all(lessThan(prevCoord, ivec3(IC_GRID_DIM)));
    vec4 prev = validPrev ? texelFetch(colortex14, icCoordToAtlas(prevCoord), 0) : vec4(0.0);

    // Early exit for converged, static probes
    if (validPrev && prev.a >= float(IC_HISTORY_MAX) - 1.0 && all(equal(originDelta, ivec3(0)))) {
        uint probeHash = pcgHash(uint(pc.x) + uint(pc.y)*67u + uint(pc.z)*137u);
        if ((probeHash + uint(frameCounter)) % uint(IC_SKIP_INTERVAL) != 0u) {
            /* RENDERTARGETS: 14 */
            gl_FragData[0] = prev;
            return;
        }
    }

    vec3 acc = vec3(0.0);
    const int rays = IC_RAYS_PER_PROBE;

    for (int i = 0; i < rays; i++) {
        float u = randFloat(seed);
        float v = randFloat(seed);
        float z = 1.0 - 2.0 * u;
        float r = sqrt(max(0.0, 1.0 - z * z));
        float phi = 6.2831853 * v;
        vec3 dir = vec3(r * cos(phi), z, r * sin(phi));

        ProbeHit h = probeTrace(colortex7, voxGridOrigin, probeWorld, dir, float(GI_RADIUS));
        // h.normal points into the voxel face the ray entered through.

        vec3 rad = vec3(0.0);
        if (h.hit) {
            if (h.category == VOXEL_EMISSIVE) {
                rad = h.albedo * float(GI_EMISSION);
            } else {

                float ndl = max(dot(h.normal, sunDirWorld), 0.0);
                if (ndl > 0.0) {
                    bool occ = traceVoxelRay(colortex7, h.pos + h.normal * 0.1, sunDirWorld,
                                             float(GI_RADIUS), cameraPosition, depthtex0,
                                             gbufferProjection, gbufferModelView);
                    if (!occ) rad += h.albedo * lightColor * ndl;
                }

                vec3 skyProbeRaw = h.normal + vec3(0.0, 1.0, 0.0);
                if (dot(skyProbeRaw, skyProbeRaw) > 1e-4) {
                    vec3 skyProbeDir = normalize(skyProbeRaw);
                    bool skyEscape = !traceVoxelRay(colortex7, h.pos + h.normal * 0.15,
                                                    skyProbeDir, float(GI_SKY_PROBE_DIST),
                                                    cameraPosition, depthtex0,
                                                    gbufferProjection, gbufferModelView);
                    if (skyEscape) {
                        #ifdef GI_SKY_DIRECTIONAL
                            vec3 probeSky = sampleSkyLut(colortex13, skyProbeDir) * GI_SKY_BRIGHTNESS;
                        #else
                            vec3 probeSky = giSky;
                        #endif
                        rad += h.albedo * probeSky * max(dot(h.normal, skyProbeDir), 0.0) * GI_BOUNCE_SKY;
                    }
                }

                // Multi-bounce: pull last frame's IC at the hit point. The atlas we read
                // was anchored at prevOrigin (see comment at top), so pass that — sampling
                // with currentOrigin while the camera has walked drags the cache behind
                // the player by one cell per block of motion.
                vec4 prevAtHit = icSampleTrilinear(colortex14, h.pos, h.normal, prevOrigin, colortex7, voxGridOrigin);
                rad += h.albedo * prevAtHit.rgb * (float(IC_FEEDBACK) / 100.0);
            }
        } else {
            #ifdef GI_SKY_DIRECTIONAL
                rad = sampleSkyLut(colortex13, dir) * GI_SKY_BRIGHTNESS;
            #else
                rad = giSky;
            #endif
            rad *= smoothstep(-0.2, 0.4, dir.y);
        }
        acc += rad;
    }
    acc /= float(rays);

    // Temporal blend with the prior probe value. To keep the cache anchored
    // to world space (not to the camera), reproject the history through the
    // cascade shift: this probe's world position last frame lived at coord
    // `pc + originDelta` in the prior atlas. Probes that crossed in from
    // outside the old cascade get no history (histLen = 1, alpha = 1.0) so
    // newly-entered cells converge in a single frame instead of taking 64.
    float histLen = validPrev ? clamp(prev.a + 1.0, 1.0, float(IC_HISTORY_MAX)) : 1.0;
    float a = 1.0 / histLen;
    vec3 blended = mix(prev.rgb, acc, a);

    // Per-probe firefly clamp against the previous value.
    float pl = icLuma(prev.rgb);
    float bl = icLuma(blended);
    float lim = pl * IC_FIREFLY + 0.5;
    if (bl > lim) blended *= lim / max(bl, 1e-4);

    /* RENDERTARGETS: 14 */
    gl_FragData[0] = vec4(blended, histLen);
}

#endif
