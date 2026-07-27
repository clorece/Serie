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

===========================================================================
HANDOFF — branch lumen-experimental (pushed to origin)
Last updated after commit affafad.
===========================================================================

STATUS

  8 tasks (7 done, 1 open, 1 blocked on verification)
  [x] Phase 0   commit foundation to lumen-experimental      a1728d1
  [x] Phase 1a  harvest reusable primitives                  5f97821
  [x] Phase 1b  delete lighting layers                       a295af5
  [x] Phase 1c  rewire pipeline config and options           a295af5
  [x] Phase 2   gate sub-block BLAS behind VOXEL_BLAS        6462309
  [x] Phase 3.1 surface cache                                40440b9
  [x] Phase 3.3 final gather  +  Phase 4 d7 seam             1860503
  [ ] Phase 3.2 world radiance cache          NOT STARTED (deliberately deferred)
  [ ] Phase 3.4 reflections                   NOT STARTED

WHERE IT STANDS RIGHT NOW — READ THIS FIRST

The pipeline is fully wired end to end: voxel grid -> surface cache -> screen
gather -> d7_composite. Everything compiles and the pack loads.

It is NOT yet confirmed working in-engine. The last change (affafad) fixed the
surface cache dispatch and has not been visually verified. The immediate next
action is not to write code, it is to run these three checks:

  1. GI_DEBUG_VIEW 5 -> expect GREEN everywhere within ~128 blocks of the camera.
     Any red means the cache still is not being written there.
  2. GI_DEBUG_VIEW 3 -> expect the world lit, not one band.
  3. GI_DEBUG_VIEW 0 -> real render; sunlight bounce should be visible and
     GI_STRENGTH should respond.

THEN: SC_UPDATE_STRIDE is temporarily 1, which refreshes all 8.4M voxels every
frame and will run badly. Put it back to 8. If view 5 stays green at 8, image
persistence works and the cheap stride is free. If it goes red, clear=false is
not being honoured for image.faceRadianceImg and the cache cannot be amortised
at all — that would need a rethink (double buffer, or full refresh every frame).

WHAT WAS BUILT

  lib/pt/surfaceCache.glsl    toroidal addressing, validity tag, read/write
  lib/pt/directLight.glsl     world-space sun vector + light colour (compute-safe)
  lib/pt/sampling.glsl        harvested sampling + BRDF primitives
  lib/pt/reproject.glsl       harvested history clamp, variance floor, historyFixGI
  program/shadowcomp/sc1_surface_direct.glsl   the cache update pass
  program/deferred/dg0_gather.glsl             the final gather
  world0/shadowcomp1.csh, world0/deferred.{fsh,vsh}

Pass order now: shadowcomp = entity BVH, shadowcomp1 = surface cache,
deferred = dg0_gather, deferred1 = d7_composite, deferred2 = d8_fog_sky,
deferred3 = d9_vl.

Buffers: colortex8 = GI (.rgb indirect, .a history length), colortex15 = the
reprojection key (.xy oct WORLD normal, .z linear depth). Both written by
dg0_gather. faceRadianceImg = the surface cache, 256 x 768 x 256 RGBA16F
(~402 MB), .a carries the validity tag, clear MUST stay false.

IRIS GOTCHAS PAID FOR IN BLOOD — do not relearn these

  1. NO trailing comments on #include lines. Iris takes the entire rest of the
     line as the path. `#include "/lib/x.glsl" // why` fails to resolve at load.
  2. `const ivec3 workGroups` MUST be literal integers. Iris parses it out of the
     source text and does NOT evaluate GLSL; an expression it cannot fold falls
     back silently to ONE work group. This cost four wrong diagnoses. Use a
     literal and absorb the remainder with a grid-stride loop.
  3. NO implicit-LOD sampling in compute. texture() needs derivatives, which do
     not exist there; drivers return 0. Use textureLod(..., 0.0). This silently
     zeroed the shadow lookup and killed all direct light in the cache.
  4. shadowcomp runs BEFORE prepare, so colortex12 (atmosphere LUT) is one frame
     stale in the cache pass. Harmless, but know it.
  5. VOXEL_CASCADE_SIZE must stay a power of two (128 or 256). The cache indexes
     itself by worldVoxel & (N-1); 192 has no mask and the old default is gone.

