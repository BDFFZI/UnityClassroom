Shader "Hidden/Transmission"
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
		_OcclusionMap("OcclusionMap",2D) = "white"{}
		_EmissiveMap("EmissiveMap",2D) = "black"{}
		_Scattering("Scattering",Range(0,1)) = 0
		_Transmission("Transmission",Range(0,1)) = 0
		_ThicknessMap("ThicknessMap",2D) = "white"{}
		_Thickness("Thickness",Range(0,1)) = 0
		_TransmitPower("TransmitPower",Float) = 1
		_TransmitScale("TransmitScale",Float) = 1
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
			sampler2D _OcclusionMap;
			sampler2D _EmissiveMap;
			float _Scattering;
			float _Transmission;
			sampler2D _ThicknessMap;
			float _Thickness;
			float _TransmitPower;
			float _TransmitScale;

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
				float3 normal = mul(tangentToWorld, UnpackNormal(tex2D(_NormalMap, fragment.uv)));
				float occlusion = tex2D(_OcclusionMap, fragment.uv).r;
				float3 emissive = tex2D(_EmissiveMap, fragment.uv).rgb;
				float scattering = _Scattering;
				float transmission = _Transmission;
				float thickness = tex2D(_ThicknessMap, fragment.uv).r * _Thickness;
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
				float3 scatter = lerp(albedo * (1 - dielectricSpec), 0, metallic);
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
					for (int i = 1; i < lightCount; ++i)
					{
						//提取灯光信息
						Light light = lights[i];
						float3 l = light.direction;
						float3 h = normalize(v + l);
						//镜射光
						float3 specularIrradiance = light.color * light.distanceAttenuation * light.shadowAttenuation;
						float3 specularRadiance = specularIrradiance * saturate(dot(normal, light.direction));
						float3 ggx = roughness2 / pow(1.0001f + (roughness2 - 1) * pow(saturate(dot(h, normal)), 2), 2);
						float3 geometryOcclusion = pow(saturate(dot(normal, l) * dot(normal, v)), 0.2) / lerp(roughness, 1, pow(saturate(dot(l, h)), 2));
						float3 specularTerm = ggx * geometryOcclusion / 3; //PBR：法线分布、几何遮蔽、归一化
						float3 specularColor = specular * specularTerm * specularRadiance;
						//散射光
						float lambertTermLUF = saturate(dot(normal, light.direction)); //标准兰伯特散射强度曲线
						float scatterTermLUF = (2 * pow(dot(normal, light.direction), 2) - 1) * 0.5 + 0.5; //最大透射时散射强度曲线
						float3 scatteringIrradiance = light.color * light.distanceAttenuation;
						float diffuseRadianceTerm = lerp(lambertTermLUF * light.shadowAttenuation, scatterTermLUF * (1 - thickness), scattering);
						float transmitRadianceTerm = pow(dot(-normalize(l + normal * thickness), v) * 0.5 + 0.5, _TransmitPower) * _TransmitScale;
						float scatteringRadianceTerm = lerp(diffuseRadianceTerm, transmitRadianceTerm, transmission);
						float3 scatteringRadiance = scatteringIrradiance * scatteringRadianceTerm;
						float3 scatteringColor = scatter * scatteringRadiance;

						//累加直接光照结果
						finalColor += specularColor + scatteringColor;
					}
				}
				//计算间接光
				{
					//间接镜射光
					float mipLevel = perceptualRoughness * (1.7 - 0.7 * perceptualRoughness) * UNITY_SPECCUBE_LOD_STEPS;
					float4 encodeSpecularRadiance = unity_SpecCube0.SampleLevel(samplerunity_SpecCube0, reflect(-v, normal), mipLevel);
					float3 specularRadiance = DecodeHDREnvironment(encodeSpecularRadiance, unity_SpecCube0_HDR);
					float3 specularTerm = 1 / (1 + roughness2); //几何遮蔽
					float3 specularColor = specular * specularTerm * specularRadiance;
					//间接散射光
					float3 diffuseRradiance = SampleSH(normal);
					float3 bl = -normalize(-v + normal * thickness);
					float3 transmitIrradiance = SampleSH(-bl);
					float3 transmitRadiance = pow(transmitIrradiance, _TransmitPower) * _TransmitScale;
					float3 scatteringColor = scatter * lerp(diffuseRradiance, transmitRadiance * (1 - thickness), transmission);
					//累加间接光照结果
					float3 indirectColor = scatteringColor + specularColor;
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