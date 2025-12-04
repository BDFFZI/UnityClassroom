Shader "Hidden/Anisotropy"
{
	Properties
	{
		_AlbedoMap("AlbedoMap",2D) = "white"{}
		[HDR]_Albedo ("Albedo", Color) = (1,1,1,1)
		_MetallicMap("MetallicMap",2D) = "white"{}
		_Metallic("Metallic",Range(0,1)) = 0
		_RoughnessMap("RoughnessMap",2D) = "white"{}
		_Roughness("Roughness",Range(0,1)) = 0.5

		_NormalMap("NormalMap",2D) = "bump"{}
		_OcclusionMap("OcclusionMap",2D) = "white"{}
		_EmissiveMap("EmissiveMap",2D) = "black"{}

		[KeywordEnum(Tangent,Bitangent)] _AnisotropyMode("AnisotropyMode",Float) = 1
		_AnisotropyMap("AnisotropyMap",2D) = "white"{}
		_AlbedoDisturbance("AlbedoDisturbance",Range(0,1)) = 0
		_DisturbanceIntensity("DisturbanceIntensity",Range(0,2)) = 1
		_DisturbanceOffset("DisturbanceOffset",Float) = 0
		_DisturbanceColor("DisturbanceColor",Color) = (1,1,1,1)
		_DisturbanceIntensity2("DisturbanceIntensity2",Range(0,2)) = 1
		_DisturbanceOffset2("DisturbanceOffset2",Float) = 0
		_DisturbanceColor2("DisturbanceColor2",Color) = (1,1,1,1)
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
			#pragma shader_feature_local _ANISOTROPYMODE_TANGENT _ANISOTROPYMODE_BITANGENT

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
			sampler2D _OcclusionMap;
			sampler2D _EmissiveMap;

			sampler2D _AnisotropyMap;
			float _AlbedoDisturbance;
			float4 _AnisotropyMap_ST;
			float _DisturbanceIntensity;
			float _DisturbanceOffset;
			float4 _DisturbanceColor;
			float _DisturbanceIntensity2;
			float _DisturbanceOffset2;
			float4 _DisturbanceColor2;

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

				float anisotropy = tex2D(_AnisotropyMap, fragment.uv * _AnisotropyMap_ST.xy).r;
				//物体表面属性
				float3 albedo = _Albedo.rgb * tex2D(_AlbedoMap, fragment.uv).rgb * lerp(1, anisotropy, _AlbedoDisturbance);
				float metallic = _Metallic * tex2D(_MetallicMap, fragment.uv).r;
				float smoothness = 1 - sqrt(_Roughness * tex2D(_RoughnessMap, fragment.uv).r);
				float3 normal = mul(tangentToWorld, UnpackNormal(tex2D(_NormalMap, fragment.uv)));
				float occlusion = tex2D(_OcclusionMap, fragment.uv).r;
				float3 emissive = tex2D(_EmissiveMap, fragment.uv).rgb;
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
						//镜反射系数
						#ifdef _ANISOTROPYMODE_TANGENT
						float3 bitangent = tangentToWorld._m00_m10_m20;
						#else
						float3 bitangent = tangentToWorld._m01_m11_m21;
						#endif

						float disturbance = (anisotropy - 0.5) * _DisturbanceIntensity + _DisturbanceOffset;
						float3 disturbedBitangent = normalize(bitangent + normal * disturbance);
						float blinnCardinal = saturate(sqrt(1 - pow(dot(h, disturbedBitangent), 2)));
						float blinn = pow(blinnCardinal, max(2 / roughness2 - 2, 0.0001)) * (1 / roughness2);
						float3 kkColor = blinn * lerp(specular, _DisturbanceColor.rgb, _DisturbanceColor.a);

						float disturbance2 = (anisotropy - 0.5) * _DisturbanceIntensity2 + _DisturbanceOffset2;
						float3 disturbedBitangent2 = normalize(bitangent + normal * disturbance2);
						float blinnCardinal2 = saturate(sqrt(1 - pow(dot(h, disturbedBitangent2), 2)));
						float blinn2 = pow(blinnCardinal2, max(2 / roughness2 - 2, 0.0001)) * (1 / roughness2);
						float3 kkColor2 = blinn2 * lerp(specular, _DisturbanceColor2.rgb, _DisturbanceColor2.a);

						float geometryOcclusion = pow(saturate(dot(normal, l) * dot(normal, v)), 0.2) / lerp(roughness, 1, pow(saturate(dot(l, h)), 2));
						float3 specularColor = (kkColor + kkColor2) / 2 * geometryOcclusion / 3; //PBR：法线分布、几何遮蔽、归一化
						//累加直接光照结果
						finalColor += (diffuse + specularColor) * radiance;
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