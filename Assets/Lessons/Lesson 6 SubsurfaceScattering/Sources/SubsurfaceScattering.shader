Shader "Hidden/SubsurfaceScattering"
{
	Properties
	{
		_AlbedoMap("AlbedoMap",2D) = "white"{}
		_Albedo ("Albedo", Color) = (1,1,1,1)
		_MetallicMap("MetallicMap",2D) = "white"{}
		_Metallic("Metallic",Range(0,1)) = 0
		_RoughnessMap("RoughnessMap",2D) = "white"{}
		_Roughness("Roughness",Range(0,1)) = 0.5

		_NormalMap("NormalMap",2D) = "bump"{}
		_LowNormalMap("LowNormalMap",2D) = "bump"{}
		_NormalScale("NormalScale",Float) = 1
		_NormalWeight("NormalWeight",Color) = (1,1,1,1)
		_OcclusionMap("OcclusionMap",2D) = "white"{}
		_EmissiveMap("EmissiveMap",2D) = "black"{}

		_AngleScatteringMap("AngleScatteringMap",2D) = "black"{}
		_ShadowScatteringMap("ShadowScatteringMap",2D) = "black"{}
		_CurvatureMap("CurvatureMap",2D) = "black"{}
		_CurvatureOffset("CurvatureOffset",Range(-1,1)) = 0
	}
	SubShader
	{
		Pass
		{
			Tags
			{
				"LightMode" = "UniversalForward"
			}

			HLSLPROGRAM
			#pragma vertex VertexPass
			#pragma fragment FragmentPass
			#pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
			#pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
			#pragma multi_compile _ EVALUATE_SH_MIXED EVALUATE_SH_VERTEX
			#pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
			#pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
			#pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION
			#pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

			struct Vertex
			{
				float3 positionOS : POSITION;
				float2 uv:TEXCOORD0;
				float3 normalOS:NORMAL;
				float4 tangentOS:TANGENT;
			};

			struct Fragment
			{
				float4 positionCS_SV : SV_POSITION;
				float3 positionWS:TEXCOORD0;
				float2 uv:TEXCOORD1;
				float3 normalWS:NORMAL;
				float3 tangentWS:TANGENT;
				float3 bitangentWS:TEXCOORD2;
			};

			sampler2D _AlbedoMap;
			float4 _Albedo;
			sampler2D _MetallicMap;
			float _Metallic;
			sampler2D _RoughnessMap;
			float _Roughness;
			sampler2D _NormalMap;
			sampler2D _LowNormalMap;
			float _NormalScale;
			float4 _NormalWeight;
			sampler2D _OcclusionMap;
			sampler2D _EmissiveMap;

			sampler2D _AngleScatteringMap;
			sampler2D _ShadowScatteringMap;
			sampler2D _CurvatureMap;
			float _CurvatureOffset;


			Fragment VertexPass(Vertex v)
			{
				Fragment fragment;
				fragment.positionCS_SV = TransformObjectToHClip(v.positionOS);
				fragment.positionWS = TransformObjectToWorld(v.positionOS);
				fragment.uv = v.uv;
				fragment.normalWS = TransformObjectToWorldNormal(v.normalOS);
				fragment.tangentWS = TransformObjectToWorldDir(v.tangentOS.xyz);
				fragment.bitangentWS = cross(fragment.normalWS, fragment.tangentWS) * v.tangentOS.w;
				return fragment;
			}

			float4 FragmentPass(Fragment fragment) : SV_Target
			{
				//切线空间
				float3x3 tangentToWorld = transpose(float3x3(
					normalize(fragment.tangentWS),
					normalize(fragment.bitangentWS),
					normalize(fragment.normalWS)
				));

				//物体表面属性
				float3 albedo = _Albedo.rgb * tex2D(_AlbedoMap, fragment.uv).rgb;
				float metallic = _Metallic * tex2D(_MetallicMap, fragment.uv).r;
				float smoothness = 1 - sqrt(_Roughness * tex2D(_RoughnessMap, fragment.uv).r);
				float3 normal = mul(tangentToWorld, normalize(UnpackNormal(tex2D(_NormalMap, fragment.uv)) * float3(_NormalScale, _NormalScale, 1)));
				float3 lowNormal = mul(tangentToWorld, normalize(UnpackNormal(tex2D(_LowNormalMap, fragment.uv)) * float3(_NormalScale, _NormalScale, 1)));
				float occlusion = tex2D(_OcclusionMap, fragment.uv).r;
				float3 emissive = tex2D(_EmissiveMap, fragment.uv).rgb;
				float curvature = saturate(tex2D(_CurvatureMap, fragment.uv).r + _CurvatureOffset);
				float3 positionWS = fragment.positionWS;
				//其他可推导的物体表面属性
				float perceptualRoughness = 1 - smoothness;
				float roughness = max(HALF_MIN_SQRT, pow(perceptualRoughness, 2));
				float roughness2 = roughness * roughness;
				float dielectricSpec = 0.04;
				float reflectivity = lerp(dielectricSpec, 1, metallic);
				float grazingTerm = saturate(reflectivity + smoothness);
				//相机信息
				float3 v = normalize(GetCameraPositionWS() - positionWS);

				//光照物理：能量守恒、双向反射分布
				float3 diffuse = lerp(albedo * (1 - dielectricSpec), 0, metallic);
				float3 specular = lerp(dielectricSpec, albedo, metallic);
				//光照物理：菲涅尔
				specular = lerp(specular, grazingTerm, pow(1 - saturate(dot(normal, v)), 4));

				//开始光照计算
				float3 finalColor = 0;
				//计算直接光
				{
					//收集直接光信息
					int lightCount = 1 + GetAdditionalLightsCount();
					Light lights[1 + 8]; //URP 支持最多 1盏主光源 + 8盏附加光源
					lights[0] = GetMainLight(TransformWorldToShadowCoord(positionWS), positionWS, 1);
					for (int i = 0; i < GetAdditionalLightsCount(); ++i)
						lights[i + 1] = GetAdditionalLight(i, positionWS, 1);
					//遍历计算光照
					for (int i = 0; i < lightCount; ++i)
					{
						//提取灯光信息
						Light light = lights[i];
						float3 l = light.direction;
						float3 h = normalize(v + l);
						//光照物理：辐照度、辐射率
						float3 irradiance = light.color * light.distanceAttenuation * light.shadowAttenuation;
						float3 radiance = irradiance * saturate(dot(normal, light.direction));
						//光照物理：镜射光
						float3 ggx = roughness2 / pow(1.0001f + (roughness2 - 1) * pow(saturate(dot(h, normal)), 2), 2);
						float3 geometryOcclusion = pow(saturate(dot(normal, l) * dot(normal, v)), 0.2) / lerp(roughness, 1, pow(saturate(dot(l, h)), 2));
						float3 specularTerm = ggx * geometryOcclusion / 3; //PBR：法线分布、几何遮蔽、归一化
						//光学物理：散射光
						//掠角次表面散射（该散射含辐射率系数）
						float3 rNormal = normalize(lerp(normal, lowNormal, _NormalWeight.r));
						float3 gNormal = normalize(lerp(normal, lowNormal, _NormalWeight.g));
						float3 bNormal = normalize(lerp(normal, lowNormal, _NormalWeight.b));
						float rHalfLambert = dot(rNormal, light.direction) * 0.5 + 0.5;
						float rAngleScattering = tex2D(_AngleScatteringMap, float2(rHalfLambert, curvature)).r;
						float gHalfLambert = dot(gNormal, light.direction) * 0.5 + 0.5;
						float gAngleScattering = tex2D(_AngleScatteringMap, float2(gHalfLambert, curvature)).g;
						float bHalfLambert = dot(bNormal, light.direction) * 0.5 + 0.5;
						float bAngleScattering = tex2D(_AngleScatteringMap, float2(bHalfLambert, curvature)).b;
						float3 angleScattering = float3(rAngleScattering, gAngleScattering, bAngleScattering);
						//角度次表面散射（该散射含阴影衰减）
						float3 shadowScattering = tex2D(_ShadowScatteringMap, float2(light.shadowAttenuation, curvature));
						//散射辐射率
						float3 scatteringIrradiance = light.color * light.distanceAttenuation * shadowScattering;
						float3 scatteringRadiance = scatteringIrradiance * angleScattering;

						//累加直接光照结果
						finalColor += diffuse * scatteringRadiance + specular * specularTerm * radiance;
					}
				}
				//计算间接光
				{
					//间接光辐射率
					float3 diffuseRadiance = SampleSH(normal);
					float mipLevel = perceptualRoughness * (1.7 - 0.7 * perceptualRoughness) * UNITY_SPECCUBE_LOD_STEPS;
					float4 encodeSpecularRadiance = unity_SpecCube0.SampleLevel(samplerunity_SpecCube0, reflect(-v, normal), mipLevel);
					float3 specularRadiance = DecodeHDREnvironment(encodeSpecularRadiance, unity_SpecCube0_HDR);
					//双向反射系数
					float3 diffuseTerm = 1;
					float3 specularTerm = 1 / (1 + roughness2); //几何遮蔽
					//累加间接光照结果
					float3 indirectColor = diffuse * diffuseTerm * diffuseRadiance + specular * specularTerm * specularRadiance;
					finalColor += indirectColor * occlusion;
				}
				//计算自发光
				finalColor += emissive;

				return float4(finalColor, 1);
			}
			ENDHLSL
		}

		UsePass "Universal Render Pipeline/Lit/DEPTHONLY"
		UsePass "Universal Render Pipeline/Lit/SHADOWCASTER"
	}
	//	Fallback "Universal Render Pipeline/Lit"
}