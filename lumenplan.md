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

(HISTORICAL — this list is as originally written. Item 1 has since been FIXED in
traceVoxelCascaded, though traceVoxelOccluded still carries it. See the HANDOFF
at the end of this file for the current state; it supersedes everything above.)

1. Step-budget teleport (voxelTrace.glsl:119, 226). If the inner DDA exhausts
CASCADE_MAX_STEPS (96) before reaching tLimit, it still advances tWorld to the far side
of the cascade and resumes in the next. Geometry in the skipped span is silently missed →
light leaks. 96 steps across a 192-voxel cascade is short in dense foliage.
2. Torch occlusion asymmetry. In traceVoxelCascaded a torch is a 2/16 stick; in
traceVoxelOccluded it has shapeId == 0 and falls through to else if (!first) return true,
so it blocks as a solid 1 m³ cube. Shadow rays and GI rays disagree about the same torch.

===========================================================================
HANDOFF — branch lumen-experimental (pushed to origin)
Rewritten after the optimisation work. Supersedes the older handoff.
===========================================================================

STATUS

  Phases
    [x] Phase 0   commit foundation                        a1728d1
    [x] Phase 1   harvest / delete / rewire                5f97821 a295af5
    [x] Phase 2   gate sub-block BLAS behind VOXEL_BLAS    6462309
    [x] Phase 3.1 surface cache                            40440b9
    [x] Phase 3.3 final gather + Phase 4 d7 seam           1860503
    [ ] Phase 3.2 world radiance cache      NOT STARTED (deliberately deferred)
    [ ] Phase 3.4 reflections               NOT STARTED

  Five optimisation passes then landed on top. The pipeline runs and is fast.

WHAT IS AND IS NOT CONFIRMED IN-ENGINE — READ THIS FIRST

  CONFIRMED by the author, reported as a large performance gain:
    604a0ce  surface cache update cost
    2062fea  surface cache feedback
    aa71d79  step-budget teleport fix + adaptive gather rays

  NOT YET SEEN RUNNING. Compile-validated only:
    aeab753  emitter palette baked to SSBO
    ae89987  sky SH
    a786d87  emitter AABBs baked
    31b91bb  converged-pixel gather skip
    ff0b0d7  LIGHTING_INDIRECT decoupled from traced GI
    9abbabf  short-range contact AO
    5096165  a-trous denoiser

  The last four change APPEARANCE, not just cost. Verify those first.

ARCHITECTURE AS BUILT

  Pass order (world0/):
    setup        s0_shape_table      BLAS table + emitter palette, once at load
    shadow       gbuffers/shadow     shadow map + voxelisation (+ skylight bits)
    shadowcomp   sc0_entity_bvh
    shadowcomp1  sc1_surface_direct  surface cache update
    shadowcomp2  sc2_sky_sh          sky -> 9 SH coefficients
    prepare      p0_atmosphere_lut
    prepare1     p1_cloud_shadow
    deferred     dg0_gather          final gather -> ct8, ct15
    deferred1-4  dg1_denoise1..4     a-trous strides 1/2/4/8
    deferred5    d7_composite        lighting hub
    deferred6    d8_fog_sky
    deferred7    d9_vl
    composite..  unchanged

  NOTE the renumbering: d7/d8/d9 used to be deferred1/2/3.

  Images
    voxelImg         256x512x256 R32UI   cascaded grid, clear=true
    brickImg/super   hierarchical occupancy, clear=true
    faceRadianceImg  256x768x256 RGBA16F surface cache, ~402 MB, clear MUST be false
    scRequestImg     32x16x32 R8UI       feedback stamps, 16 KB, clear MUST be false

  Buffers
    ct8   GI: .rgb indirect, .a history length. dg0_gather's temporal history.
    ct9   denoise ping-pong
    ct10  denoise ping-pong
    ct15  reprojection key: .xy oct WORLD normal, .z linear depth

  SSBOs
    0  block-shape BLAS table          65536
    1  entity BVH                     262144
    2  emitter palette: colour + occluder/emissive AABBs   16384
    3  sky SH, 9 coefficients            256

