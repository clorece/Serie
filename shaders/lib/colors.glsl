float MdotU = dot(moonVector,upVector);
float moonVisibility = pow(clamp(MdotU+0.1,0.0,0.1)/0.1,2.0);


float sunAngle = max(dot(sunVector, upVector), 0.0);
vec3 sunColor = mix(vec3(1.0, 0.65, 0.35) * 0.15, vec3(1.0, 1.0, 1.1), sunAngle);


float moonAngle = max(dot(moonVector, upVector), 0.0);
vec3 moonColor = mix(vec3(0.65, 0.85, 1.0), vec3(0.65, 0.85, 1.0), moonAngle) * 0.02;

lightColor = mix(sunColor, moonColor, moonVisibility);
float sunUp = clamp(dot(sunVector, upVector), 0.0, 1.0);
float dayScale = mix(0.1, 1.0, sunUp); // sunset/sunrise is 0.6, noon is 3.5
float nightScale = 0.025; // night is 0.02 to make night shadows visible but balanced with moonlight
float ambientScale = mix(dayScale, nightScale, moonVisibility);

ambientColor = vec3(0.22, 0.295, 0.4) * ambientScale;