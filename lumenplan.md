Context

Repo: /home/clorece/.local/share/ModrinthApp/profiles/Fabric 26.2/shaderpacks/Serie
(a Minecraft Iris shaderpack — not the sibling Allium pack, which is a screen-space fork)

Goal: replace Serie's ReSTIR GI + SVGF denoiser + screen-space reflections with a
software-raytraced Lumen-style system: a persistent world-space surface cache holding lit
radiance, a world radiance cache of probes for far field, screen probes for the final
gather, and reflections that reuse the same tracing stack.

Why Lumen's shape specifically. Lumen decouples lighting from tracing: rays do not shade at
the hit point, they look up a cache. Lighting cost becomes O(cache size) instead of O(rays),
which is what makes multi-bounce and reflections nearly free once diffuse GI is paid for.
Minecraft makes this unusually cheap — Lumen's hardest problem is placing orthographic "cards"
over arbitrary meshes, and on axis-aligned unit cubes that problem vanishes. Voxel faces are
the cards.

Common misconception to avoid: Lumen is not primarily screen-space. Screen traces are only
the first link in a fallback chain (screen → mesh/global SDF or hardware BVH → world radiance
cache → sky), and they exist to patch gaps the world-space representation cannot resolve.
Screen-space-only means no off-screen occlusion, no light from behind the camera, and
reflections that can only show what is already on screen — i.e. SSGI+SSR, which is what this
work is moving away from. The design below is hybrid, exactly like real Lumen.

---
Ground truth about the current tree

Serie has ~8,440 lines of uncommitted, unpushed work. main is level with origin/main;
there are no stashes. This work is the foundation for this plan and must be committed before
anything is deleted.

┌──────────────────┬───────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│    Component     │                                 File                                  │                                 What it is                                                               │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Cascaded clipmap │ shaders/lib/pt/voxelCascade.glsl                                      │ 4 cascades, 192³ voxels each, at 1/2/4/8 blocks per voxel → 192/384/768/1536 block reach. Stacked into one 192×512×192 R32UI image.   │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Voxel word       │ shaders/lib/pt/voxelFormat.glsl                                       │ R32UI: [2:0] category, [12:3] shapeId, [15:13] spare, [31:16] payload (RGB565 albedo, or light material id).                          │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Traversal        │ shaders/lib/pt/voxelTrace.glsl                                        │ traceVoxelCascaded() / traceVoxelOccluded(), brick (8³) + super-brick (64³) empty-space skipping.                                     │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Block BLAS       │ shaders/lib/pt/blas.glsl, shapeTable.glsl                             │ 761 shapes / 3080 boxes generated from Minecraft's own model JSON by scripts/gen_block_shapes.py. Being disabled — see Phase 2.       │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Emitter shapes   │ shaders/lib/pt/lightShapes.glsl                                       │ Hand-written occluder-box vs emissive-box split per emitter (torch post vs flame cap). Independent of the generated BLAS. Stays live. │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Entity BVH       │ shaders/lib/pt/entityBvh.glsl, program/shadowcomp/sc0_entity_bvh.glsl │ Per-frame entity AABBs via atomics, keyed on a hash of each entity's render origin.                                                   │
├──────────────────┼───────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Voxelizer        │ shaders/program/gbuffers/shadow.glsl                                  │ Writes all ss.                                                                                           │
└──────────────────┴───────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Compute shaders and SSBOs are already in use: world0/setup.csh, world0/shadowcomp.csh,
bufferObject.0 (64 KB shape table), bufferObject.1 (256 KB entity BVH).
iris.features.required = CUSTOM_IMAGES SSBO (shaders.properties:56).

Decisions already made

- Compute shaders (.csh): adopt — already the precedent in this tree.
- Surface cache: full Lumen-style decoupled cache, not shade-on-hit.
- VRAM budget: generous, 8 GB+ target.
- Distant Horizons: near-field only — keep shadeDhTerrain on analytic ambient, but drive
its giSky from one far-field value from the new tracer instead of the duplicated pipeline
at d7_composite.glsl:242-258.
- Sub-block intersection: disabled behind a flag, not deleted (idea pending for later).

---
Phase 0 — Preserve the foundation

git -C <Serie> checkout -b lumen-experimental
git -C <Serie> add -A && git -C <Serie> commit    # checkpoint: cascade + BLAS + entity BVH

Nothing else may be deleted until this commit exists. Verify with git log --stat -1.

---
Phase 1 — Wipe the lighting layers

Delete outright:

