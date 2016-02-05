﻿Shader "Skybox/Edited Procedural Surround" {
Properties {
	[KeywordEnum(None, Simple, High Quality)] _SunDisk ("Sun", Int) = 2
	_SunSize ("Sun Size", Range(0,1)) = 0.04
	
	_Exposure("Sun Exposure", Range(0, 8)) = 1.3
	_AtmosphereThickness ("Atmoshpere Thickness", Range(0,5)) = 1.0
	_SkyTint ("Sky Tint", Color) = (.5, .5, .5, 1)
	_GroundColor ("Ground", Color) = (.369, .349, .341, 1)
	
	//Custom Properties
	_MoonSize ("Moon Size", Range(0,.2)) = 0.04
	_MoonColor ("Moon Color", Color) = (.8,.8,1, .75)
	_MoonExposure("Moon Exposure", Range(0, 8)) = 1.3
	
	_TwilightColor ("Twilight Color", Color) = (.2, .2, .6, 1)
	_TwilightHorizonColor ("Twilight Horizon Color", Color) = (.2, .2, .6, 1)
	_NightColor ("Night Color", Color) = (.2, .2, .6, 1)
	_NightHorizonColor ("Night Horizon Color", Color) = (.2, .2, .6, 1)
	_NightAngles ("Night Color Fade In Angles", Vector) = (-.05,.165,.35,0)
	
	_StarMap ("Star Map", 2D) = "black" {}
	_StarMapScale ("Star Map Scale", Range(0,5)) = 1.0
	_StarAngles ("Stars Fade In Angles", Vector) = (.15,.5,0,0)
	_StarRotation ("Stars Rotation Euler Angles", Vector) = (0,0,0,0)
	
}

SubShader {
	Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" }
	Cull Off ZWrite Off

	Pass {

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag
//		#pragma glsl

		#include "UnityCG.cginc"
		#include "Lighting.cginc"

		#pragma multi_compile __ UNITY_COLORSPACE_GAMMA
		#pragma multi_compile _SUNDISK_NONE _SUNDISK_SIMPLE _SUNDISK_HIGH_QUALITY

		uniform half _Exposure;		// HDR exposure
		uniform half3 _GroundColor;
		uniform half _SunSize;
		uniform half3 _SkyTint;
		uniform half _AtmosphereThickness;
		
		//custom properties
		uniform half _MoonSize;
		uniform half4 _MoonColor;
		uniform half _MoonExposure;		// HDR exposure
		
		uniform half3 _TwilightColor;
		uniform half3 _TwilightHorizonColor;
		uniform half3 _NightColor;
		uniform half3 _NightHorizonColor;
		uniform half4 _NightAngles;
		
		uniform sampler2D _StarMap; uniform float4 _StarMap_ST;
		uniform half4 _StarAngles;
		uniform half _StarMapScale;
		uniform half4 _StarRotation;
		

	#if defined(UNITY_COLORSPACE_GAMMA)
		#define GAMMA 2
		#define COLOR_2_GAMMA(color) color
		#define COLOR_2_LINEAR(color) color*color
		#define LINEAR_2_OUTPUT(color) sqrt(color)
	#else
		#define GAMMA 2.2
		// HACK: to get gfx-tests in Gamma mode to agree until UNITY_ACTIVE_COLORSPACE_IS_GAMMA is working properly
		#define COLOR_2_GAMMA(color) ((unity_ColorSpaceDouble.r>2.0) ? pow(color,1.0/GAMMA) : color)
		#define COLOR_2_LINEAR(color) color
		#define LINEAR_2_LINEAR(color) color
	#endif

		// RGB wavelengths
		// .35 (.62=158), .43 (.68=174), .525 (.75=190)
		static const float3 kDefaultScatteringWavelength = float3(.65, .57, .475);
		static const float3 kVariableRangeForScatteringWavelength = float3(.15, .15, .15);

		#define OUTER_RADIUS 1.025
		static const float kOuterRadius = OUTER_RADIUS;
		static const float kOuterRadius2 = OUTER_RADIUS*OUTER_RADIUS;
		static const float kInnerRadius = 1.0;
		static const float kInnerRadius2 = 1.0;

		static const float kCameraHeight = 0.0001;

		#define kRAYLEIGH (lerp(0, 0.0025, pow(_AtmosphereThickness,2.5)))		// Rayleigh constant
		#define kMIE 0.0010      		// Mie constant
		#define kSUN_BRIGHTNESS 20.0 	// Sun brightness

		#define kMAX_SCATTER 50.0 // Maximum scattering value, to prevent math overflows on Adrenos

		static const half kSunScale = 400.0 * kSUN_BRIGHTNESS;
		static const float kKmESun = kMIE * kSUN_BRIGHTNESS;
		static const float kKm4PI = kMIE * 4.0 * 3.14159265;
		static const float kScale = 1.0 / (OUTER_RADIUS - 1.0);
		static const float kScaleDepth = 0.25;
		static const float kScaleOverScaleDepth = (1.0 / (OUTER_RADIUS - 1.0)) / 0.25;
		static const float kSamples = 2.0; // THIS IS UNROLLED MANUALLY, DON'T TOUCH

		#define MIE_G (-0.990)
		#define MIE_G2 0.9801

		#define SKY_GROUND_THRESHOLD 0.02

		// fine tuning of performance. You can override defines here if you want some specific setup
		// or keep as is and allow later code to set it according to target api

		// if set vprog will output color in final color space (instead of linear always)
		// in case of rendering in gamma mode that means that we will do lerps in gamma mode too, so there will be tiny difference around horizon
		// #define SKYBOX_COLOR_IN_TARGET_COLOR_SPACE 0

		// sun disk rendering:
		// no sun disk - the fastest option
		#define SKYBOX_SUNDISK_NONE 0
		// simplistic sun disk - without mie phase function
		#define SKYBOX_SUNDISK_SIMPLE 1
		// full calculation - uses mie phase function
		#define SKYBOX_SUNDISK_HQ 2

		// uncomment this line and change SKYBOX_SUNDISK_SIMPLE to override material settings
		// #define SKYBOX_SUNDISK SKYBOX_SUNDISK_SIMPLE

	#ifndef SKYBOX_SUNDISK
		#if defined(_SUNDISK_NONE)
			#define SKYBOX_SUNDISK SKYBOX_SUNDISK_NONE
		#elif defined(_SUNDISK_SIMPLE)
			#define SKYBOX_SUNDISK SKYBOX_SUNDISK_SIMPLE
		#else
			#define SKYBOX_SUNDISK SKYBOX_SUNDISK_HQ
		#endif
	#endif

	#ifndef SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
		#if defined(SHADER_API_MOBILE)
			#define SKYBOX_COLOR_IN_TARGET_COLOR_SPACE 1
		#else
			#define SKYBOX_COLOR_IN_TARGET_COLOR_SPACE 0
		#endif
	#endif

		// Calculates the Rayleigh phase function
		half getRayleighPhase(half eyeCos2)
		{
			return 0.75 + 0.75*eyeCos2;
		}
		half getRayleighPhase(half3 light, half3 ray)
		{
			half eyeCos	= dot(light, ray);
			return getRayleighPhase(eyeCos * eyeCos);
		}


		struct appdata_t
		{
			float4 vertex : POSITION;
		};

		struct v2f
		{
			float4	pos				: SV_POSITION;
//			float4	position		: POSITION;

		#if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
			// for HQ sun disk, we need vertex itself to calculate ray-dir per-pixel
//			half3	vertex			: TEXCOORD0;
		#elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
			half3	rayDir			: TEXCOORD0;
		#else
			// as we dont need sun disk we need just rayDir.y (sky/ground threshold)
			half	skyGroundFactor	: TEXCOORD0;
		#endif

			// calculate sky colors in vprog
			half3	groundColor		: TEXCOORD1;
			half3	skyColor		: TEXCOORD2;
			half3	vertex			: TEXCOORD5;
			half3 	nightColor		: TEXCOORD6;
			half3	horizonPercent	: TEXCOORD7;
			

		#if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
			half3	sunColor		: TEXCOORD3;
			half3	moonColor		: TEXCOORD4;
		#endif
		};


		float scale(float inCos)
		{
			float x = 1.0 - inCos;
		#if defined(SHADER_API_N3DS)
			// The polynomial expansion here generates too many swizzle instructions for the 3DS vertex assembler
			// Approximate by removing x^1 and x^2
			return 0.25 * exp(-0.00287 + x*x*x*(-6.80 + x*5.25));
		#else
			return 0.25 * exp(-0.00287 + x*(0.459 + x*(3.83 + x*(-6.80 + x*5.25))));
		#endif
		}

		v2f vert (appdata_t v)
		{
			v2f OUT;
			OUT.pos = mul(UNITY_MATRIX_MVP, v.vertex);
			
			half3 calcNightColor = half3(0,0,0);

			float3 kSkyTintInGammaSpace = COLOR_2_GAMMA(_SkyTint); // convert tint from Linear back to Gamma
			float3 kScatteringWavelength = lerp (
				kDefaultScatteringWavelength-kVariableRangeForScatteringWavelength,
				kDefaultScatteringWavelength+kVariableRangeForScatteringWavelength,
				half3(1,1,1) - kSkyTintInGammaSpace); // using Tint in sRGB gamma allows for more visually linear interpolation and to keep (.5) at (128, gray in sRGB) point
			float3 kInvWavelength = 1.0 / pow(kScatteringWavelength, 4);

			float kKrESun = kRAYLEIGH * kSUN_BRIGHTNESS;
			float kKr4PI = kRAYLEIGH * 4.0 * 3.14159265;

			float3 cameraPos = float3(0,kInnerRadius + kCameraHeight,0); 	// The camera's current position

			// Get the ray from the camera to the vertex and its length (which is the far point of the ray passing through the atmosphere)
			float3 eyeRay = normalize(mul((float3x3)_Object2World, v.vertex.xyz));

			float far = 0.0;
			half3 cIn, cOut;


			if(eyeRay.y >= 0.0)
			{
				// Sky
				// Calculate the length of the "atmosphere"
				far = sqrt(kOuterRadius2 + kInnerRadius2 * eyeRay.y * eyeRay.y - kInnerRadius2) - kInnerRadius * eyeRay.y;

				float3 pos = cameraPos + far * eyeRay;

				// Calculate the ray's starting position, then calculate its scattering offset
				float height = kInnerRadius + kCameraHeight;
				float depth = exp(kScaleOverScaleDepth * (-kCameraHeight));
				float startAngle = dot(eyeRay, cameraPos) / height;
				float startOffset = depth*scale(startAngle);


				// Initialize the scattering loop variables
				float sampleLength = far / kSamples;
				float scaledLength = sampleLength * kScale;
				float3 sampleRay = eyeRay * sampleLength;
				float3 samplePoint = cameraPos + sampleRay * 0.5;

				// Now loop through the sample rays
				float3 frontColor = float3(0.0, 0.0, 0.0);
				// Weird workaround: WP8 and desktop FL_9_1 do not like the for loop here
				// (but an almost identical loop is perfectly fine in the ground calculations below)
				// Just unrolling this manually seems to make everything fine again.
//				for(int i=0; i<int(kSamples); i++)
				{
					float height = length(samplePoint);
					float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
					float lightAngle = dot(_WorldSpaceLightPos0.xyz, samplePoint) / height;
					float cameraAngle = dot(eyeRay, samplePoint) / height;
					float scatter = (startOffset + depth*(scale(lightAngle) - scale(cameraAngle)));
					float3 attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));

					frontColor += attenuate * (depth * scaledLength);
					samplePoint += sampleRay;
				}
				{
					float height = length(samplePoint);
					float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
					float lightAngle = dot(_WorldSpaceLightPos0.xyz, samplePoint) / height;
					float cameraAngle = dot(eyeRay, samplePoint) / height;
					float scatter = (startOffset + depth*(scale(lightAngle) - scale(cameraAngle)));
					float3 attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));
					
					
					frontColor += attenuate * (depth * scaledLength);
					samplePoint += sampleRay;
					
					half sunAngle = -dot(normalize(_WorldSpaceLightPos0.xyz), half3(0,1,0));
					half twilightLerpAmount = saturate((sunAngle - _NightAngles.x) / (_NightAngles.y - _NightAngles.x));
					half nightLerpAmount = saturate((sunAngle - _NightAngles.y) / (_NightAngles.z - _NightAngles.y)) * step(1, twilightLerpAmount);
					calcNightColor = lerp(calcNightColor, _TwilightColor, twilightLerpAmount);
					calcNightColor = lerp(calcNightColor, _NightColor, nightLerpAmount);
										
					half horizonPercent = 1 - eyeRay.y;
//					horizonPercent *= horizonPercent; //square falloff
//					horizonPercent *= horizonPercent * horizonPercent; //cubic falloff
					horizonPercent *= horizonPercent * horizonPercent * horizonPercent * horizonPercent; //pow(5) falloff
//					horizonPercent *= horizonPercent * horizonPercent * horizonPercent * horizonPercent * horizonPercent; //pow(6) falloff
					horizonPercent = 1 - horizonPercent;
					horizonPercent = cos(horizonPercent * 1.57079632679); //coserp (hardcoded number is pi/2)
					OUT.horizonPercent = horizonPercent;
					
					half3 calcHorizonColor = lerp(half3(0,0,0), _TwilightHorizonColor, twilightLerpAmount);
					calcHorizonColor = lerp(calcHorizonColor, _NightHorizonColor, nightLerpAmount);
					
					calcNightColor = lerp(calcNightColor, calcHorizonColor, horizonPercent);
				}



				// Finally, scale the Mie and Rayleigh colors and set up the varying variables for the pixel shader
				cIn = frontColor * (kInvWavelength * kKrESun);
				cOut = frontColor * kKmESun;
			}
			else
			{
				// Ground
				far = (-kCameraHeight) / (min(-0.001, eyeRay.y));

				float3 pos = cameraPos + far * eyeRay;

				// Calculate the ray's starting position, then calculate its scattering offset
				float depth = exp((-kCameraHeight) * (1.0/kScaleDepth));
				float cameraAngle = dot(-eyeRay, pos);
				float lightAngle = dot(_WorldSpaceLightPos0.xyz, pos);
				float cameraScale = scale(cameraAngle);
				float lightScale = scale(lightAngle);
				float cameraOffset = depth*cameraScale;
				float temp = (lightScale + cameraScale);

				// Initialize the scattering loop variables
				float sampleLength = far / kSamples;
				float scaledLength = sampleLength * kScale;
				float3 sampleRay = eyeRay * sampleLength;
				float3 samplePoint = cameraPos + sampleRay * 0.5;

				// Now loop through the sample rays
				float3 frontColor = float3(0.0, 0.0, 0.0);
				float3 attenuate;
//				for(int i=0; i<int(kSamples); i++) // Loop removed because we kept hitting SM2.0 temp variable limits. Doesn't affect the image too much.
				{
					float height = length(samplePoint);
					float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
					float scatter = depth*temp - cameraOffset;
					attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));
					frontColor += attenuate * (depth * scaledLength);
					samplePoint += sampleRay;
				}

				cIn = frontColor * (kInvWavelength * kKrESun + kKmESun);
				cOut = clamp(attenuate, 0.0, 1.0);
			}

		OUT.vertex 			= -v.vertex;
		#if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
			OUT.vertex 			= -v.vertex;
		#elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
			OUT.rayDir 			= half3(-eyeRay);
		#else
			OUT.skyGroundFactor	= -eyeRay.y / SKY_GROUND_THRESHOLD;
		#endif

			// if we want to calculate color in vprog:
			// 1. in case of linear: multiply by _Exposure in here (even in case of lerp it will be common multiplier, so we can skip mul in fshader)
			// 2. in case of gamma and SKYBOX_COLOR_IN_TARGET_COLOR_SPACE: do sqrt right away instead of doing that in fshader

			OUT.groundColor	= _Exposure * (cIn + COLOR_2_LINEAR(_GroundColor) * cOut);
			OUT.skyColor	= _Exposure * (cIn * getRayleighPhase(_WorldSpaceLightPos0.xyz, -eyeRay));
			OUT.nightColor = calcNightColor;

		#if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
			OUT.sunColor	= _Exposure * (cOut * _LightColor0.xyz);
			OUT.moonColor	= _MoonExposure * _MoonColor.xyz;
		#endif

		#if defined(UNITY_COLORSPACE_GAMMA) && SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
			OUT.groundColor	= sqrt(OUT.groundColor);
			OUT.skyColor	= sqrt(OUT.skyColor);
			#if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
				OUT.sunColor= sqrt(OUT.sunColor);
				OUT.moonColor= sqrt(OUT.moonColor);
			#endif
		#endif

			return OUT;
		}
		