DEBUG VIEWS (GI_DEBUG_VIEW in options.glsl)
  1 indirect buffer, no albedo     is the gather producing anything?
  2 temporal history length        blue = fresh, red = converged
  3 surface cache down primary ray is the CACHE populated?
  4 same as 3 but ignoring the tag distinguishes "unwritten" from "tag rejected"
  5 coverage: green = tag valid, red = tag rejected, black = ray miss
  6 tag STORED in the slot         grey ramp; pure black = never written
  7 tag the reader EXPECTS         compare against 6

Views 5/6/7 are the ones that actually find dispatch and addressing bugs. Reach
for them before reasoning about screenshots — three of the four bugs in this
phase were misdiagnosed by inference first.

DEVIATIONS FROM THE PLAN AS WRITTEN (all deliberate)

  1. historyFixGI takes its samplers as PARAMETERS, not hardcoded ct8/ct15.
     Phase 1 frees ct8, so the original binding could not survive.
  2. lib/fragment/reflections.glsl was DELETED, not stripped. Its BRDF core moved
     to lib/pt/sampling.glsl and its SSR march was removed; nothing was left.
  3. Surface cache direct + radiosity are ONE dispatch, not the planned
     shadowcomp1 + shadowcomp2 split. With only 1/STRIDE of the volume refreshed
     per frame a separate radiosity pass would still read mostly-previous-frame
     direct light, buying a second dispatch and a RAW hazard for no accuracy.
  4. Phase 3.2 (world radiance cache) was REORDERED after 3.3/4. With d7 on the
     analytic fallback the surface cache was invisible and untestable.

===========================================================================
OPTIMISATION PASS 1 -- surface cache update cost
===========================================================================

Profile-by-inspection finding: the cache update pass, not the gather, was the
expensive half of the pipeline. At SC_UPDATE_STRIDE 1 it launched one thread per
cascade-0 voxel every frame -- 256 x 128 x 256 = 8.39M -- against roughly 932k
gather rays at 1080p x 0.67. Three specific wastes dominated:

  * ~90% of those threads were AIR, and each still wrote six RGBA16F texels of
    black, about 400 MB/frame spent writing zeroes over zeroes.
  * solid-interior voxels (all of underground) paid 7 atlas fetches and 6 stores
    to rediscover that every face is buried.
  * exposed voxels cast a 64-block occlusion probe PER FACE, purely to estimate
    sky visibility -- the longest and most numerous ray in the renderer.

What changed

  1. Sky visibility is no longer traced. gbuffers/shadow banks Minecraft's own
     skylight lightmap into three previously spare bits of the voxel word
     (voxelFormat.glsl, [15:13]); the cache reads it out of the word it has
     already fetched. Removes SC_SKY_PROBE_DIST entirely. This is also MORE
     accurate than the probe: the probe thresholded one fixed-direction ray to
     0 or 1, so a partly-covered face read as fully open or fully blind.
     New knob SC_SKY_DOWN_FACE shapes how much sky a downward face receives.

  2. Air voxels are no longer cleared. The cache is only ever read at a ray HIT,
     and scVoxelForHit pulls the hit point half a voxel inward, so every read
     lands on an OCCUPIED voxel -- stale radiance in an air slot is unreachable.
     Debug note: views 4 and 6 ignore the tag and will now show leftovers in
     empty space; views 3 and 5 respect it and remain the ones to trust.

  3. Hierarchical occupancy gates the pass. The 8^3 brick and 64^3 super-brick
     maps the DDA already builds reject empty space in two L1-resident fetches,
     before anything touches the 134 MB voxel atlas.

  4. The flat index is now BRICK-MAJOR and enumerates LOCAL space rather than
     slot space, so a 256-thread work group lands inside one brick and the
     occupancy test above is group-uniform. Local space matters: the toroidal
     wrap plus a non-8-aligned cascade origin means an aligned run of slots
     straddles two bricks, which would make the group-uniform test a lie.

  5. Refresh rate is distance-banded instead of a flat Z-slab stride, with the
     phase hashed per voxel. This is Lumen's per-frame card-capture budget in
     miniature: SC_NEAR_DIST refreshes every frame, SC_UPDATE_STRIDE governs
     the far field. The old slab stride spent as much work on the far corner of
     the cascade as on the block underfoot, and relit in planar sweeps that
     crossed the world as a visible wavefront; hashing turns that into dither.

  6. Face round-robin (SC_FACE_STRIDE): one face in N per voxel per frame.
     Slots with no valid history ignore it and fill immediately, so it never
     leaves holes.