┌───────────────────────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────┐
│                                       Path                                        │                                             Role                                             │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d0_restir.glsl                                                   │ ReSTIR initial sampling + temporal reuse                                                     │
├───────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ program/deferred/d0_accum.glsl                                                    │ temporal accum + spatial ReSTIR + GTAO                                                       │
├───────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ program/deferred/d0b_historyfix.glsl                                              │ disocclusion prefilter                                                                       │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d1_atrous_first.glsl, d1..d4_denoise.glsl, d_denoise_common.glsl │ SVGF a-trous chain                                              │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d7b_reflections.glsl, d7c_reflection_spatial.glsl                │ screen-space refle                                              │
├───────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ lib/pt/restir.glsl, denoise.glsl, historyfix.glsl, gi.glsl, ao.glsl, gtao.glsl    │ supporting libs                                                                              │
├───────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ lib/util/distort.glsl                                                             │ orphaned, included shadow distortion than the live one — a trap │

---
Phase 0 — Preserve the foundation

git -C <Serie> checkout -b lumen-experimental
git -C <Serie> add -A && git -C <Serie> commit    # checkpoint: cascade + BLAS + entity BVH

Nothing else may be deleted until this commit exists. Verify with git log --stat -1.

---
Phase 1 — Wipe the lighting layers

Delete outright:

┌───────────────────────────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────┐
│                                       Path                                        │                                             Role                                             │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d0_restir.glsl                                                   │ ReSTIR initial sampling + temporal reuse                                                     │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d0_accum.glsl                                                    │ temporal accum + spatial ReSTIR + GTAO                                                       │
├───────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
│ program/deferred/d0b_historyfix.glsl                                              │ disocclusion prefilter                                                                       │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d1_atrous_first.glsl, d1..d4_denoise.glsl, d_denoise_common.glsl │ SVGF a-trous chain                                                                           │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ program/deferred/d7b_reflections.glsl, d7c_reflection_spatial.glsl                │ screen-space reflections                                                                     │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ lib/pt/restir.glsl, denoise.glsl, historyfix.glsl, gi.glsl, ao.glsl, gtao.glsl    │ supporting libs                                                 │
├───────────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ lib/util/distort.glsl                                                             │ orphaned, included shadow distortion than the live one — a trap │
└───────────────────────────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────┘

Also delete these dead blocks in program/deferred/d7_composite.glsl:
- :357-386 — SSPT debug block calling sspt_dbgHemisphere / traceScreenSpace, neither of
which exists in this pack. Already broken.
- :431-477 — the indirect #if ladder (replaced in Phase 4).

Harvest before deleting (copy into a new lib/pt/sampling.glsl + lib/pt/reproject.glsl):

┌──────────────────────────────────────────────────────────────┬─────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┐
│                           Function                           │                From                 │                                                             Why                                                             │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ clipHistoryMoments(vec3,vec3,vec3)                           │ denoise.glsl:28                     │ YCoCg history clamp                                                                                                         │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ svgfVarianceFloor(float)                                     │ denoise.glsl:156                    │ l                                                                                              │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ getJitterRotation(vec2,int)                                  │ denoise.glsl:186                    │ TAA-phase-locked kernel rotation                                                                                            │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ HF_DISK[16] Vogel disk                                       │ historyfix.glsl:30                  │ spatial filter kernel                                                                                                       │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ historyFixGI(...)                                            │ historyfix.glsl:43                  │ disocclusion fill — reusable verbatim                                                                                       │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ buildTBN / cosHemisphereDir                                  │ ao.glsl:7,14                        │ re-home, still needed                                                                                                       │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ stbnCosineHemisphere(vec3,ivec2,int)                         │ restir.glsl:109                     │ blue-noise cosine hemisphere                                                                                                │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ uniform sampler3D blueNoise decl                             │ restir.glsl:89                      │ must be re-declared somewhere included after options.glsl — see uniforms.glsl:76-80 for why it cannot live in uniforms.glsl │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ sampleGGXVNDF, smithGGX_v1/v2, fresnelSchlick, tbnFromNormal │ lib/fragment/reflections.glsl:11-45 │ BRDF core, geometry-agnostic                                                                                                │
└──────────────────────────────────────────────────────────────┴─────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Keep lib/fragment/reflections.glsl but strip refl_viewToScreen:51 and
traceReflectionSSR:58 (screen-space specific).

Also clean: every removed option must come out of shaders.properties screen.* menus and
the giant sliders= line (:47), or the UI leaves stale text-cycle entries. Remove
screen.SVGF (:42), screen.ReSTIR (:43), screen.Ambient-Occlusion (:44),
screen.Voxel-AO (:45).

