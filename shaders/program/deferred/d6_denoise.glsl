// SVGF a-trous iteration 6 (BYPASSED for performance): colortex6 -> colortex3 + colortex8

#ifdef VERTEX
out vec2 texCoord;
void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}
#endif

#ifdef FRAGMENT
uniform sampler2D colortex6;
uniform sampler2D colortex8;
in vec2 texCoord;
/* RENDERTARGETS: 3,8 */
void main() {
    gl_FragData[0] = texture(colortex6, texCoord);
    gl_FragData[1] = texture(colortex8, texCoord);
}
#endif
