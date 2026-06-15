// irc_shift : irradiance-cache reprojection + temporal decay (compute)
// Runs first in the shadowcomp stage, after the shadow pass has rebuilt the voxel
// grid. The cache is camera-relative, so every frame each cell must inherit the
// value that lived at its world position last frame — i.e. the cell offset by the
// integer cell-space camera delta — then decay toward zero (leaky integrator: the
// GI update pass re-adds fresh samples). The shift is done IN PLACE in one image;
// the per-axis traversal order is reversed on axes the grid moved negatively so a
// source cell isn't overwritten before a destination cell reads it.

#ifdef CSH

#include "/lib/options.glsl"
#include "/lib/pt/irc.glsl"

const ivec3 workGroups = IRC_WG;
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba16f) uniform image3D irradianceImg;

void main() {
    // workGroups * local_size (8) exactly tiles IRC_DIMS, so every invocation is in
    // range — no early-out guard (a return before the barrier() below would break
    // the workgroup's uniform control flow).
    ivec3 gid = ivec3(gl_GlobalInvocationID);

    ivec3 delta = ircCellDelta(cameraPosition, previousCameraPosition);

    // Reverse traversal on negatively-moved axes (avoids clobbering a source cell
    // before its consumer reads it during the in-place shift).
    ivec3 coord = gid * ivec3(greaterThanEqual(delta, ivec3(0)))
                + (IRC_DIMS - gid - 1) * ivec3(lessThan(delta, ivec3(0)));

    ivec3 prev = coord + delta;
    vec4 v = (all(greaterThanEqual(prev, ivec3(0))) && all(lessThan(prev, IRC_DIMS)))
           ? imageLoad(irradianceImg, prev) : vec4(0.0);

    v *= float(IRC_DECAY);
    // clear=false means the image is NOT zeroed each frame (it IS the history); but
    // its contents on the very first frame are undefined, so zero-init then. The
    // clamp keeps any stray garbage / overflow bounded (radiance is non-negative;
    // rgba16f maxes ~65504) so the leaky integrator can never get stuck.
    if (frameCounter == 0 || any(isnan(v)) || any(isinf(v))) v = vec4(0.0);
    v = clamp(v, vec4(0.0), vec4(60000.0));

    barrier();
    memoryBarrierImage();
    imageStore(irradianceImg, coord, v);
}

#endif
