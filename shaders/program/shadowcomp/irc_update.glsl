// irc_update : irradiance-cache gather (compute)
// Runs after irc_shift. For each cache cell (distance-amortized), traces IRC_RAYS
// rays over the full sphere from the cell center through the voxel DDA, gathers
// incoming radiance (sun direct via a voxel shadow ray, sky probe, emissive blocks
// crossed, and a one-bounce feedback read of the cache itself for multi/infinite
// bounce), and ACCUMULATES it into the cell as (radiance sum, sample weight). The
// resolved mean radiance read during shading is rgb / max(a, eps). Because the
// decay+add forms a leaky integrator, the cell converges to a stable, low-noise
// estimate that is independent of the camera — no screen-space crawl, no
// disocclusion flush.

#ifdef CSH

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
// gi.glsl brings traceVoxelGI, traceVoxelRay, voxelData (+ rand, ao)
#include "/lib/pt/gi.glsl"
#include "/lib/pt/irc.glsl"

const ivec3 workGroups = IRC_WG;
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba16f) uniform image3D irradianceImg;

const vec3 LUMA_W = vec3(0.2126, 0.7152, 0.0722);

// Uniform direction on the sphere (cells are points in space with no normal; we
// estimate the mean incoming radiance over all directions).
vec3 ircSphereDir(float u1, float u2) {
    float z   = u1 * 2.0 - 1.0;
    float r   = sqrt(max(0.0, 1.0 - z * z));
    float phi = 6.2831853 * u2;
    return vec3(r * cos(phi), z, r * sin(phi));
}

void main() {
    ivec3 coord = ivec3(gl_GlobalInvocationID);
    if (any(greaterThanEqual(coord, IRC_DIMS))) return;

    // --- amortization: near cells update every frame, far cells 1-in-N ----------
    vec2  relXZ   = (vec2(coord.xz) + 0.5 - IRC_DIMSF.xz * 0.5) / (IRC_DIMSF.xz * 0.5);
    bool  doUpdate = dot(relXZ, relXZ) < (IRC_AMORTIZE_DIST * IRC_AMORTIZE_DIST);
#if IRC_AMORTIZE > 1
    if (!doUpdate) {
        uint phase = pcgHash(uint(coord.x) ^ (uint(coord.y) << 10) ^ (uint(coord.z) << 20)) % uint(IRC_AMORTIZE);
        doUpdate = (uint(frameCounter) % uint(IRC_AMORTIZE)) == phase;
    }
#endif
    if (!doUpdate) return;

    vec3 camPos     = cameraPosition;
    vec3 gridOrigin = floor(camPos) - VOXEL_RADIUS_VEC;
    vec3 cellCenter = ircCellCenter(coord, camPos); // world-absolute

    // Sun/sky colors — no vertex stage in compute, so derive them from uniforms
    // exactly like the gbuffer vertex shaders do.
    // These names are ASSIGNED by vectors.glsl/colors.glsl (they declare their own
    // sunColor/moonColor locals); pre-declare only the ones they write to.
    vec3 sunVector, moonVector, upVector, lightVector, lightColor, ambientColor;
    {
        #include "/lib/vectors.glsl"
        #include "/lib/colors.glsl"
    }
    vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
    vec3 giSky = ambientColor * GI_SKY_BRIGHTNESS;
    giSky *= mix(vec3(1.0), vec3(1.25, 1.04, 0.72), GI_SKY_WARMTH);

    uint seed = pcgHash(uint(coord.x) * 73856093u ^ uint(coord.y) * 19349663u
                      ^ uint(coord.z) * 83492791u ^ uint(frameCounter) * 2654435761u);

    vec3 acc = vec3(0.0);
    for (int i = 0; i < IRC_RAYS; i++) {
        vec3 dir = ircSphereDir(randFloat(seed), randFloat(seed));
        VoxelHit h = traceVoxelGI(voxelSampler, gridOrigin, cellCenter, dir, float(GI_RADIUS));

        vec3 rad = max(h.emission, vec3(0.0)); // emissive blocks crossed (already GI_EMISSION-scaled)

        if (h.hit) {
            // direct sun at the bounce surface (voxel shadow ray)
            float ndl = max(dot(h.normal, sunDirWorld), 0.0);
            if (ndl > 0.0) {
                bool occ = traceVoxelRay(voxelSampler, h.pos + h.normal * 0.1, sunDirWorld,
                                         float(GI_RADIUS), camPos, depthtex0,
                                         gbufferProjection, gbufferModelView, false);
                if (!occ) rad += h.albedo * lightColor * ndl;
            }
            // sky probe (can the bounce surface see the sky?)
            vec3  skyProbeRaw = h.normal + vec3(0.0, 1.0, 0.0);
            float l2 = dot(skyProbeRaw, skyProbeRaw);
            if (l2 > 1e-4) {
                vec3  skyDir  = skyProbeRaw * inversesqrt(l2);
                float lambert = max(dot(h.normal, skyDir), 0.0);
                bool  skyOcc  = traceVoxelRay(voxelSampler, h.pos + h.normal * 0.15, skyDir,
                                              float(GI_SKY_PROBE_DIST), camPos, depthtex0,
                                              gbufferProjection, gbufferModelView, false);
                if (!skyOcc) rad += vec3(dot(h.albedo, LUMA_W)) * giSky * lambert * GI_BOUNCE_SKY;
            }
            // one-bounce feedback: cache irradiance at the hit surface * albedo
            // (compounds across frames -> multi/infinite bounce). imageLoad (point
            // fetch) — the cache is bound here as an image, not a sampler.
            ivec3 hc;
            if (ircCoordOf(h.pos, h.normal, camPos, hc)) {
                vec4 b = imageLoad(irradianceImg, hc);
                rad += float(IRC_MULTIBOUNCE) * h.albedo * (b.rgb / max(b.a, 1e-4));
            }
        } else {
            // ray escaped to the sky
            rad += giSky * smoothstep(-0.2, 0.4, dir.y);
        }

        if (any(isnan(rad)) || any(isinf(rad))) rad = vec3(0.0);
        acc += max(rad, vec3(0.0));
    }

    // single owning thread per cell -> plain read-modify-write accumulation
    vec4 cell = imageLoad(irradianceImg, coord);
    cell.rgb += acc;
    cell.a   += float(IRC_RAYS);
    if (any(isnan(cell)) || any(isinf(cell))) cell = vec4(0.0);
    imageStore(irradianceImg, coord, cell);
}

#endif
