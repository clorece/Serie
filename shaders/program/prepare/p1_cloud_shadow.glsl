// p1_cloud_shadow : cloud shadow map build pass.
//
// Phase 0 stub — clears colortex13 to white (full sun visibility = no clouds yet).
// Phase 5 will fill this with raymarched cloud transmittance projected from sun.
//
// Target: colortex13, 512×512 RGBA16F. Only .r is consumed (cloud transmittance).
// Until phase 5 lands, .r = 1.0 so terrain in d7_composite sees full sunlight.

#ifdef VERTEX

void main() {
    gl_Position = ftransform();
}

#endif

#ifdef FRAGMENT

/* RENDERTARGETS: 13 */

void main() {
    gl_FragData[0] = vec4(1.0, 0.0, 0.0, 1.0);
}

#endif
