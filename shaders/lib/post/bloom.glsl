#ifndef BLOOM_GLSL
#define BLOOM_GLSL

// ============================================================================
//  Multi-scale bloom atlas (industry-standard for Iris)
// ----------------------------------------------------------------------------
//  Seven mip tiles (LOD 2..8) of the TAA-resolved HDR scene are packed into
//  colortex3 by c1_bloom_atlas. final.glsl reads the tiles back, unpacks them
//  and blends with the scene. Mip-sampling colortex0 means the heavy spatial
//  averaging is done by the GPU's mipmap unit; the explicit 7-tap binomial
//  kernel below is the final smoothing on top of the mip.
//
//  HDR range compression: tiles are stored as pow(x/128, 0.25). The fourth-
//  power unpack on read restores linear radiance AND acts as an implicit
//  highlight bias (dim pixels collapse toward zero), removing the need for a
//  classic luma threshold.
// ============================================================================

const float bloomTileLods[7] = float[](2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
const vec2  bloomTileOffsets[7] = vec2[](
    vec2(0.0,       0.0    ),
    vec2(0.0,       0.26   ),
    vec2(0.135,     0.26   ),
    vec2(0.2075,    0.26   ),
    vec2(0.135,     0.3325 ),
    vec2(0.160625,  0.3325 ),
    vec2(0.1784375, 0.3325 )
);
// Soft de-weighting of the lowest-frequency tiles to keep the bloom from
// turning into a screen-wide milky tint at high BLOOM_STRENGTH.
const float bloomTileWeights[7] = float[](1.0, 1.0, 1.0, 0.8, 0.8, 0.6, 0.4);

// 1080p reference rescale so the atlas UV layout is resolution-independent.
// The same rescale must be applied identically on build and read.
vec2 bloomAtlasRescale() {
    return max(vec2(viewWidth, viewHeight) / vec2(1920.0, 1080.0), vec2(1.0));
}

// Build one tile of the atlas. Pixels outside the tile's footprint return 0.
// `scaledCoord` is texCoord * bloomAtlasRescale() (caller-precomputed).
vec3 BuildBloomTile(float lod, vec2 offset, vec2 scaledCoord) {
    float scale = exp2(lod);
    vec2 coord = (scaledCoord - offset) * scale;
    float padding = 0.5 + 0.005 * scale;

    if (abs(coord.x - 0.5) >= padding || abs(coord.y - 0.5) >= padding) {
        return vec3(0.0);
    }

    // 7-tap binomial Gaussian sampled from the matching mip level of colortex0.
    const float w[7] = float[](1.0, 6.0, 15.0, 20.0, 15.0, 6.0, 1.0);
    vec2 view = vec2(viewWidth, viewHeight);
    vec3 bloom = vec3(0.0);
    for (int i = -3; i <= 3; i++) {
        for (int j = -3; j <= 3; j++) {
            float wg = w[i + 3] * w[j + 3];
            vec2 pixelOffset = vec2(i, j) / view;
            vec2 srcCoord = (scaledCoord - offset + pixelOffset) * scale;
            bloom += textureLod(colortex0, srcCoord, lod).rgb * wg;
        }
    }
    bloom /= 4096.0;  // 1 / sum(w_i * w_j)

    // Pack as pow(x/128, 0.25) so RGBA16F holds ~128-unit HDR range without clipping.
    return pow(max(bloom * (1.0 / 128.0), vec3(0.0)), vec3(0.25));
}

vec3 BuildBloomAtlas(vec2 scaledCoord) {
    vec3 atlas = vec3(0.0);
    for (int i = 0; i < 7; i++) {
        atlas += BuildBloomTile(bloomTileLods[i], bloomTileOffsets[i], scaledCoord);
    }
    return atlas;
}

// Read one tile of the atlas. Reverses the gamma-4 pack and applies tile weight.
vec3 SampleBloomTile(sampler2D atlasTex, float lod, vec2 tileOffset, vec2 coord, vec2 rescale) {
    float scale = exp2(lod);
    vec2 bloomCoord = coord / scale + tileOffset;
    // Clamp UV into the tile interior so bilinear taps near the tile edge
    // do not bleed in neighbouring (or zero) padding pixels.
    bloomCoord = clamp(bloomCoord, tileOffset, 1.0 / scale + tileOffset);

    vec3 sampled = texture(atlasTex, bloomCoord / rescale).rgb;
    sampled *= sampled;
    sampled *= sampled;       // x^4 unpack
    return sampled * 128.0;
}

vec3 ReadBloomAtlas(sampler2D atlasTex, vec2 coord) {
    vec2 rescale = bloomAtlasRescale();
    vec3 sum = vec3(0.0);
    for (int i = 0; i < 7; i++) {
        sum += SampleBloomTile(atlasTex, bloomTileLods[i], bloomTileOffsets[i], coord, rescale)
             * bloomTileWeights[i];
    }
    // sum(weights) ≈ 5.6; *0.14 normalises to a perceptual mid-gray bloom intensity
    // (matches Allium/Complementary's DoBloom factor).
    return sum * 0.14;
}

#endif
