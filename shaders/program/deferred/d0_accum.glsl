// ============================================================================
//  d0_accum : temporal accumulation for indirect light (rebuilt)
// ----------------------------------------------------------------------------
//  Takes the 1spp estimate from d0_restir (colortex3, + ReSTIR spatial reuse here),
//  reprojects last frame, and blends with a 2x2 history fetch validated by LINEAR
//  depth + world normal (no raw-depth banding). Accumulation length adapts (hand /
//  near surfaces get a low cap to kill hand ghosting); a sudden brightening resets
//  history so light doesn't trail in; fresh pixels are spatially seeded.
//
//  Output: colortex8 = accumulated GI (.rgb) + history length (.a)
//          colortex9 = LINEAR depth (.r) + luminance moments (.g = E[L], .b = E[L^2])
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/pt/denoise.glsl"

in vec2 texCoord;

uniform sampler2D colortex1;   // view normals
uniform sampler2D colortex3;   // raw 1spp GI (from d0_restir)
uniform sampler2D colortex8;   // GI history (.rgb col, .a frames)
uniform sampler2D colortex9;   // history: LINEAR depth (.r) + moments (.g,.b)
uniform sampler2D colortex10;  // ReSTIR reservoir radiance/M
uniform sampler2D colortex11;  // ReSTIR reservoir samplePos/W
uniform sampler2D colortex14;  // ReSTIR reservoir sampleNormal
uniform sampler2D colortex15;  // world-normal history (.xy oct)
uniform sampler2D depthtex0;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform mat4 gbufferProjection;
#ifndef GBUFFER_PROJECTION_INVERSE_DECLARED
#define GBUFFER_PROJECTION_INVERSE_DECLARED
uniform mat4 gbufferProjectionInverse;
#endif
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

