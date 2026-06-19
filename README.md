# Serie

<img width="2560" height="1440" alt="Serie shaderpack screenshot" src="https://github.com/user-attachments/assets/499510fa-0233-4d3f-b1a8-2efa26ad1026" />

Serie is an experimental path-traced shaderpack for Minecraft Java Edition. It combines physically inspired lighting with art-directable atmosphere, clouds, water, color grading, and material controls.

The current renderer uses a voxelized world representation for path-traced indirect light, a world-space irradiance cache for multi-bounce lighting, and temporal/spatial filtering to produce a stable image at different render resolutions.

> [!IMPORTANT]
> Serie is under active development. Expect settings, buffer layouts, and visual behavior to change between builds.

## Requirements

- Minecraft Java Edition
- A recent version of [Iris Shaders](https://irisshaders.dev/)
- A GPU and driver with OpenGL 4.3 support
- Iris custom-image support (required by the voxel and irradiance-cache volumes)
- Distant Horizons is optional

Serie is developed for Iris. OptiFine is not currently supported.

## Current features

### Path-traced lighting

- Voxelized scene representation with hierarchical empty-space skipping
- Per-pixel voxel GI rays
- Persistent world-space irradiance cache for multi-bounce color bleeding
- Temporal accumulation and four-stage edge-aware à-trous filtering
- Emissive voxel lighting for lava, torches, lanterns, redstone, and other light-emitting blocks
- Shaped voxel intersections for supported non-cubic blocks
- GTAO contact shading with temporal accumulation
- Debug views for GI, AO, voxel data, and lighting isolation

### Shadows and direct lighting

- Distorted high-resolution shadow map
- PCSS-style variable soft shadows
- Colored/translucent shadow support
- Screen-space contact and extended shadows
- Cloud shadows
- Foliage and subsurface-style lighting treatment

### Atmosphere and volumetrics

- LUT-based Rayleigh, Mie, and ozone atmospheric scattering
- Sun and moon lighting with atmospheric extinction
- Aerial perspective and Distant Horizons fog integration
- Belt of Venus / Earth-shadow treatment around twilight
- Shadow-aware volumetric light shafts
- Volumetric cumulus clouds with self-shadowing and multi-scattering
- A separate volumetric altocumulus layer
- Wind-driven clouds, distance erosion, atmospheric haze, and cloud shadows

### Water and transparent materials

- Procedural multi-octave water waves
- Water parallax and vertex displacement
- Screen-space refraction and reflection
- Reflected sky and volumetric clouds
- Depth-based absorption and in-scattering
- Underwater fog, optional god rays, and total internal reflection
- Procedural caustics on submerged terrain
- Generated normals and refraction handling for glass and ice
- Near and Distant Horizons water integration

### Integrated PBR

- Block-class material system for metals, polished stone, ceramics, gems, wood, terrain, and other surfaces
- Per-texel smoothness variation derived from material color
- Generated bump normals from texture luminance
- GGX VNDF importance-sampled reflections
- Screen-space scene reflections with atmospheric and GI fallback lighting
- Temporal and bilateral spatial reflection denoising
- Direct sun and moon specular highlights

Serie currently uses its own integrated material classification rather than a complete LabPBR texture-pack workflow.

### Post-processing

- Temporal anti-aliasing and temporal upscaling
- TAA, TAAU/Catmull-Rom, and Lanczos reconstruction modes
- Configurable internal render scale
- Bloom
- Automatic exposure
- Multiple tone-mapping operators
- Contrast, saturation, temperature, sharpening, and optional vignette controls

### Distant Horizons

- Distant terrain and water rendering
- Consistent direct lighting and atmospheric fog
- Far screen-space terrain shadows
- Volumetric-light integration
- Dedicated temporal reprojection for DH geometry

## Installation

### Release build

1. Download a ZIP from the repository's [Releases page](https://github.com/clorece/Serie/releases).
2. Place the ZIP in your Minecraft `shaderpacks` directory.
3. Open Minecraft with Iris installed.
4. Select Serie from **Options → Video Settings → Shader Packs**.

Do not extract a release ZIP unless its outer archive contains another shaderpack folder or ZIP.

### Latest repository build

1. Select **Code → Download ZIP** on the [GitHub repository](https://github.com/clorece/Serie).
2. Extract the downloaded repository archive.
3. Place the folder containing `shaders/`, `README.md`, and `License.txt` in your `shaderpacks` directory.

Repository builds contain the newest changes and may be less stable than releases.

## Performance guide

Serie is intentionally GPU-heavy. Internal resolution, path tracing, shadows, reflections, and clouds are normally the largest costs.

Adjust these settings first, in roughly this order:

1. **Render Scale** — the strongest general performance control. The default `0.67` renders about 45% as many internal pixels as native resolution before temporal reconstruction.
2. **IRC Quality** — controls the size of the world-space irradiance cache. `0` is substantially lighter than `1` or `2`.
3. **Reflection Smoothness Minimum** — raising this skips reflections on matte materials while preserving polished surfaces and metals.
4. **Reflection Rays / Steps** — reduce rays before aggressively reducing march distance.
5. **Shadow Resolution / Filter Quality** — shadow filtering affects most visible terrain pixels.
6. **Cloud Primary, Light, and Multi-Scatter Steps** — lower light steps first; TAA hides moderate cloud undersampling well.
7. **GTAO Slices / Steps** — one rotating slice is a good performance option when TAA is enabled.
8. **Voxel Distance / GI Radius** — reduce these last because they control lighting coverage and off-screen information.

Suggested starting points:

| Setting | Performance | Balanced | Quality |
|---|---:|---:|---:|
| Render Scale | 0.50 | 0.67 | 0.77–1.00 |
| IRC Quality | 0 | 1 | 1–2 |
| Shadow Resolution | 2048 | 3072 | 4096 |
| Shadow Filter Quality | 6–8 | 10–12 | 14–16 |
| Reflection Rays | 1 | 2–3 | 3–4 |
| Reflection Steps | 20–24 | 32 | 48 |
| Reflection Smoothness Minimum | 0.25 | 0.12 | 0.04 |
| Cloud Primary Steps | 8 | 16 | 24–32 |
| Cloud Light Steps | 2 | 3–4 | 6 |
| GTAO Slices × Steps | 1 × 3 | 2 × 4 | 3 × 4 |
| Voxel Distance | 8 | 12 | 16 |

These are starting points, not bundled presets. Performance varies considerably by GPU, output resolution, render distance, biome, and the amount of reflective material or water on screen.

## Settings

The in-game shader menu is divided into:

- Light and shadow filtering
- Terrain and Distant Horizons
- Water
- Integrated PBR
- Volumetric lighting
- Atmosphere
- Clouds
- Post-processing and TAA
- Path tracing, irradiance cache, and ambient occlusion

After changing a compile-time option, allow Iris to reload the pack. Temporal GI, reflections, clouds, and TAA may need several frames to settle after a reload or large camera movement.

## Current limitations

- The pack is primarily focused on the Overworld renderer.
- Integrated PBR coverage is driven by Serie's block/material mappings; unsupported or newly added blocks may fall back to a generic material.
- Screen-space reflections and refractions cannot reproduce geometry that is unavailable to the current or previous frame.
- Voxel lighting covers a finite camera-centered volume. Distant surfaces use raster, sky, or atmospheric fallback lighting.
- Fast camera movement, teleporting, dimension changes, and shader reloads temporarily invalidate temporal histories.
- Compatibility with other rendering mods is not guaranteed.

## Reporting bugs

Please open an issue on the [GitHub Issues page](https://github.com/clorece/Serie/issues) and include:

- A concise description of the problem
- Steps and a location/scene that reproduce it
- Minecraft, Iris, loader, and mod versions
- GPU model and driver version
- The active Serie settings or an exported shader configuration
- Screenshots or video when the issue is visual
- `latest.log` when the pack fails to load or reports a shader compilation error

Before reporting a visual artifact, test once with default settings and confirm whether Distant Horizons or another rendering mod is involved.

## Development status

The repository branch is the active development version. Stable builds, when available, are published through [GitHub Releases](https://github.com/clorece/Serie/releases).

Contributions and focused bug reports are welcome. When changing shader code, test at multiple render scales, during camera motion, at day/night transitions, underwater, and with Distant Horizons both enabled and disabled.

## License

Original Serie code is available under the custom [Serie Shaderpack License 1.0](License.txt) (`LicenseRef-Serie-1.0`). It allows gameplay, monetized screenshots and videos, qualifying modpack distribution, and meaningfully modified source-available forks under the conditions in the license.

Serie may not be sold or placed behind paid access. Standalone reuploads, closed-source forks, settings-only repacks, confusing use of the Serie name, and claims of official endorsement are not permitted. Material with third-party origins remains subject to its original terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
