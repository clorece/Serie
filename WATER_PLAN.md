# SerieVX — Physically-Accurate Water Rendering Plan

Status: PLAN ONLY (not implemented). Authored 2026-05-28.
Derived from inspecting **iterationRP Alpha 0.8.22**, **MollyVX-2025-1.1**, **Alpha-Piscium-main**,
and **zephyr-starlight-v0.2.2a-hotfix1** water rendering, fitted to SerieVX's voxel-PT pipeline.

---

## 0. Current state (baseline)

`shaders/program/gbuffers/water.glsl` is bare:
- VS: `ftransform()`, passes geometric `normal`, lightmap, vertex `color`, applies TAA jitter.
- FS: `albedo = texture(tex)*color`; `gl_FragData[0]=albedo` (colortex0), `gl_FragData[1]=vec4(normal*0.5+0.5,0)` (colortex1).

Because Iris renders `gbuffers_water` **after** the whole deferred chain (which already wrote the fully-lit
opaque scene + sky to colortex0 in d7/d8), the current pass **clobbers the lit scene with a flat water texture**.
No waves, no Fresnel, no reflections, no refraction, no absorption, no underwater handling.

### Pipeline order (verified on disk)
```
shadow → gbuffers_{terrain,entities,hand,particles,clouds}
       → deferred d0_restir … d7_composite, d8_fog_sky   [lit opaque + sky → colortex0]
       → gbuffers_water        ← WATER LIVES HERE (translucent forward pass)
       → composite0 c0_taa → composite1 c1_bloom_atlas → composite2 c2_bloom_finalize → final
```

### Reusable infrastructure already in SerieVX (no new tracer needed)
- `lib/pt/ddaTrace.glsl`: `traceVoxelRay(...)` (Amanatides-Woo voxel DDA, **auto-falls back to** `screenSpaceRayTrace`),
  and `screenSpaceRayTrace(... out hitUV, hitNormal, hitPos)`.
- `lib/pt/gi.glsl`: `giRayRadiance(...)`, `computeGI(...)` — full radiance along a ray (voxel + colortex5 cache + sky).
- `lib/fragment/sky.glsl`: `getSky(rd, sunDir, moonDir, eyeAltitude)`; `lib/fragment/atmosphere.glsl`:
  `GetAtmosphere`, `GetAtmosphereTransmittance`.
- Uniforms present: `noisetex`, `depthtex0` (water+opaque), `depthtex1` (opaque only), `colortex0` (lit opaque scene),
  `colortex5` (prev-frame HDR / TAA history), `frameTimeCounter`, `cameraPosition`, all gbuffer/projection matrices.
  (`isEyeInWater`, `sunPosition`/`shadowLightPosition` etc. to be added to `lib/uniforms.glsl` if missing.)
- Free buffer slots: **colortex4, colortex12, colortex13 were deleted** → one can be re-declared as a dedicated,
  single-writer water buffer with **no ping-pong parity risk** (~16 MB at 1080p, RGBA16F).

