#ifndef GTAO_GLSL
#define GTAO_GLSL

// Screen-space ground-truth ambient occlusion (Jimenez et al. 2016),
// DECOUPLED from the voxel path tracer.
//
// Why screen-space here: the old RTAO rode the GI candidate's voxel ray, so it
//  - was quantized to whole blocks (no stairs/slabs/decoration contact detail),
//  - went checkered when RESTIR_CHECKERBOARD skipped the candidate,
//  - died beyond the voxel grid.
// GTAO works at PIXEL granularity from the packed linear-depth/world-normal
// G-buffer (colortex15, written by d0_restir), samples EVERY pixel EVERY
// frame, and costs zero voxel traces. The per-frame noise (few slices) is
// smoothed by the existing temporal AO accumulation in d0_accum (colortex9.a).
//
// All taps read colortex15.z (linear depth) — cache-coherent 2D fetches, no
// getDepth() unprojection per tap.

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"

// view-space position from pixel-grid uv + linear depth
// (clip.x = P00*view.x, w = -view.z = linDepth => view.x = ndc.x*linDepth/P00)
vec3 gtaoViewPos(vec2 uv, float linDepth) {
    vec2 ndc = uv * 2.0 - 1.0;
    return vec3(ndc * vec2(1.0 / gbufferProjection[0][0],
                           1.0 / gbufferProjection[1][1]) * linDepth,
                -linDepth);
}

// returns visibility in [0,1] (1 = unoccluded), cosine-weighted
float computeGTAO(vec2 uv, float linDepth, vec3 normalWorld, int frame) {
    vec3 viewPos    = gtaoViewPos(uv, linDepth);
    vec3 viewNormal = mat3(gbufferModelView) * normalWorld;
    vec3 V          = normalize(-viewPos);

    // world-space AO radius projected to pixels at this depth. The clamp's
    // low end keeps taps meaningful up close; past the point where 2px spans
    // more than GTAO_RADIUS the distance falloff fades AO out naturally.
    float radiusPx = (float(GTAO_RADIUS) * gbufferProjection[1][1] * 0.5 * viewHeight)
                   / max(linDepth, 0.5);
    radiusPx = clamp(radiusPx, 2.0, 48.0);

    // per-pixel spatial decorrelation + TAA-phase-locked temporal rotation
    // (period 8, same scheme as the a-trous kernel rotation — see the lesson
    // in denoise.glsl: free-running per-frame angles shimmer against TAA)
    vec2 p = uv * vec2(viewWidth, viewHeight);
    float baseAng = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) * PI
                  + float(frame % 8) * (PI / 8.0);

    float visibility = 0.0;

    for (int s = 0; s < GTAO_SLICES; s++) {
        float ang  = baseAng + float(s) * (PI / float(GTAO_SLICES));
        vec2 omega = vec2(cos(ang), sin(ang));

        // slice frame: marching direction, slice-plane axis, projected normal
        vec3 dirV     = vec3(omega, 0.0);
        vec3 orthoDir = dirV - dot(dirV, V) * V;
        vec3 axis     = normalize(cross(dirV, V));
        vec3 projN    = viewNormal - axis * dot(viewNormal, axis);
        float projNLen = length(projN);
        if (projNLen < 1e-4) continue;

        float cosNorm = clamp(dot(projN, V) / projNLen, -1.0, 1.0);
        float n = sign(dot(orthoDir, projN)) * acos(cosNorm);

        // horizon search, both sides of the slice
        float h1cos = -1.0; // -omega side
        float h2cos = -1.0; // +omega side
        for (int i = 1; i <= GTAO_STEPS; i++) {
            float t = float(i) / float(GTAO_STEPS);
            t *= t; // concentrate taps near the center (contact detail)
            vec2 offUV = omega * (t * radiusPx) * texelSize;

            // +side
            {
                vec2 uvS = clamp(uv + offUV, vec2(0.0), vec2(1.0));
                float dS = textureLod(colortex15, uvS, 0.0).z;
                vec3 ws  = gtaoViewPos(uvS, dS) - viewPos;
                float dist = length(ws);
                float cosH = dot(ws, V) / max(dist, 1e-5);
                // range falloff: geometry beyond the AO radius opens back up
                cosH = mix(cosH, -1.0, clamp((dist - float(GTAO_RADIUS)) / float(GTAO_RADIUS), 0.0, 1.0));
                h2cos = max(h2cos, cosH);
            }
            // -side
            {
                vec2 uvS = clamp(uv - offUV, vec2(0.0), vec2(1.0));
                float dS = textureLod(colortex15, uvS, 0.0).z;
                vec3 ws  = gtaoViewPos(uvS, dS) - viewPos;
                float dist = length(ws);
                float cosH = dot(ws, V) / max(dist, 1e-5);
                cosH = mix(cosH, -1.0, clamp((dist - float(GTAO_RADIUS)) / float(GTAO_RADIUS), 0.0, 1.0));
                h1cos = max(h1cos, cosH);
            }
        }

        // horizon angles around V, clamped to the normal's hemisphere
        float h1 = -acos(clamp(h1cos, -1.0, 1.0));
        float h2 =  acos(clamp(h2cos, -1.0, 1.0));
        h1 = n + max(h1 - n, -GTAO_HALF_PI);
        h2 = n + min(h2 - n,  GTAO_HALF_PI);

        // cosine-weighted visibility arc (Jimenez 2016 inner integral)
        float sinN = sin(n), cosN = cos(n);
        float arc = 0.25 * (-cos(2.0 * h1 - n) + cosN + 2.0 * h1 * sinN)
                  + 0.25 * (-cos(2.0 * h2 - n) + cosN + 2.0 * h2 * sinN);

        visibility += projNLen * arc;
    }

    return clamp(visibility / float(GTAO_SLICES), 0.0, 1.0);
}

#endif
