// sc1_surface_direct : surface cache update (direct light + radiosity)
//
// One thread per cascade-0 voxel; each thread lights all six of its faces and
// writes their outgoing radiance into faceRadianceImg. Runs in shadowcomp, after
// the shadow pass has both rasterised the voxel grid and filled the shadow map,
// so the voxel word and the sun visibility this pass needs are already current.
//
// Cost is fixed and independent of screen resolution -- the whole point of a
// world-space cache. It is amortised further: only 1/SC_UPDATE_STRIDE of the
// volume is touched per frame, selected by a frame-rotating Z phase, so a full
// refresh takes SC_UPDATE_STRIDE frames.
//
// Per face:
//   direct   = sun/moon through the shadow map, plus the block's self-emission
//   indirect = a few cosine rays, each resolving its hit through the cache
//              itself rather than shading it
//   stored   = direct + albedo * indirect, blended into the previous value
//
// The indirect term reading the cache it is writing IS the design: this frame's
// bounce sees last frame's totals, which already contained a bounce, so bounce
// count grows by one per refresh and multi-bounce costs nothing extra. It also
// means the cache converges over several frames rather than being exact on any
// single one -- hence the temporal blend, which is what keeps a 2-ray estimate
// from visibly boiling.
//
// The plan called for splitting this across two dispatches (direct in
// shadowcomp1, radiosity in shadowcomp2). Merged deliberately: with only
// 1/STRIDE of the volume refreshed per frame, a separate radiosity pass would
// still be sampling mostly-previous-frame direct light, so the split bought a
// second full dispatch and a read-after-write hazard between passes for no
// accuracy gain.

#define SC_IMAGE   // this pass reads AND writes the cache; see surfaceCache.glsl

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"        // isInShadow
#include "/lib/pt/surfaceCache.glsl"
#include "/lib/pt/voxelFormat.glsl"
#include "/lib/pt/directLight.glsl"
#include "/lib/pt/rand.glsl"
#include "/lib/pt/sampling.glsl"        // buildTBN, cosHemisphereDir
#include "/lib/pt/voxelTrace.glsl"
#include "/lib/fragment/sky.glsl"       // sampleSky_fast
#include "/lib/blocklightColors.glsl"   // GetSpecialBlocklightColor

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
const ivec3 workGroups = ivec3(SC_XZ / 8, SC_Y / 8, SC_XZ / SC_UPDATE_STRIDE);

// Voxel word at a cascade-0 LOCAL coordinate, or air outside the volume.
uint fetchLocal(ivec3 local) {
    if (any(lessThan(local, ivec3(0))) || any(greaterThanEqual(local, CASCADE_DIMS))) {
        return 0u; // outside cascade 0 -> treat as air, so border faces stay lit
    }
    return texelFetch(voxelSampler, cascadeAtlasCoord(local, 0), 0).r;
}