### What each reference pack taught us
| Pack | Wave normals | Reflection | Refraction | Fog / absorption | Notable |
|---|---|---|---|---|---|
| **iterationRP** | noisetex multi-octave height + finite-diff normal; optional POM parallax; detail octaves | voxel `SpecularTracing` (occluded water), else sky cubemap; Fresnel Schlick | screen-space UV offset by refracted ray, depth-guarded | Beer-Lambert `exp2(-att·d)` + sun-tinted in-scatter; sep. above/under water | **Deferred water**: gbuffer stores wave normal + dist-to-opaque + flag; composite does the rest |
| **MollyVX** | two models — Shadertoy "Seascape" iterative octaves AND Gerstner (`w=√(gk)`, wind dir); parallax | path-traced GGX reflect ray + Schlick3 (uses its probe/voxel scene) | (in deferred apply) | — | `calculateSnellsWindow` (TIR when `cosθ ≤ -1/1.336`) |
| **Alpha-Piscium** | curl-distorted multi-octave noise, golden-angle rotation, base+detail | SS-trace via VNDF micro-normal; **env-probe cubemap** + sky LUT fallback; squircle edge-fade | SS-trace refracted micro-normal, IOR edge fix, geom-normal blend | Beer-Lambert absorption→transmittance (luma-normalized) | Full **PBR microfacet** combine: `Ft·albedo·refract + reflectance·reflect + specular`, Smith G2/G1 + pdfRatio |
| **Zephyr** | FBM value-noise, **precomputed into 512² normal texture** (±32 blk @ 1/8 res) by a compute pass | octree ray-trace reflect, lit via IC + Cook-Torrance; sky on miss | **multi-bounce** refract ray-trace through octree, throughput tint | per-channel `waterTransmittance = exp(-abs·d)` | **caustics** `calcWaterCaustics` (exp of dot(rayDir, waveN)·depth); SSS on refract hits |

**Consensus pattern:** all four **defer** water to a composite/SST pass that reads the intact lit scene + water
G-buffer + depth, and shade reflection/refraction/fog there. SerieVX should adopt the same — it avoids the
read-after-write hazard of sampling colortex0 while writing it, and it lets us reuse the existing voxel/SS tracer.

---

## Target architecture for SerieVX

Convert water to a **deferred composite** model:

1. `gbuffers_water` becomes a **G-buffer writer only** (no color clobber). It writes the wave-perturbed normal and a
   water material flag; it does **not** write colortex0, so colortex0 stays the lit opaque scene = the refraction background.
2. A new **`composite0` water pass** (`program/composite/c_water.glsl`) runs first in the composite chain. It reads
   colortex0 (background), the water normal/flag, `depthtex0` (water surface) and `depthtex1` (opaque behind), then
   computes refraction + reflection + Fresnel + absorption/fog and writes the composited result back to colortex0.
3. Existing composite passes shift down one slot: `c0_taa → composite1`, `c1_bloom_atlas → composite2`,
   `c2_bloom_finalize → composite3`, `final` unchanged.

**Parity safety:** the single colortex0 write simply **moves** from `gbuffers_water` to `c_water` (net write count
unchanged). `c_water` must **not** write colortex3 (keeps the documented 7-writes/frame bloom ping-pong parity intact).
Water G-buffer data goes in a re-declared dedicated buffer (reuse the freed **colortex4** slot) — single writer
(`gbuffers_water`) + single reader (`c_water`), so no flip-parity hazard.

### Buffer usage
- **colortex1**: keep `.rgb = wave-perturbed view normal`, `.a = water material code`. Safe — colortex1 is regenerated
  every frame and nothing in composite reads it. Lets the water normal optionally feed back into screen-space effects.
- **colortex4 (re-declare, RGBA16F, clear=true)**: `.rgb = water albedo/biome tint`, `.a = skylight (lightmap.y) + water flag`.
  (Or pack flag into colortex1.a as a distinct material code and use colortex4.a for foam/skylight.)
- Thickness is **free**: `thickness = linearize(depthtex1) − linearize(depthtex0)` at water pixels. No buffer needed.

---

## Phase 0 — Architecture switch (no visual features yet)
**Goal:** move water to the deferred model; output must look identical to today (flat textured water) before adding effects.
- `shaders.properties`: add `blend.gbuffers_water=off` (we composite manually; avoids double-blend).
- Rewrite `program/gbuffers/water.glsl` FS to write only the water G-buffer (normal+flag+albedo), not colortex0.
- Add `program/composite/c_water.glsl` + `world0/composite.{fsh,vsh}` wrapper (`DRAWBUFFERS:0`), reading the water
  G-buffer and, for now, just `mix(background, waterAlbedo, alpha)` to reproduce current look.