OPTIMISATION PASS 2 -- feedback, tracer, and gather

  7. SURFACE CACHE FEEDBACK (was headroom item 1). Lumen's
     LumenSurfaceCacheFeedback at brick granularity. Every gather ray stamps the
     low 8 bits of the frame onto the 8^3 brick it resolved through, into a new
     16 KB R8UI image (scRequestImg); sc1 refuses to spend work on any brick
     outside SC_NEAR_DIST with no stamp inside SC_REQUEST_TTL frames. Cache cost
     now tracks what the camera can see rather than the size of the cascade.

     THE TRAP, if this is ever revisited: bounce-ray stamping must stay confined
     to the near field. If every updated voxel stamped, the requested set would
     grow by SC_BOUNCE_DIST per frame -- requested bricks cast rays, those hits
     get stamped, next frame THEY cast rays -- and saturate the cascade in about
     eight frames, silently making the whole scheme worthless. GI_DEBUG_VIEW 8
     is how you would catch that: mostly green everywhere means saturation.

  8. STEP-BUDGET TELEPORT FIXED (was a known defect). A ray exhausting
     CASCADE_MAX_STEPS used to advance to the far side of the cascade and resume
     in the next, skipping everything in between AND reporting escaped, so the
     caller substituted full sky for a ray that had actually stopped inside a
     forest canopy. It now stops where it is and reports a non-escaped miss.

     The point is as much performance as correctness: GI_MAX_STEPS was
     previously a knob you could not turn down, because lowering it leaked
     light. It now trades reach for speed and nothing else.

  9. ADAPTIVE GATHER RAY BUDGET. GI_GATHER_RAYS is now what a pixel with NO
     history gets; a pixel converged to GI_ADAPTIVE_FRAMES drops to one ray.
     The full budget is paid only at disocclusions, silhouettes and on moving
     geometry. Reprojection had to move ABOVE the gather to make this possible
     -- it does not depend on the gather's result, and when histLen is 0 the
     blend weight is exactly 1 so the history value is unused.

OPTIMISATION PASS 3 -- getting large code out of the hot loops

Passes 1 and 2 were confirmed in-engine: a large performance gain. These two are
both the same shape of problem -- expensive code sitting where it is executed
per ray rather than per frame.

 10. EMITTER PALETTE BAKED TO AN SSBO. GetSpecialBlocklightColor is a ~160-line
     binary search over ~98 materials, and voxelEmitterColor was calling it from
     inside the DDA loop. The branching is not the main cost: pulling that tree
     into the trace loop inflates its register allocation and lowers occupancy
     for EVERY ray, including the majority that never touch an emitter. The
     palette is pure constants, so the setup pass (which already uploads the BLAS
     table and runs once at load) now flattens it into bufferObject.2.

     Flattened translation units shrank by ~276 lines each for the gather, the
     cache update and d7_composite; setup grew 374, and runs once.

 11. SKY SH. sampleSky_fast is four texelFetches into the atmosphere LUT plus
     transcendentals, per MISSED RAY, in both the gather and the cache bounce
     loop. shadowcomp2 now projects the sky onto nine SH coefficients once per
     frame (bufferObject.3) and each miss becomes ~20 FMAs.

     It also cuts noise: the sky term is a Monte Carlo estimate over few rays,
     and LUT sampling hands each ray high-frequency detail that is pure variance
     for a diffuse gather. Verified numerically -- see scripts/verify_sky_sh.py,
     which mirrors the shader's own basis and sampling. Against a worst-case hard
     step the cosine-weighted error is +0.0% on floors, -0.7% on walls and +4.3%
     on ceilings, with 0.000% shift in mean radiance. The clamp to zero in
     skySHRadiance is load-bearing: negative radiance would be fed back through
     the surface cache and keep subtracting.