WHAT THE OPTIMISATION PASSES DID, AND THE TRAPS IN THEM

  The through-line: the surface cache update, not the gather, was the expensive
  half; and large constant tables were sitting inside the hottest loop.

  1. Sky visibility is READ, not traced. The voxeliser banks Minecraft's own
     skylight lightmap into three formerly spare bits of the voxel word. This
     removed a 64-block occlusion probe cast per face per refresh -- the longest
     and most numerous ray in the renderer -- and is more accurate than the
     probe, which thresholded one fixed-direction ray to 0 or 1.

  2. Air voxels are not cleared. The cache is only read at a ray HIT and
     scVoxelForHit pulls half a voxel inward, so every read lands on an OCCUPIED
     voxel; stale radiance in an air slot is unreachable.
     Consequence: GI_DEBUG_VIEW 4 and 6 ignore the tag and now show leftovers in
     empty space. Views 3 and 5 respect it and remain the ones to trust.

  3. Brick/super-brick occupancy gates the update in two L1-resident fetches.
     The flat index is BRICK-MAJOR over LOCAL space so a work group lands inside
     one brick and that test is group-uniform. Local space is required: the
     toroidal wrap plus a non-8-aligned cascade origin means an aligned run of
     SLOTS straddles two bricks and the group-uniform test would be a lie.

  4. Refresh rate is distance-banded with a per-voxel hashed phase. The old flat
     Z-slab stride spent as much on the far cascade corner as on the block
     underfoot and relit in visible planar sweeps.

  5. SURFACE CACHE FEEDBACK (Lumen's LumenSurfaceCacheFeedback). Gather rays
     stamp the brick they resolve through; the update pass skips unstamped
     bricks outside SC_NEAR_DIST.
     ** THE TRAP: bounce-ray stamping MUST stay confined to the near field. If
     every updated voxel stamped, the requested set would grow by SC_BOUNCE_DIST
     per frame and saturate the cascade in ~8 frames, silently making the whole
     scheme worthless. GI_DEBUG_VIEW 8 catches it: mostly green everywhere means
     saturation. **

  6. Step-budget teleport FIXED. A ray exhausting CASCADE_MAX_STEPS used to jump
     to the cascade's far side, skip everything between, and report `escaped` --
     so the caller substituted full sky for a ray stopped inside a canopy. It now
     stops in place and reports a non-escaped miss. This is what makes
     GI_MAX_STEPS a knob you can turn down: it now costs reach, not correctness.

  7. Adaptive gather rays + converged-pixel skipping. GI_GATHER_RAYS is what a
     pixel with NO history gets; converged pixels drop to one ray, and fully
     converged NEAR-STATIC ones skip entirely one frame in GI_SKIP_PERIOD.
     Chosen over a checkerboard: no spatial reconstruction, cannot touch a
     disoccluded or moving pixel, and the skipped set is hashed not patterned.

  8. Emitter palette AND emitter AABBs baked into SSBO 2. Both were branch trees
     over material ids returning constants, inside the DDA loop. The authoring
     data is renamed ...Ref() and fenced behind EMITTER_PALETTE_BAKE so only the
     setup pass compiles it -- leaving it reachable-but-uncalled would rely on
     driver DCE, and register allocation is exactly what should not depend on
     that. Material-id compares reachable in the gather: 11 -> 0.

  9. SKY SH. Diffuse ray misses read nine coefficients instead of four LUT
     texelFetches. Also a noise reduction: LUT sampling hands each ray
     high-frequency detail that is pure variance for a diffuse gather.
     Verified numerically -- scripts/verify_sky_sh.py mirrors the shader's own
     basis and sampling. Cosine-weighted error against a worst-case hard step:
     floor +0.0%, wall -0.7%, ceiling +4.3%, mean radiance 0.000%.
     The clamp to zero in skySHRadiance is LOAD-BEARING: negative radiance would
     feed back through the surface cache and keep subtracting.

 10. SHORT-RANGE CONTACT AO. Ray occlusion alone barely darkens anything in
     daylight -- a ray hitting a nearby block resolves it through the cache,
     which holds direct + albedo*indirect, so a SUNLIT occluder returns roughly
     what the sky it replaced would have. Geometry blocks the ray without
     lowering what the ray returns. Nothing else supplied contact shading either:
     GTAO went in Phase 1 and the d7 seam contract says "AO is NOT pre-applied".
     Derived from hit distances the gather already has, so no extra rays, and
     applied BEFORE temporal accumulation so the history denoises it.
     NOT a normals bug -- that was ruled out first, see below.

 11. A-TROUS DENOISER, deliberately small, because the surface cache converges
     before the gather runs. 3x3 taps per pass, not SVGF's 5x5; no variance
     buffer, no moment accumulation (history length stands in for variance).
       GI_DENOISE_QUALITY 0 off / 1 (1,2) / 2 (1,2,4) / 3 (1,2,4,8)
     ** TRAP A: colortex8 is NEVER written by the denoiser. It is dg0_gather's
     temporal history; feeding a filtered result back compounds blur every frame
     with nothing new to anchor it. SVGF does feed its first pass back, but its
     history is a 1-spp estimate that needs the help. **
     ** TRAP B: the ladder ping-pongs 8->9->10->9->10 and ENDS on a different
     buffer for an odd vs even pass count. d7 resolves which at compile time from
     the same option that gates the passes. Verified at every level:
     0->ct8, 1->ct10, 2->ct9, 3->ct10. **

 12. LIGHTING_INDIRECT no longer attenuates the traced GI. It scales only the
     rasterised fills: the analytic lightmap fallback, and shadeDhTerrain's
     hemisphere ambient. Previously the only way to trim the flat raster ambient
     was to attenuate the traced result by the same factor.

THINGS RULED OUT BY INSPECTION — do not re-investigate

  - The gather's NORMALS are correct. gbuffers/terrain writes
    normalize(gl_NormalMatrix * gl_Normal), i.e. VIEW space, encoded *0.5+0.5
    into colortex1 via DRAWBUFFERS:0127; dg0_gather decodes *2-1 and applies
    gbufferModelViewInverse. Checked end to end while chasing "terrain looks
    flat"; the cause was missing contact occlusion, item 10.

  - historyFixGI already early-outs for converged pixels, and entityBvhClosest
    already early-outs on an empty tree. Neither is worth optimising.

REVERTED, BUT THE FINDING STANDS

  An emissive-shadow-contrast change was written and then reverted at the
  author's request. The underlying observation is real and may be wanted later:

    accumEmission in voxelTrace.glsl has NO distance term. A ray that TERMINATES
    on an emitter is a solid-angle correct sample and needs none -- a far torch
    subtends a smaller angle and catches fewer rays. But a ray that merely passes
    through an emitter's flame box picks up its full glow whether the emitter is
    one block along the ray or forty, and gather rays run to GI_GATHER_DIST.

    So shaped emitters (torches, lanterns, candles) wash a room evenly, which
    fills in shadows that the DDA had occluded exactly. Area emitters (glowstone,
    lava) TERMINATE rays and are unaffected.

    Care if revisiting: a torch lights a room almost entirely via flame
    pass-through, so scaling that term to 0 removes nearly all torch GI rather
    than merely hardening its shadows.

KNOWN DEFECTS STILL OPEN

  - Torch occlusion asymmetry: traceVoxelCascaded resolves a torch through its
    light shape, traceVoxelOccluded blocks on the whole voxel. Currently moot --
    traceVoxelOccluded has ZERO callers since the per-face sky probe was removed
    -- but it will bite Phase 3.4. It also still carries the teleport bug, which
    was only fixed in traceVoxelCascaded.
  - Pre-existing, unrelated: shaders.properties lists SHADOW_BIAS and
    SHADOW_DISTORT_FACTOR in screen.Light but neither has a #define.

IRIS GOTCHAS PAID FOR IN BLOOD — do not relearn these

  1. NO trailing comments on #include lines. Iris takes the rest of the line as
     the path.
  2. `const ivec3 workGroups` MUST be literal integers. Iris parses it out of
     source text and does NOT evaluate GLSL; an expression it cannot fold falls
     back silently to ONE work group. This cost four wrong diagnoses.
  3. RENDERTARGETS is read the same way. Keep it a literal, never behind an #if.
     That is why the denoiser has four one-line wrapper files.
  4. NO implicit-LOD sampling in compute. texture() needs derivatives; drivers
     return 0. Use textureLod / texelFetch. This silently zeroed the shadow
     lookup once. (The atmosphere LUT path is safe -- _bilinearLUT uses
     texelFetch -- which is why sc2_sky_sh can call sampleSky_fast.)
  5. shadowcomp runs BEFORE prepare, so colortex12 is one frame stale in both
     sc1 and sc2. Harmless; the sky changes over minutes.
  6. VOXEL_CASCADE_SIZE must stay a power of two (128 or 256): the cache indexes
     itself by worldVoxel & (N-1).

DEBUG VIEWS (GI_DEBUG_VIEW in options.glsl)
  1 indirect buffer, no albedo     is the gather producing anything?
  2 temporal history length        blue = fresh, red = converged
  3 surface cache down primary ray is the CACHE populated?
  4 same as 3, ignoring the tag    (now shows leftovers in air -- see item 2)
  5 coverage: green = tag valid, red = tag rejected, black = ray miss
  6 tag STORED in the slot
  7 tag the reader EXPECTS         compare against 6
  8 feedback coverage: green = stamped and refreshing, red = frozen,
    blue = SURFACE_CACHE_FEEDBACK compiled out

Views 5 and 8 are the ones that find dispatch and addressing bugs. Reach for
them before reasoning about screenshots -- three of the four bugs in Phase 3.1
were misdiagnosed by inference first.

VERIFICATION HARNESS

  scripts/validate_shaders.py   flattens every world0 entry point and runs
    glslangValidator. Exits non-zero on anything failing outside its known list.
    59/64 clean; the 5 known failures are Distant Horizons programs referencing
    Iris-injected uniforms with no source declaration.

  scripts/verify_sky_sh.py      numerically checks the SH projection against the
    shader's own basis and sampling.

  Three things the shader harness must keep doing:
    1. reject #include lines with trailing content, exactly as Iris does;
    2. resolve #ifdef VERTEX / FRAGMENT for the target cycle BEFORE deduping
       includes -- a global dedupe drops /lib/options.glsl from the fragment
       cycle of every program whose vertex branch included it first, and reports
       it as undeclared identifiers nowhere near the cause (this bug made the
       harness report 41/55 before it was found);
    3. rename the pack's `uniform sampler2D texture`, which shadows the GLSL
       built-in and makes glslang abort at the first sample.

  MEASURE PREPROCESSED SOURCE, not flattened source:
    glslangValidator -E -S <stage> <flattened>
  The flattener does not resolve #ifdefs, so it counts text the compiler
  discards. That made the emitter-AABB change first appear to make the tracers
  BIGGER, and made the palette win read as -276 lines when the real figure is
  -223.

NEXT WORK, IN ORDER

  1. Verify the seven unconfirmed commits in-engine, appearance ones first:
     contact AO, denoiser, sky SH, LIGHTING_INDIRECT. Debug views 1, 5 and 8.
  2. Tune: GI_AO_STRENGTH / GI_AO_RADIUS (contact shading),
     GI_DN_SIGMA_* (denoiser edge stopping), GI_SKY_BRIGHTNESS vs GI_STRENGTH
     (sky wash vs coloured bounce), GI_SKIP_PERIOD, GI_MAX_STEPS.
  3. Phase 3.2 world radiance cache. Two jobs: give rays that exhaust
     GI_GATHER_DIST / SC_BOUNCE_DIST a real far-field answer, and replace the
     hardcoded DH ambient in shadeDhTerrain with a far-field probe lookup.
     ** Consider extending faceRadianceImg to coarser cascades INSTEAD of a
     separate probe grid. Old Lumen used exactly this: a 4-cascade voxel
     clipmap storing radiance in 6 directions, which is the structure already
     here. It would also unblock cone-stepping (below). Cost: cascade 0 is
     402 MB, so 2 cascades ~804 MB. R11F_G11F_B10F becomes worth revisiting at
     that size -- it was dropped earlier only because bandwidth stopped
     mattering at one cascade. **
  4. Phase 3.4 reflections on the same stack: sampleGGXVNDF -> voxel trace ->
     surface cache lookup. colortex7 and the pbrSunVis output on colortex6 were
     both kept live for this. Free slots: ct4, ct11, ct14.

REMAINING OPTIMISATION HEADROOM

  Ranked, all needing a profile rather than more guessing.

  a. CONE-STEPPING ACROSS CASCADES. The biggest single ray-cost win left. Lumen's
     software tracer widens the cone with distance and samples coarser SDF mips;
     the voxel analogue is to promote k by distance travelled, not only on
     leaving a cascade. A 48-block gather ray currently walks cascade 0 at one
     block per step for up to 83 steps; promoting to cascade 1 after ~16 blocks
     and cascade 2 after ~48 gets it to roughly 32.
     BLOCKED on the surface cache covering coarser cascades -- see item 3 above.
     (This already bites today: a ray starting near the cascade-0 edge can cross
     out and scLookup silently returns black.)

  b. IMPORTANCE SAMPLING from the cache. Lumen builds a per-probe PDF from the
     previous frame's radiance and inverse-CDF samples it. A coarse luminance
     volume over cascade 0, MIS-weighted against the cosine lobe, would be a
     large variance win in torch- and lava-lit interiors, which is where a
     two-ray gather looks worst.

  c. NRD-STYLE FAST HISTORY (anti-lag). Keep a short-window history alongside the
     long one and snap toward it when they diverge. GI_ACCUM_FRAMES is 32, so a
     light turning on takes ~32 frames to appear. Quality, not speed.

  d. SPLIT DIRECT AND INDIRECT CACHE STORAGE. Lumen keeps separate Direct,
     Radiosity and Final Lighting atlases so the cheap high-frequency term and
     the expensive low-frequency one can run at different rates and resolutions.
     Here direct is one shadow lookup and indirect is SC_BOUNCE_RAYS DDA walks,
     but they are summed into one slot so neither can be scheduled independently.
     SC_FACE_STRIDE is the poor-man's version and needs no extra storage.

  e. OCCUPANCY-ONLY VOLUME FOR TRAVERSAL. The DDA's hottest fetch is the full
     R32UI word; the loop needs one bit and the fat word only AT the hit. R8UI
     would be 33.5 MB, a packed bitmask 4.2 MB and L2-resident. Estimate revised
     DOWN: brick skipping already handles the long walks through open air, so the
     remaining steps are near geometry and about to hit anyway. Also costs an
     image uniform in the shadow fragment stage, which is near its budget of 16.

  f. HALF-RESOLUTION GATHER with bilateral upsample. Not done because it touches
     the renderScale and jitter conventions this pack has repeatedly broken
     silently on, and the adaptive budget already bought most of the headroom.

  g. SCREEN PROBES on a 16x16 grid -- Lumen's actual final gather, and the
     structural fix that (f) approximates. Only once a profile shows the gather
     dominating.

  h. voxelImg is clear=true, so 134 MB is cleared and re-rasterised every frame,
     roughly 0.33 ms on a 400 GB/s part. Avoiding it needs toroidal addressing
     for the GRID plus explicit invalidation on block changes -- the same trick
     the cache uses, but with much worse failure modes.

  DROPPED after reconsidering, with reasons:
    - Slimming the hot VoxelHit. category/shapeId/albedo/lightMat are dead at
      both consumers, but drivers inline traceVoxelCascaded and DCE unread struct
      fields, so the gain is very likely already had. Duplicating a 100-line DDA
      to chase an unmeasurable win is a bad trade.
    - R11F_G11F_B10F for a ONE-cascade cache. The feedback gate shrank the update
      set by more than an order of magnitude, taking cache bandwidth off the
      critical path; 402 MB is inside the stated budget; and Iris support for the
      format on a custom image is unverified. Revisit only for a multi-cascade
      cache (item 3).