- Renumber the three existing composite wrappers (`composite{1,2,3}`) + update their `DRAWBUFFERS`/includes.
- Re-declare `colortex4Format = RGBA16F; colortex4Clear = true;` in `lib/pipelineSettings.glsl`.
- **Acceptance:** in-game water looks like the current build; no parity/stale-buffer artifacts (watch corners + bloom).

## Phase 1 — Wave normals
**Goal:** animated surface normals driving everything downstream.
- New `lib/fragment/water.glsl`: procedural wave **height field** + **finite-difference normal** (the technique all four
  packs share). Recommend the **analytic FBM** approach (Zephyr/MollyVX — no texture dependency, cheap, tileable) with a
  `noisetex` variant available (iterationRP) behind a define. Multi-octave, time-animated, wind-directional.
  - `WaveHeight(worldPos)` → sum of N octaves (rotate + scale + advect each), squared/curved for choppiness.
  - `WaveNormal(worldPos)` → central/forward differences in x,z; `normalize(vec3(dHdx, dHdz, 1/strength))`.
- In `gbuffers_water` VS: pass world position; FS: build TBN from the geometric (mostly +Y) water normal, perturb with
  `WaveNormal`, transform to view space, store in colortex1.rgb.
- Options: `WAVE_SCALE`, `WAVE_SPEED`, `WAVE_HEIGHT`, `WAVE_STRENGTH`, `WAVE_OCTAVES`, `WIND_DIRECTION`.
- (Optional, perf) Precompute the wave normal into a small 512² texture each frame via a tiny deferred/compute pre-pass
  (Zephyr) and sample it — improves temporal stability + cost; defer to a later optimization pass.
- **Acceptance:** rippling normals visible (debug-view the normal); no shading yet.

## Phase 2 — Refraction + absorption
**Goal:** see a tinted, refracted background through the surface.
- In `c_water`: reconstruct water-surface view pos (`depthtex0`) and opaque-behind view pos (`depthtex1`) → `thickness`.
- `refractDir = refract(viewDir, waterNormal, AIR_IOR/WATER_IOR)` (`WATER_IOR≈1.33`). Project `viewPos + refractDir*k`
  to screen UV, sample `colortex0` there. **Depth-guard**: if the sampled opaque is nearer than the water surface, fall
  back to the un-offset UV (prevents foreground bleeding into the water — iterationRP/Alpha-Piscium do this).
- **Absorption** (Beer-Lambert, per-channel): `refractColor *= exp(-WATER_ABSORPTION_RGB * thickness)`.
- Options: `WATER_REFRACTION` (toggle), `WATER_IOR`, `WATER_REFRACT_STRENGTH`, `WATER_ABSORPTION_R/G/B`.
- **Acceptance:** submerged terrain wobbles with waves and darkens/tints with depth.

## Phase 3 — Reflections + Fresnel
**Goal:** sky + scene reflections, energy-correct against refraction.
- **Fresnel** (Schlick, `F0 ≈ 0.02` for water): `F = fresnelSchlick(dot(viewDir, waterNormal), F0)`.
- `reflectDir = reflect(viewDir, waterNormal)`; guard against reflecting below the surface (Alpha-Piscium clamps with the
  geometric normal).
