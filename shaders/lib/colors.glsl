float MdotU = dot(moonVector,upVector);
float moonVisibility = pow(clamp(MdotU+0.1,0.0,0.1)/0.1,2.0);

// Sunlight color
float sunAngle = max(dot(sunVector, upVector), 0.0);
vec3 sunColor = mix(vec3(1.0, 0.65, 0.1) * 0.25, vec3(1.0, 1.0, 1.1), sunAngle) * 1.25;

// Moonlight color
float moonAngle = max(dot(moonVector, upVector), 0.0);
vec3 moonColor = mix(vec3(0.4, 0.55, 1.0), vec3(0.1, 0.5, 1.0), moonAngle) * 0.01;

lightColor = mix(sunColor, moonColor, moonVisibility);
ambientColor = vec3(0.2, 0.275, 0.4);