OPTIMISATION PASS 4 -- finishing the hot-loop cleanup, and skipping the gather

 12. EMITTER AABBs BAKED TOO. lightOccluderAabb and lightEmissiveAabb were the
     same problem as the colour lookup: branch trees over material ids returning
     constants, inside the DDA loop. They now come from the same SSBO (five vec4
     arrays, 10240 bytes). The authoring data is renamed ...Ref() and fenced
     behind EMITTER_PALETTE_BAKE so only s0_shape_table compiles it -- leaving it
     reachable-but-uncalled would rely on the driver dead-stripping it, and the
     register allocation this change is about is exactly what should not depend
     on that. Material-id compares reachable in the gather: 11 -> 0.

 13. CONVERGED PIXELS SKIP THE GATHER. At GI_ACCUM_FRAMES a pixel blends each new
     estimate at alpha = 1/33, so it is already 97% resampled history and tracing
     it again moves it almost not at all. Fully converged AND near-static pixels
     now trace one frame in GI_SKIP_PERIOD.

     Chosen over a checkerboard gather deliberately: it needs no spatial
     reconstruction, it cannot touch a disoccluded or moving pixel (those never
     qualify), and the set that skips is hashed per pixel rather than following a
     pattern. The motion guard is belt-and-braces -- converged pixels resample
     every frame regardless, so the blur it guards against is inherent to
     temporal accumulation, not to skipping.

MEASUREMENT NOTE, learned here: measure PREPROCESSED source, not flattened
source. `glslangValidator -E -S <stage> <flattened>` shows what the compiler
actually sees. The flattener does not resolve #ifdefs, so it counts text the
preprocessor discards -- which made pass 4's change first appear to make the
tracers BIGGER, and made pass 3's palette win read as -276 lines when the real
figure is -223.

NOTE: traceVoxelOccluded now has ZERO callers -- removing the per-face sky probe
orphaned it. It is kept as the natural any-hit primitive for Phase 3.4, but it
still carries both the teleport bug and the torch asymmetry. Fix them before
reusing it.

NEXT WORK, IN ORDER

  1. Verify in-engine. Nothing in either optimisation pass has been seen
     running -- the checks below are compile-level only. Debug views to use:
       5  cache coverage (unchanged meaning)
       8  feedback coverage: green = brick stamped and refreshing, red = frozen,
          blue = SURFACE_CACHE_FEEDBACK compiled out
     Watch for: cave leak (the sky term changed source), a visible warm-up when
     spinning the camera (raise SC_REQUEST_TTL or SC_NEAR_DIST), and whether
     SC_FACE_STRIDE 2 is catchable on a fast lighting change.
  2. Tune. GI_SKY_LEAK_FALLOFF (cave leak), SC_BLEND / SC_UPDATE_STRIDE
     (convergence vs latency), GI_GATHER_RAYS with GI_ADAPTIVE_FRAMES,
     GI_STRENGTH. GI_MAX_STEPS is now safe to lower.
  3. Phase 3.2 world radiance cache. Two jobs: give rays that exhaust
     GI_GATHER_DIST / SC_BOUNCE_DIST a real far-field answer instead of the
     current lightmap-gated sky approximation, and replace the hardcoded DH
     ambient in d7_composite (the GI_FIREFLY_MAX block inside shadeDhTerrain,
     ~line 262) with a single far-field probe lookup.
  4. Phase 3.4 reflections on the same stack: sampleGGXVNDF -> voxel trace ->
     surface cache lookup. colortex7 (PBR material) and the pbrSunVis output on
     colortex6 were both kept live for this. Free slots: ct4, ct9, ct10, ct11,
     ct14, and deferred4+.

KNOWN DEFECTS STILL OPEN

  - Torch occlusion asymmetry: traceVoxelCascaded resolves a torch through its
    light shape, traceVoxelOccluded blocks on the whole voxel. Currently moot --
    traceVoxelOccluded has no callers -- but it will bite Phase 3.4.
  - Pre-existing, unrelated: shaders.properties lists SHADOW_BIAS and
    SHADOW_DISTORT_FACTOR in screen.Light but neither has a #define.