- **Reflection radiance** — reuse the existing tracer: call `traceVoxelRay` (voxel DDA, auto SS-fallback) from the surface
  along `reflectDir`; on hit, read radiance from `colortex5`/`colortex0` (reproject like d0_restir's cache), on miss call
  `getSky(reflectDir, …)`. This mirrors iterationRP (voxel specular + sky fallback) and Zephyr (octree reflect + sky).
- Combine: `color = mix(refractColor, reflectColor, F)` (energy-conserving; refraction already absorbed).
- **Roughness:** calm water = mirror; for choppy/rainy water, jitter `reflectDir` in a small cone (optional GGX VNDF micro-normal
  à la Alpha-Piscium) and rely on temporal accumulation.
- **Temporal stability:** traced reflections are noisy. Either lean on the existing TAA (note: ghosting on the moving
  surface — tune motion-vector handling) or add a small reflection history buffer (iterationRP `SST_TEMPORAL`,
  Alpha-Piscium transient reflection). Start with TAA; add history only if needed.
- Options: `WATER_REFLECTIONS` (toggle), `WATER_REFLECT_TRACE` (`voxel`/`SS`/`sky-only`), `WATER_ROUGHNESS`,
  `WATER_REFLECT_QUALITY` (steps), gated by a half-res option for perf.
- **Acceptance:** sky + nearby geometry reflect; grazing angles brighten (Fresnel), top-down sees mostly through.

## Phase 4 — Water fog / lighting / underwater
**Goal:** physically-plausible volume + correct camera-underwater behaviour.
- **Above water:** add a sun-tinted in-scatter term over `thickness` (iterationRP `WaterFog`): combine the per-channel
  absorption above with `+ scattering * (1 − exp(-thickness*density))`, `scattering` driven by sun/sky color and a phase
  term toward the refracted sun direction.
- **Eye-in-water (`isEyeInWater==1`):** apply full-screen water fog to *opaque* pixels seen through water, plus view
  transmittance on reflection/refraction (Zephyr/iterationRP). Handle **Snell's window** + **total internal reflection**
  (MollyVX `calculateSnellsWindow`: TIR when `cosθ ≤ -1/IOR`; Alpha-Piscium inverts IOR underwater).
- **Underwater god-rays:** optional — reuse the existing volumetric-light machinery.
- Options: `WATER_FOG` (toggle), `WATER_SCATTERING_R/G/B`, `WATER_SCATTERING_DENSITY`.
- **Acceptance:** depth reads as real volume; going underwater fogs + shows Snell's window/TIR correctly.

## Phase 5 — Caustics (optional, last)
**Goal:** dappled light on submerged surfaces.
- Cheapest: screen-space caustic on the refraction background — `calcWaterCaustics`-style (Zephyr):
  `exp(strength * f(rayDir, waveNormal) * depth)` applied to `refractColor`.
- Higher quality: project wave normal in the shadow pass / a caustic LUT and modulate sunlight on underwater terrain in
  `d7_composite` (iterationRP bakes into shadowcolor).
- Options: `WATER_CAUSTICS` (toggle), `WATER_CAUSTICS_STRENGTH`.

---

## Cross-cutting
- **Options:** new block in `lib/options.glsl` + a `screen.Water` page in `shaders.properties` (add `[Water]` to the
  Path-Tracing or a new top-level screen) + sliders. Group: waves, refraction, reflections, fog, caustics.
- **Naming:** `lib/pt` and `lib/fragment` are **camelCase** on disk (`traceVoxelRay`, `getSky`); the project naming note
  prefers PascalCase. **Confirm with user** — recommend matching the local file convention (camelCase in lib/pt &
  lib/fragment) for new water functions to stay consistent with the tracer/sky code they call.
- **DH-awareness:** later — trace/refract against `dhDepthTex` for far water, like iterationRP.

## Risks / watch-list
- **Ping-pong parity:** keep `c_water` off colortex3; verify colortex0 write count is unchanged after the gbuffers_water→
  c_water move (documented "stale buffer" lesson: garbage in screen corner + red blowout = parity broken).
- **Read-after-write:** avoided by the deferred design (don't sample colortex0 inside gbuffers_water).
- **TAA ghosting** on the moving surface + noisy traced reflections — primary tuning risk in Phase 3.
- **Perf:** per-pixel reflection tracing is the cost driver — gate behind a quality preset + optional half-res + the
  precomputed wave-normal texture.
- **Suggested order:** Phase 0 → 1 → 2 → 3 → 4 → 5, validating in-game after each (can't compile from WSL).
