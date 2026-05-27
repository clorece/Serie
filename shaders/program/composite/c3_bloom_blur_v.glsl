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


#include "/lib/util/common.glsl"
#include "/lib/post/bloom.glsl"

void main() {
    vec3 color = BloomBlur(colortex6, texCoord, vec2(0.0, texelSize.y));
    
    /* DRAWBUFFERS:3 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