//		float2 GetUVFromPosition(float3 position)
		half2 GetUVFromPosition (half3 position)
		{
			half dx = position.x;
			half dy = position.z;
			half dz = position.y;
			half ang = atan2( dx, dz );
			ang += 3.1415926; // was -pi to pi, becomes 0 to 2 pi
			half vtx = ang / ( 2 * 3.1415926 );
			half dxz = sqrt( dx * dx + dz * dz );
			ang = atan2( dxz, dy ); // 0 to pi
			half vty = ang / 3.1415926;
			return half2(vtx, vty);
		}
		
		half2 GetUVFromPositionOriginal(half3 position)
		{
			return half2(0.25 + saturate(((atan2(position.z, position.x) / 3.141592654) + 1.0) / 2.0), -(0.5-(asin(position.y)/3.141592654)) );
		}
		
		half3 RotatePoint (half3 position, half3 rotation)
		{
			float x = position.x;
			float y = position.y;
			float z = position.z;
			
			rotation *= 0.0174533;

			//use these to temporarily store the output of the last rotation
			float x2 = x;
			float y2 = y;
			float z2 = z;

			float cx = cos(-rotation.x);
			float sx = sin(-rotation.x);
			
			float cy = cos(-rotation.y);
			float sy = sin(-rotation.y);
			float cz = cos(rotation.z);
			float sz = sin(rotation.z);

			x = cy * x2 + sy * z2;
			z = -sy * x2 + cy * z2;
			x2 = x;
			z2 = z;
			
			y = cx * y2 - sx * z2;
			z = sx * y2 + cx * z2;
			y2 = y;
			z2 = z;

			x = cz * x2 - sz * y2;
			y = sz * x2 + cz * y2;

			return float3(x,y,z);
		}


		// Calculates the Mie phase function
		half getMiePhase(half eyeCos, half eyeCos2)
		{
			half temp = 1.0 + MIE_G2 - 2.0 * MIE_G * eyeCos;
			temp = pow(temp, pow(_SunSize,0.65) * 10);
			temp = max(temp,1.0e-4); // prevent division by zero, esp. in half precision
			temp = 1.5 * ((1.0 - MIE_G2) / (2.0 + MIE_G2)) * (1.0 + eyeCos2) / temp;
			#if defined(UNITY_COLORSPACE_GAMMA) && SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
				temp = pow(temp, .454545);
			#endif
			return temp;
		}
		
		half getMoonMiePhase(half eyeCos, half eyeCos2)
		{
			half temp = 1.0 + MIE_G2 - 2.0 * MIE_G * eyeCos;
			temp = pow(temp, pow(_MoonSize,0.65) * 10);
			temp = max(temp,1.0e-4); // prevent division by zero, esp. in half precision
			temp = 1.5 * ((1.0 - MIE_G2) / (2.0 + MIE_G2)) * (1.0 + eyeCos2) / temp;
			#if defined(UNITY_COLORSPACE_GAMMA) && SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
				temp = pow(temp, .454545);
			#endif
			return temp;
		}

		half calcSunSpot(half3 vec1, half3 vec2)
		{
			half3 delta = vec1 - vec2;
			half dist = length(delta);
			half spot = 1.0 - smoothstep(0.0, _SunSize, dist);
			return kSunScale * spot * spot;
		}
		
		half calcMoonSpot(half3 vec1, half3 vec2)
		{
			half3 delta = vec1 - vec2;
			half dist = length(delta);
			half spot = 1.0 - smoothstep(0.0, _MoonSize, dist);
			return kSunScale * spot * spot;
		}

		half4 frag (v2f IN) : SV_Target
		{
			half3 col = half3(0.0, 0.0, 0.0);
			half3 calcNightColor = IN.nightColor;

		// if y > 1 [eyeRay.y < -SKY_GROUND_THRESHOLD] - ground
		// if y >= 0 and < 1 [eyeRay.y <= 0 and > -SKY_GROUND_THRESHOLD] - horizon
		// if y < 0 [eyeRay.y > 0] - sky
		#if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
			half3 ray = normalize(mul((float3x3)_Object2World, IN.vertex));
			half y = ray.y / SKY_GROUND_THRESHOLD;
		#elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
			half3 ray = IN.rayDir.xyz;
			half y = ray.y / SKY_GROUND_THRESHOLD;
		#else
			half y = IN.skyGroundFactor;
		#endif

			// if we did precalculate color in vprog: just do lerp between them
			col = lerp(IN.skyColor, IN.groundColor, saturate(y));

		#if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
			if(y < 0.0)
			{
			#if SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
				half mie = calcSunSpot(_WorldSpaceLightPos0.xyz, -ray);
				half moonMie = 0;
			#else // SKYBOX_SUNDISK_HQ
				half eyeCos = dot(_WorldSpaceLightPos0.xyz, ray);
				half eyeCos2 = eyeCos * eyeCos;
				half mie = getMiePhase(eyeCos, eyeCos2);
				
				half moonEyeCos = dot(-_WorldSpaceLightPos0.xyz, ray);
				half moonEyeCos2 = moonEyeCos * moonEyeCos;
				half moonMie = getMoonMiePhase(moonEyeCos, moonEyeCos2);
			#endif
			
			#if defined(UNITY_COLORSPACE_GAMMA) && SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
				moonMie = sqrt(moonMie);
			#endif
			
				col += mie * IN.sunColor;
				calcNightColor += moonMie * IN.moonColor;
			}
		#endif
		
		if(y < 0.0)
		{
		
			half3 normalizedLightPosition = normalize(_WorldSpaceLightPos0.xyz);
			half sunAngle = -dot(normalizedLightPosition, half3(0,1,0));
//			half nightPercent = dot(normalize(_WorldSpaceLightPos0.xyz), half3(0,0,-1)) * .5 + .5;
			
			half3 position = normalize(IN.vertex);
//			half3 position = normalize(IN.vertex - _WorldSpaceLightPos0.xyz);
//			float2 starUV = float2(0.25 + saturate(((atan2(position.z, position.x) / 3.141592654) + 1.0) / 2.0), -(0.5-(asin(position.y)/3.141592654)) );
			
			position = RotatePoint(position, _StarRotation.xyz);
			
			half2 starUV = GetUVFromPositionOriginal(position);
//			half2 starUV = GetUVFromPosition(position);
			starUV *= _StarMapScale;
			
//			half3 noisePosition = IN.vertex * _NoiseScales.rgb;
//			noisePosition.x = sin(noisePosition.x + 1.11235813) + tan(noisePosition.x * 1.11235813 - 23.513425);
//			noisePosition.y = cos(noisePosition.y - .62393) - sin(noisePosition.y * .62393 + 2.3249234);
//			noisePosition.z = tan(noisePosition.z + 2.71828182) + cos(noisePosition.z * 1.218324233 - 6.2143672);
////			noisePosition = frac(noisePosition);
//			half noiseAmount = length(noisePosition) * _NoiseScales.w * .01;
//			calcNightColor *= 1 + (noiseAmount);
			
//			float4 starColor = tex2D(_StarMap,TRANSFORM_TEX(starUV.xy, _StarMap));
			half4 starColor = tex2Dlod(_StarMap,float4(TRANSFORM_TEX(starUV, _StarMap),0.0,0.0));
//			float4 starColor = tex2D(_StarMap,float4(starUV, 0, 1));
			half starLerpAmount = saturate((sunAngle - _StarAngles.x) / (_StarAngles.y - _StarAngles.x));
			starLerpAmount = 1 - cos(starLerpAmount * 1.570796326); //coserp (hardcoded number is pi/2)
			starLerpAmount = 1 - cos(starLerpAmount * 1.570796326); //second coserp for a more gradual fade in
			half3 calcStarColor = lerp(half3(0,0,0), starColor.rgb, starLerpAmount);
			
			half horizonPercent = IN.horizonPercent;
			horizonPercent = 1 - horizonPercent;
			horizonPercent *= horizonPercent;
			calcStarColor *= horizonPercent;
			half nightColorValue = length(calcNightColor);
			nightColorValue = 1 - nightColorValue;
			nightColorValue *= nightColorValue;
			nightColorValue *= nightColorValue;
			nightColorValue = 1 - nightColorValue;
			calcStarColor = saturate(calcStarColor - (nightColorValue * 2.5));
			calcNightColor += calcStarColor;
		}
		
		col += lerp(half3(0,0,0), calcNightColor, 1 - length(col));

		#if defined(UNITY_COLORSPACE_GAMMA) && !SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
			col = LINEAR_2_OUTPUT(col);
		#endif

			return half4(col,1.0);

		}
		ENDCG
	}
}


Fallback Off

}
