#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"

in vec2 texCoord;

uniform sampler2D colortex3; // Bloom input (bright-pass)

#include "/lib/util/common.glsl"
#include "/lib/post/bloom.glsl"

void main() {
    vec3 color = BloomBlur(colortex3, texCoord, vec2(texelSize.x, 0.0));
    
    /* DRAWBUFFERS:6 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