---
Phase 2 — Disable sub-block intersection

Everything traces as a full cube. Keep the code and the shape table in the tree, gated on a
new #define VOXEL_BLAS in options.glsl (default off).

Exactly five call sites in lib/pt/voxelTrace.glsl:

┌──────┬──────────────────────────────┬──────────────────────────────────────────────┐
│ Line │             Call             │           Behaviour with BLAS off            │
├──────┼──────────────────────────────┼──────────────────────────────────────────────┤
│ :170 │ intersectLightShape(...)     │ keep — emitter shapes stay live              │
├──────┼──────────────────────────────┼──────────────────────────────────────────────┤
│ :176 │ lightOccluderAabb(...)       │ keep                                         │
├──────┼──────────────────────────────┼──────────────────────────────────────────────┤
│ :183 │ intersectShape(shapeId, ...) │ skip; use the DDA's tLocal + lastMask normal │
├──────┼──────────────────────────────┼──────────────────────────────────────────────┤
│ :198 │ lightEmisFactor(...)         │ keep                                         │
├──────┼──────────────────────────────┼──────────────────────────────────────────────┤
│ :320 │ occludeShape(shapeId, ...)   │ skip; !first → return true                   │
└──────┴──────────────────────────────┴──────────────────────────────────────────────┘

Do not simply turn off the existing VOXEL_SHAPES define. Its #else branch at
shaders/program/gbuffers/shadow.glsl:110-111 maps shaped blocks to VOXEL_AIR, which deletes
every stair, slab, fence and wall from the grid rather than cubing them. Leave VOXEL_SHAPES on
so shapeId keeps being written into the voxel word (free — the bits already exist), and gate
only the trace-side calls. That makes re-enabling later a one-line change.

setup.csh / the shape SSBO can stay resident; it costs 24 KB and runs once at load.

---
Phase 3 — The Lumen stack

3.1 Surface cache (the core)

Per-voxel-face radiance for cascade 0 only (1 block/voxel, 192 block reach). Beyond cascade 0,
rays fall back to the radiance cache — the same near/far split Lumen uses.

Storage: a new persistent 3D image, faceRadianceImg, R11F_G11F_B10F, dimensions
192 × (128 × 6) × 192 — the Y axis expanded ×6 for the six face directions, matching the
existing "stack along Y" convention from voxelCascade.glsl:24-26.
≈ 113 MB. clear = false (it must persist).

▎ The critical problem to solve first. The cascade is currently cleared and fully
▎ re-rasterized every frame (shaders.properties:85, clear=true) and its origin is
▎ floor(cameraPosition/vs)*vs — so voxel coordinates shift as the camera moves and any cached
▎ radiance would be invalidated constantly. The surface cache must use toroidal addressing:
▎ index by worldVoxelCoord mod N so entries stay valid under camera motion, and invalidate only
▎ the newly-exposed slabs. CASC_XZ = 192 is not a power of two — either use %, or change
▎ VOXEL_CASCADE_SIZE to 256 and use & 255 (voxelImg then costs 134 MB, cache ≈ 201 MB; both
▎ fine at the 8 GB target). Recommend 256 + bitmask.

Two new compute passes:

- shadowcomp1.csh → surface cache direct lighting. One thread per occupied voxel face.
Sun visibility via isInShadow() (lib/util/common.glsl:56 — cheap any-hit, and already what
the current GI uses; getShadow() is not reentrant, it reads five file-scope globals).
Inject emission from GetSpecialBlocklightColor(mat) (lib/blocklightColors.glsl:50) weighted
by lightEmisFactor() (lib/pt/lightShapes.glsl:108).
- shadowcomp2.csh → surface cache radiosity. Each face traces a few rays via
traceVoxelCascaded(); each hit looks up the cache from last frame. This feedback loop is
what gives multi-bounce for free. Write final = direct + indirect.

Amortize: update ~1/8 of faces per frame, selected by a frame-rotating stride. Cost is fixed and
independent of screen resolution.

3.2 World radiance cache

Octahedral probes on a world-anchored grid (start: 4-block spacing), each storing irradiance
plus a depth/variance term — the Chebyshev visibility test is what prevents the light leaking
that kills naive irradiance volumes. Probes trace via traceVoxelCascaded() and resolve hits
through the surface cache. New pass: prepare2.csh.

This also feeds the DH fallback: replace the hardcoded ambientColor * GI_SKY_BRIGHTNESS at
d7_composite.glsl:242-258 with a single far-field probe lookup.

