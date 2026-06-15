#ifndef GTAO_GLSL
#define GTAO_GLSL

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"

vec3 gtaoViewPos(vec2 uv, float linDepth) {
    vec2 ndc = uv * 2.0 - 1.0;
    return vec3(ndc * vec2(1.0 / gbufferProjection[0][0],
                           1.0 / gbufferProjection[1][1]) * linDepth,
                -linDepth);
}

float computeGTAO(vec2 uv, float linDepth, vec3 normalWorld, int frame) {
    vec3 viewPos    = gtaoViewPos(uv, linDepth);
    vec3 viewNormal = mat3(gbufferModelView) * normalWorld;
    vec3 V          = normalize(-viewPos);

    float radiusPx = (float(GTAO_RADIUS) * gbufferProjection[1][1] * 0.5 * viewHeight)
                   / max(linDepth, 0.5);
    radiusPx = clamp(radiusPx, 2.0, 48.0);

    vec2 p = uv * vec2(viewWidth, viewHeight);
    float baseAng = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) * PI
                  + float(frame % 8) * (PI / 8.0);

    float visibility = 0.0;

    for (int s = 0; s < GTAO_SLICES; s++) {
        float ang  = baseAng + float(s) * (PI / float(GTAO_SLICES));
        vec2 omega = vec2(cos(ang), sin(ang));

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
                float dS = getDepth(textureLod(depthtex0, uvS * renderScale, 0.0).r); // ct15 (packed depth) removed by IRC migration -> linearize depthtex0
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
                float dS = getDepth(textureLod(depthtex0, uvS * renderScale, 0.0).r); // ct15 (packed depth) removed by IRC migration -> linearize depthtex0
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
