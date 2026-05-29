// c1_bloom_atlas : multi-scale bloom atlas + TAA / exposure persistence
// Replaces the old soft-threshold extract. Builds the 7-tile mip atlas via
// mip-sampled colortex0 (LODs 2..8) and stores it in colortex3. Also carries
// the TAA-resolved HDR scene + exposure into colortex5 for the next frame's
// d0_restir / temporal radiance cache.
//
// Tile layout, packing and unpack live in lib/post/bloom.glsl.

#include "/lib/options.glsl"

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

in vec2 texCoord;

#include "/lib/util/common.glsl"
#include "/lib/post/bloom.glsl"

void main() {
    vec3 sceneColor = texture(colortex0, texCoord).rgb;

    // Carry the previous-frame exposure through to colortex5 so c0_taa and the
    // PT chain can keep using the existing "exposure-in-alpha" channel.
    float exposure = texelFetch(colortex0, ivec2(0), 0).a;
    if (exposure <= 0.001 || isnan(exposure) || isinf(exposure)) {
        exposure = 1.3;
    }

    vec3 bloomAtlas = vec3(0.0);
    #ifdef BLOOM
        vec2 scaledCoord = texCoord * bloomAtlasRescale();
        bloomAtlas = BuildBloomAtlas(scaledCoord);
    #endif

    /* DRAWBUFFERS:35 */
    gl_FragData[0] = vec4(bloomAtlas, 1.0);   // colortex3 = packed atlas
    gl_FragData[1] = vec4(sceneColor, exposure); // colortex5 = TAA history + exposure
}

#endif