3.3 Screen probes + final gather

- deferred.csh — place probes on a 16×16 pixel screen grid. Per probe, trace an octahedral
set of rays: screen trace first (cheap, high detail), fall back to traceVoxelCascaded(),
then the radiance cache, then sky. Hits resolve through the surface cache — no shading at the
hit point.
- deferred1 — spatially filter probes, project to SH, integrate per pixel, write the GI
buffer. Because probes are already converged, this replaces the entire SVGF chain; a light
temporal pass plus historyFixGI() on disocclusion should be enough.

Ray misses must use sampleSky_fast(worldDir, cameraPosition.y - 64.0)
(lib/fragment/sky.glsl:17 → atmosphereLUT.glsl:724). Never sampleSky() — it includes the
sun and moon discs (×1000 and ×100) and a single ray hitting one is a guaranteed firefly. Note
the current GI ignores the atmosphere LUT entirely and uses a flat ambientColor constant
(d0_restir.glsl:84); switching to a directional sky miss is one of the cheapest quality wins here.

3.4 Reflections

Same tracing stack, BRDF-sampled: sampleGGXVNDF() → screen trace → voxel trace → surface cache
lookup. Reuse the existing denoise architecture, which is already Lumen-shaped and worth keeping:
demodulate → temporal accumulate → spatial blur → re-modulate with sharp per-texel Fresnel.
Worth preserving specifically:
- ratio estimator G2/G1 demodulation (d7b_reflections.glsl:158-160)
- Karis inverse-luma ray weighting (:168-170)
- screen-velocity history rejection (:209-210)
- history-driven adaptive blur radius (d7c:92-93)

Composite in exactly one place. Metals replace ct0, dielectrics add — see
d7c_reflection_spatial.glsl:89.

---
Phase 4 — Re-wire the seam

d7_composite.glsl is the lighting hub and stays. The entire integration surface is one variable.

Replace the deleted :431-477 ladder with a single read of the new GI buffer, assigned to
vec3 indirect. The composite line :509 (color = albedoRaw * (direct + indirect)) must stay
unchanged.

1. Albedo-demodulated. The buffer holds incident light only; d7 multiplies by albedo.
2. Units: cosine-weighted mean incident radiance = irradiance/π. d7 does albedo * indirect,
not albedo/π * indirect, so the Lambert 1/π is folded into the buffer. Divide your
irradiance by π or the scene comes out ~3.14× too bright.
3. No NdotL applied by the consumer — the cosine lives in the sampling distribution.
4. GI_STRENGTH is pre-applied by the producer. LIGHTING_INDIRECT is not — d7 applies
it at :499.
5. Firefly clamps are pre-applied by the producer.
6. AO is not pre-applied.
7. Linear HDR, unbounded (RGBA16F).
8. Sampled at logical, un-jittered UV: texture(buf, unjitteredTexCoord * renderScale).
9. Diffuse only — no emission, no specular.

Double-count hazards

- Self-emission is added separately at d7_composite.glsl:510-519. The surface cache must inject
emission for other surfaces' light only. The current code is safe solely because
d0_restir traces with skipOrigin = true; preserve that.
- Reflections composite in deferred9/10, not in indirect.

are the most likely source of silent breakage.

1. Render scale. RENDER_SCALE = 0.67 (options.glsl:4-5). Buffers are full-res; scaled
passes squeeze into the bottom-left corner via
gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
and every read of a scaled buffer multiplies UV by renderScale. The upscale boundary is
composite1 (c0_taa.glsl); everything after it is full-res.
2. Jitter. G-buffers are stored jittered; GI buffers use logical un-jittered UV.
getTaaJitter() returns pixels, not UV. From a buffer-space pass, reach a GI buffer with
texCoord - jitter*texelSize; reach a G-buffer with texCoord directly. Position
reconstruction always feeds the logical UV to clipSpace, because
gbufferProjectionInverse is the un-jittered projection.
3. colortex5 is FULL-RES — written by c1_bloom_atlas.glsl:37 after the TAA resolve. Read it
without renderScale.
nt.
5. Compute template: layout(local_size_x = N) in; + const ivec3 workGroups = ivec3(X,1,1);,
SSBO block declared in a lib/ header and #included, barrier() + memoryBarrierBuffer().
No workGroupsRender precedent exists in this pack — a screen-space compute pass will be first.
6. The shadow fragment stage is near its 16-image-uniform budget (voxelCascade.glsl:24-26).
That is why all four cascades share one atlas. Budget carefully before binding more there.

---
Buffer budget