vec3 clipSpace;
#include "/lib/util/positions.glsl"
#include "/lib/pt/restir.glsl"

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter)     * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    float depth0 = texture(depthtex0, texCoord).r;

    // Sky: clear history, store far depth.
    if (depth0 >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        gl_FragData[1] = vec4(far, 0.0, 0.0, 1.0);
        return;
    }

    // Gbuffer sampled at the pixel; only the reconstruction NDC is unjittered.
    vec2 uvUnjittered = texCoord - currentJitter;
    clipSpace = vec3(uvUnjittered, depth0) * 2.0 - 1.0;
    float linDepth   = getDepth(depth0);

    vec3 normal      = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3 worldRel    = getWorldPosition().xyz;

    vec3 rawGI = texture(colortex3, texCoord).rgb;

    // ---- ReSTIR spatial reuse (current frame; reservoirs from d0_restir) ----
    // A freshly-disoccluded pixel has no temporal reservoir, so its reservoir M is just
    // RESTIR_INITIAL_SAMPLES (~1). Its single cosine ray probably missed the room's light
    // source, so the pixel reads black - and the temporal accumulator then "builds up"
    // light over many frames (the disocclusion ghost trail). Fix: detect that low-M state
    // and do MANY more spatial reservoir reuses at a much LARGER radius, so the fresh
    // pixel borrows found-light samples directly from the converged interior of the screen.
    // This is the real "more rays" the path tracer needs at disocclusion edges.
    #if defined(VOXEL_GI) && defined(RESTIR_GI) && defined(RESTIR_SPATIAL)
        uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter + 1);
        Reservoir shade = readReservoir(colortex10, colortex11, colortex14, texCoord);
        shade.wSum = luma(shade.radiance) * shade.W * shade.M;

        // Adaptive sample count / radius. Loop bound stays a compile-time constant for
        // driver portability; we just break out early when the pixel isn't fresh.
        const int   DISOCC_SAMPLES  = 8;
        const float DISOCC_RADIUS   = 48.0;
        bool  isFresh   = shade.M < 4.0;
        int   nSamples  = isFresh ? DISOCC_SAMPLES        : RESTIR_SPATIAL_SAMPLES;
        float radius    = isFresh ? DISOCC_RADIUS         : float(RESTIR_SPATIAL_RADIUS);

        float depthThresh  = isFresh ? 0.40 : 0.10;
        float normalThresh = isFresh ? 0.3  : 0.8;

        for (int i = 0; i < DISOCC_SAMPLES; i++) {
            if (i >= nSamples) break;
            float ang  = randFloat(seed) * 6.2831853;
            float dist = sqrt(randFloat(seed)) * radius;
            vec2  nUV  = texCoord + vec2(cos(ang), sin(ang)) * dist * texelSize;
            if (clamp(nUV, 0.0, 1.0) != nUV) continue;
            
            float nDepth = textureLod(depthtex0, nUV, 0.0).r;
            if (abs(getDepth(nDepth) - linDepth) / max(linDepth, 0.001) > depthThresh) continue;
            vec3 nNormal = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
            if (dot(normal, nNormal) < normalThresh) continue;
            
            Reservoir n = readReservoir(colortex10, colortex11, colortex14, nUV);
            n.M = min(n.M, float(RESTIR_M_CAP));

            #ifdef RESTIR_JACOBIAN
                // Calculate neighbor's world position
                vec4 nFrag = gbufferProjectionInverse * vec4(vec3(nUV, nDepth) * 2.0 - 1.0, 1.0);
                nFrag.xyz /= nFrag.w;
                vec3 p_neighbor = (gbufferModelViewInverse * vec4(nFrag.xyz, 1.0)).xyz;
                
                vec3 v_current = n.samplePos - worldRel;
                vec3 v_neighbor = n.samplePos - p_neighbor;
                
                float dist_current = max(length(v_current), 0.01);
                float dist_neighbor = max(length(v_neighbor), 0.01);
                
                vec3 l_current = v_current / dist_current;
                vec3 l_neighbor = v_neighbor / dist_neighbor;
                
                float cos_n_current = max(dot(n.sampleNormal, -l_current), 0.0);
                float cos_n_neighbor = max(dot(n.sampleNormal, -l_neighbor), 0.0);
                float cos_p_current = max(dot(normalWorld, l_current), 0.0);
                
                if (cos_n_current <= 0.0 || cos_p_current <= 0.0) continue;
                
                float jacobian = (cos_n_current * dist_neighbor * dist_neighbor) / 
                                 max(cos_n_neighbor * dist_current * dist_current, 0.0001);
                jacobian = clamp(jacobian, 0.9, 1.1);
                                 
                float pHat = luma(n.radiance) * cos_p_current * jacobian;
            #else
                float pHat = luma(n.radiance);
            #endif

            mergeReservoir(shade, n, max(pHat, 0.0001), seed);
        }
        finalizeReservoir(shade);
        rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);
    #endif

    // ---- 3x3 firefly clamp + spatial seed (geometry-aware) ----
    vec3  neighborSum    = vec3(0.0);
    float neighborWeight = 0.0;
    for (int x = -1; x <= 1; x++)
    for (int y = -1; y <= 1; y++) {
        if (x == 0 && y == 0) continue;
        vec2  nUV    = texCoord + vec2(x, y) * texelSize;
        float nLin   = getDepth(textureLod(depthtex0, nUV, 0.0).r);
        vec3  nN     = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
        if (abs(nLin - linDepth) < 0.1 * linDepth && dot(normal, nN) > 0.8) {
            neighborSum += textureLod(colortex3, nUV, 0.0).rgb;
            neighborWeight += 1.0;
        }
    }
    vec3 neighborAvg = neighborWeight > 0.5 ? neighborSum / neighborWeight : rawGI;
    if (neighborWeight > 0.5 && luma(rawGI) > luma(neighborAvg) * 3.0 + 0.02) rawGI = neighborAvg;

    float lr = luma(rawGI);

    // ---- Reproject to previous frame ----
    bool  isHand = depth0 < 0.56;
    vec2  uvPrev;
    float expLinD;
    if (isHand) {
        uvPrev  = texCoord;
        expLinD = linDepth;
    } else {
        vec3 worldPrevRel = worldRel + (cameraPosition - previousCameraPosition);
        vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
        vec4 clipPrev = gbufferPreviousProjection * viewPrev;
        uvPrev  = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5 - prevJitter;
        expLinD = getDepth(clipPrev.z / clipPrev.w * 0.5 + 0.5);
    }

    // ---- 2x2 bilinear history fetch, validated by LINEAR depth + normal ----
    vec3  histColor  = vec3(0.0);
    vec2  histMom    = vec2(0.0);
    float histFrames = 0.0;
    float wsum       = 0.0;

    vec2  padding = 1.5 * texelSize;
    if (all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding))) {
        vec2  prevPix = uvPrev * vec2(viewWidth, viewHeight) - 0.5;
        ivec2 base    = ivec2(floor(prevPix));
        vec2  f       = fract(prevPix);

        for (int i = 0; i < 4; i++) {
            ivec2 o = ivec2(i & 1, i >> 1);
            ivec2 t = base + o;
            if (any(lessThan(t, ivec2(0))) || any(greaterThanEqual(t, ivec2(viewWidth, viewHeight)))) continue;

            float sLin = texelFetch(colortex9, t, 0).r;                       // stored LINEAR depth
            if (abs(sLin - expLinD) > expLinD * 0.05 + 0.02) continue;         // relative depth gate
            vec3  sN = octDecodeNormal(texelFetch(colortex15, t, 0).xy);
            if (dot(sN, normalWorld) < 0.85) continue;                         // normal gate

            float bw = mix(1.0 - f.x, f.x, float(o.x)) * mix(1.0 - f.y, f.y, float(o.y));
            vec4  sC = texelFetch(colortex8, t, 0);
            vec2  sM = texelFetch(colortex9, t, 0).gb;
            histColor  += sC.rgb * bw;
            histFrames += sC.a   * bw;
            histMom    += sM      * bw;
            wsum       += bw;
        }
    }

    // ---- Blend ----
    float maxFrames = isHand ? float(DENOISE_HAND_FRAMES) : float(DENOISE_MAX_FRAMES);
    float frames    = 1.0;
    vec3  outColor  = rawGI;
    vec2  outMom    = vec2(lr, lr * lr);

    if (wsum > 1e-4) {
        // Colours / moments use the standard bilinear blend (normalised).
        histColor /= wsum;
        histMom   /= wsum;
        // Frames stay UN-normalised: they're now a validity-weighted sum, so partial
        // disocclusion (e.g. only 1 of the 2x2 taps survives the depth/normal gate)
        // proportionally drops the accumulated frames -> the ghost trail dies off
        // immediately instead of inheriting full convergence from a postage-stamp patch.

        frames = min(histFrames + 1.0, maxFrames);

        // BIDIRECTIONAL change rejection: when the local (3x3-smoothed) luma diverges
        // from the history mean - brighter OR darker - drop history. Catches lighting
        // changes, view rotation onto a differently-lit surface, and disocclusion onto
        // a similar-depth-but-different-radiance surface. Uses the smoothed luma so
        // 1spp noise doesn't trigger it.
        #if DENOISE_FAST_LIGHT > 0
            float curSpatialLum = luma(neighborAvg);
            float diffLum = abs(curSpatialLum - histMom.x)
                          / max(max(curSpatialLum, histMom.x), 0.02);
            float reset = clamp((diffLum - 0.15) * (float(DENOISE_FAST_LIGHT) / 60.0), 0.0, 1.0);
            frames = mix(frames, 1.0, reset * reset);
        #endif

        float a  = 1.0 / frames;
        outColor = mix(histColor, rawGI, a);
        outMom   = mix(histMom, vec2(lr, lr * lr), a);
    }

    // Disocclusion seed: fresh pixels are noisy at 1spp; blend toward the 3x3 spatial
    // mean of the raw GI for a couple of frames. (Wider gathers / colortex8 lookups were
    // tried here but couldn't conjure light when the base PT itself is dark - that's a
    // PT-side problem, not an accumulator-side one; see the GI-feedback work in gi.glsl.)
    outColor = mix(neighborAvg, outColor, clamp((frames - 1.0) / 3.0, 0.0, 1.0));

    /* RENDERTARGETS: 8,9 */
    gl_FragData[0] = vec4(outColor, frames);
    gl_FragData[1] = vec4(linDepth, outMom.x, outMom.y, 1.0);
}

#endif