void main() {
    // --- slot -> world voxel ------------------------------------------------
    ivec3 slot;
    slot.x = int(gl_GlobalInvocationID.x);
    slot.y = int(gl_GlobalInvocationID.y);
    // Frame-rotating Z phase: each frame covers every SC_UPDATE_STRIDE'th slab.
    slot.z = int(gl_GlobalInvocationID.z) * SC_UPDATE_STRIDE
           + (frameCounter % SC_UPDATE_STRIDE);

    if (any(greaterThanEqual(slot, ivec3(SC_XZ, SC_Y, SC_XZ)))) return;

    ivec3 org   = scCascadeOriginVoxel();
    ivec3 wv    = scSlotToWorldVoxel(slot, org);
    ivec3 local = wv - org;

    uint w = fetchLocal(local);

    // Air voxels are still written. Leaving them alone would let a slot keep the
    // radiance of whatever solid block used to occupy it, and the tag would
    // agree -- the tag detects a change of WORLD VOXEL, not a change of contents
    // at the same voxel (a block being broken, say).
    if (voxelIsAir(w)) {
        for (int f = 0; f < SC_FACES; ++f) scImageStore(wv, f, vec3(0.0));
        return;
    }

    uint cat    = voxelCategory(w);
    vec3 albedo = voxelAlbedo(w);

    // Self-emission is a property of the block, not of any one face.
    vec3 emission = vec3(0.0);
    if (cat == VOXEL_LIGHT) {
        emission = GetSpecialBlocklightColor(int(voxelLightMat(w))).rgb * float(GI_EMISSION);
    } else if (cat == VOXEL_EMISSIVE) {
        emission = albedo * float(GI_EMISSION) * SC_EMISSIVE_BOOST;
    }

    vec3  lightVec  = ptWorldLightVector();
    vec3  lightCol  = ptLightColor();
    float rain      = 1.0 - rainStrength * 0.75;
    float eyeAlt    = ptEyeAltitude();
    uint  seed      = pcgHash(uint(wv.x * 73856093) ^ uint(wv.y * 19349663)
                            ^ uint(wv.z * 83492791) ^ uint(frameCounter) * 2654435761u);

    for (int f = 0; f < SC_FACES; ++f) {
        vec3 n = scFaceNormal(f);

        // A face buried against a solid neighbour emits nothing: no ray can see
        // it, and lighting it would leak through a one-block partition whenever
        // a lookup landed on the wrong side.
        if (!voxelIsAir(fetchLocal(local + scFaceOffset(f)))) {
            scImageStore(wv, f, vec3(0.0));
            continue;
        }

        // Face centre, lifted off the plane so neither the shadow lookup nor the
        // bounce rays start inside the block they belong to.
        vec3 faceCentre = vec3(wv) + 0.5 + n * 0.5;
        vec3 origin     = faceCentre + n * 0.02;

        // --- direct ---------------------------------------------------------
        vec3  direct = emission;
        float NdotL  = dot(n, lightVec);
        if (NdotL > 0.0) {
            // isInShadow wants a CAMERA-RELATIVE position: it applies
            // shadowModelView, which is already camera-centred.
            if (!isInShadow(origin + n * 0.03 - cameraPosition)) {
                direct += albedo * lightCol * NdotL * rain;
            }
        }

        // --- indirect -------------------------------------------------------
        // Cosine-weighted, so the estimator is a plain mean: no 1/pdf, no NdotL.
        vec3 incoming = vec3(0.0);
        for (int r = 0; r < SC_BOUNCE_RAYS; ++r) {
            vec3 dir = cosHemisphereDir(n, randFloat(seed), randFloat(seed));
            VoxelHit h = traceVoxelCascaded(origin, dir, float(SC_BOUNCE_DIST), true);

            if (h.hit) {
                // The whole point: resolve the hit through the cache instead of
                // shading it. Emitters passed through on the way are additive.
                incoming += scImageLookup(h.pos, h.normal) + h.emission;
            } else {
                // Never sampleSky(): it carries the sun and moon discs (x1000 and
                // x100) and a single ray clipping one is a guaranteed firefly.
                //
                // This reads the atmosphere LUT in colortex12, which prepare.fsh
                // rebuilds LATER in the frame than shadowcomp runs -- so the sky
                // colour here is one frame stale. Harmless: the LUT changes over
                // minutes of world time, and the cache's own temporal blend has a
                // far longer time constant than a frame.
                incoming += sampleSky_fast(dir, eyeAlt) * float(GI_SKY_BRIGHTNESS)
                          + h.emission;
            }
        }
        incoming *= 1.0 / float(SC_BOUNCE_RAYS);

        vec3 total = direct + albedo * incoming;

        // Firefly clamp at the source, before the value can be fed back into the
        // next frame's bounce and amplified.
        float lum = dot(total, vec3(0.2126, 0.7152, 0.0722));
        if (GI_FIREFLY_MAX < 1000.0 && lum > GI_FIREFLY_MAX) {
            total *= GI_FIREFLY_MAX / lum;
        }

        // --- temporal blend -------------------------------------------------
        // A few rays per face per refresh is far too noisy to use raw. Blending
        // against the slot's previous value turns the cache into its own
        // accumulator. A slot whose tag has gone stale has no usable history, so
        // it takes the new value outright rather than blending toward a
        // different block's radiance.
        vec4  prev  = imageLoad(faceRadianceImg, scImageCoord(wv, f));
        bool  valid = abs(prev.a - scTag(wv)) < 0.5;
        vec3  outR  = valid ? mix(prev.rgb, total, SC_BLEND) : total;

        scImageStore(wv, f, outR);
    }
}