All 16 colortex are currently in use. Deleting ReSTIR + denoiser + AO + reflections frees
ct4, ct8, ct9, ct10, ct11, ct14 outright, plus ct15 (packed oct-normal + linear depth —
almost certainly worth keeping for the resolve) and ct7 (PBR material — keep for
material-aware reflections). ≈ 6-8 full-res RGBA16F targets.

Traps: ct3 is double-booked (GI denoise ↔ bloom atlas, c1_bloom_atlas.glsl:36) and ct6 is
triple-booked (a-trous ping-pong ↔ pbrSunVis from d7_composite:564 ↔ a composite-stage
rebind to Luts2.png, shaders.properties:154). Neither index is actually reclaimable.

Free pass slots: 99 setup, 99 shadowcomp, 98 prepare, 87 deferred, 92 composite. SSBO bindings
0 and 1 are taken; bufferObject.2+ is free.

---
Known defects in the inherited code

Worth fixing while in the area — several will otherwise be inherited silently.

1. Step-budget teleport (voxelTrace.glsl:119, 226). If the inner DDA exhausts
CASCADE_MAX_STEPS (96) before reaching tLimit, it still advances tWorld to the far side
of the cascade and resumes in the next. Geometry in the skipped span is silently missed →
light leaks. 96 steps across a 192-voxel cascade is short in dense foliage.
2. Torch occlusion asymmetry. In traceVoxelCascaded a torch is a 2/16 stick; in
traceVoxelOccluded it has shapeId == 0 and falls through to else if (!first) return true,
so it blocks as a solid 1 m³ cube. Shadow rays and GI rays disagree about the same torch.

  6 tasks (5 done, 1 open)
  ☑ Phase 0: commit foundation to lumen-experimental      a1728d1
  ☑ Phase 1a: harvest reusable primitives                 5f97821
  ☑ Phase 1b: delete lighting layers                      a295af5
  ☑ Phase 1c: rewire pipeline config and options          a295af5
  ☑ Phase 2: gate sub-block BLAS behind VOXEL_BLAS        6462309
  ◻ Phase 3: build the Lumen stack

---
Progress notes (branch: lumen-experimental)

Phase 1a harvested into lib/pt/sampling.glsl (luma, buildTBN, cosHemisphereDir,
stbnCosineHemisphere + the blueNoise decl, and the BRDF core: fresnelSchlick,
smithGGX_v1/v2, sampleGGXVNDF, tbnFromNormal) and lib/pt/reproject.glsl
(RGBtoYCoCg/YCoCgtoRGB, clipHistoryMoments, varFromMoments, svgfVarianceFloor,
getJitterRotation, HF_DISK, historyFixGI).

Two deviations from the plan as written, both deliberate:

1. historyFixGI takes its GI-history and normal/depth samplers as PARAMETERS
   rather than reading colortex8/colortex15 directly. The plan called it
   "reusable verbatim", but Phase 1 frees ct8, so the hardcoded binding could
   not have survived the buffer relayout.
2. lib/fragment/reflections.glsl was DELETED rather than stripped. Once its BRDF
   core moved to lib/pt/sampling.glsl and its screen-space march was removed,
   nothing was left in the file and nothing included it.

Deferred chain is now contiguous: deferred = d7_composite, deferred1 =
d8_fog_sky, deferred2 = d9_vl. All other deferred slots are free.

options.glsl went 268 -> 195 defines with zero legacy path-tracing macros left.
Three macros survived under new names because live code still reads them:
RESTIR_BLUE_NOISE -> GI_BLUE_NOISE, SVGF_MIN_LUMA_SIGMA -> GI_MIN_LUMA_SIGMA,
GID_FIREFLY_MAX -> GI_FIREFLY_MAX. The HISTORYFIX_* group kept its name.

CURRENT VISUAL STATE: direct lighting only. d7_composite's `indirect` is the
analytic lightmap ambient (the pre-path-tracer fallback) and there are no
reflections. This is expected between Phase 1 and Phase 3 — the 7-point contract
the Phase 3 GI buffer must satisfy is written into d7_composite at the seam.

Still open from "Known defects in the inherited code": both #1 (step-budget
teleport) and #2 (torch occlusion asymmetry) are unfixed. #2 survives the BLAS
gating — traceVoxelCascaded still resolves a torch through its light shape while
traceVoxelOccluded blocks on the whole voxel.

Pre-existing, unrelated to this work: shaders.properties lists SHADOW_BIAS and
SHADOW_DISTORT_FACTOR in screen.Light but neither has a #define.