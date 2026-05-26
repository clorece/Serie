// SVGF a-trous iteration 5 (BYPASSED for performance): colortex3 -> colortex6

#ifdef VERTEX
out vec2 texCoord;
void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}
#endif

#ifdef FRAGMENT
uniform sampler2D colortex3;
in vec2 texCoord;
/* RENDERTARGETS: 6 */
void main() {
    gl_FragData[0] = texture(colortex3, texCoord);
}
#endif