REMAINING OPTIMISATION HEADROOM

Everything below is DELIBERATELY NOT DONE. Two of them were dropped after
reconsidering, and the reasons matter more than the items.

  DROPPED -- slim the hot VoxelHit. category, shapeId, albedo and lightMat are
  dead at both consumers, so a narrower struct looked like free register
  pressure. But GLSL drivers inline traceVoxelCascaded unconditionally and then
  dead-code-eliminate unread struct fields, so the gain is very likely already
  being had. Duplicating a 100-line DDA to chase an unmeasurable win is a bad
  trade. Revisit only with a profile that shows occupancy limited in that loop.

  DROPPED -- R11F_G11F_B10F for the cache. Would take faceRadianceImg from
  402 MB to ~251 MB and cut its bandwidth 37%. But the feedback gate shrank the
  update set by more than an order of magnitude, which took cache bandwidth off
  the list of things that matter; 402 MB is well inside the stated 8 GB budget;
  and Iris support for that internal format on a custom image is unverified.
  Cost and risk both now exceed the benefit.

  STILL OPEN, needs profiling first:

  a. Split direct and indirect storage. Lumen keeps separate Direct Lighting,
     Radiosity and Final Lighting atlases precisely so the cheap high-frequency
     term and the expensive low-frequency one can run at different rates and
     resolutions (r.Lumen.Radiosity.DownsampleFactor defaults to 4). Here direct
     is one shadow-map lookup and indirect is SC_BOUNCE_RAYS DDA walks, but they
     are summed into one slot so neither can be scheduled independently.
     SC_FACE_STRIDE is the poor-man's version and needs no extra storage.

  b. Occupancy-only volume for traversal. The DDA's hottest fetch is the full
     R32UI word, yet the loop only needs one bit; the fat word is only needed AT
     the hit. R8UI would be 33.5 MB, a packed bitmask 4.2 MB and L2-resident.
     Estimate revised DOWN since first writing this: the brick/super-brick
     skipping already handles the long walks through open air, so the remaining
     steps are near geometry and about to hit anyway. It also costs an image
     uniform in the shadow fragment stage, which is near its budget of 16.

  c. Gather at half resolution with a bilateral upsample -- 4x fewer rays, and
     the gather's output is inherently low-frequency because the cache is smooth
     at voxel granularity. Not done because it touches the renderScale and
     jitter conventions that this pack has repeatedly broken silently on, and
     the adaptive budget (item 9) already bought most of the headroom.

  d. Screen probes on a 16x16 grid -- Lumen's actual final gather, and the
     structural fix that (c) approximates. A whole new pass; only worth it once
     a profile shows the gather dominating.

  e. voxelImg is clear=true, so 134 MB is cleared and fully re-rasterised every
     frame -- roughly 0.33 ms on a 400 GB/s part. Avoiding it needs toroidal
     addressing for the GRID plus explicit invalidation on block changes, which
     is the same trick the cache uses but with much worse failure modes.

VERIFICATION HARNESS

scripts/validate_shaders.py. Flattens every world0 entry point and runs
glslangValidator over it; exits non-zero on anything failing outside its
known-failures list. 50 of 55 programs compile clean; the 5 known failures are
Distant Horizons programs referencing uniforms Iris injects that have no source
declaration.

Three things it has to emulate, all learned the hard way — do not "simplify"
them away:

  1. Reject #include lines with trailing content exactly as Iris does. Iris
     takes the rest of the line as part of the path.
  2. Resolve #ifdef VERTEX / #ifdef FRAGMENT for the target cycle BEFORE
     deduping includes. Iris compiles each stage separately, so a header pulled
     in under #ifdef VERTEX must still reach the fragment cycle. A global dedupe
     without this drops /lib/options.glsl from the fragment cycle of every
     program whose vertex branch included it first, which surfaces as undeclared
     identifiers nowhere near the cause. (The first version of this harness had
     exactly that bug and reported 41/55 as a result.)
  3. Rename the pack's `uniform sampler2D texture`, which shadows the GLSL
     built-in. Iris renames it at load; glslang aborts at the first sample and
     hides the entire rest of the program behind one error.
