Shader "Hidden/TangentSpace"
{
	Properties
	{
		_NormalMap ("NormalMap", 2D) = "bump" {}
		_NormalScale("NormalScale",Float) = 1
	}
	SubShader
	{
		Tags
		{
			"LightType"="UniversalForward"
		}

		Pass
		{
			HLSLPROGRAM
			#pragma vertex VertexPass
			#pragma fragment FragmentPass

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
				float2 uv:TEXCOORD0;
				float3 normalWS:NORMAL;
				float3 tangentWS:TANGENT;
				float3 bitangentWS:TEXCOORD1;
			};

			sampler2D _NormalMap;
			float4 _NormalMap_ST;
			float _NormalScale;

			Fragment VertexPass(Vertex vertex)
			{
				Fragment fragment;
				fragment.positionCS_SV = TransformObjectToHClip(vertex.positionOS);
				fragment.uv = TRANSFORM_TEX(vertex.uv, _NormalMap);
				fragment.normalWS = mul(vertex.normalOS, (float3x3)GetWorldToObjectMatrix());
				fragment.tangentWS = mul((float3x3)GetObjectToWorldMatrix(), vertex.tangentOS.xyz);
				fragment.bitangentWS = cross(fragment.normalWS, fragment.tangentWS) * vertex.tangentOS.w;
				return fragment;
			}

			float4 FragmentPass(Fragment fragment) : SV_Target
			{
				float3x3 worldToTangent = float3x3(
					normalize(fragment.tangentWS),
					normalize(fragment.bitangentWS),
					normalize(fragment.normalWS)
				);

				float3 normalTS = tex2D(_NormalMap, fragment.uv).xyz * 2 - 1;
				normalTS *= step(0.012f, abs(normalTS)); // 255精度 + 压缩导致无法精准存储 0.5，所以需要手动舍入。
				normalTS = normalize(normalTS * float3(_NormalScale, _NormalScale, 1));
				float3 normal = mul(normalTS, worldToTangent);

				// float3x3 tangentToWorld = transpose(worldToTangent);
				// float3 normal = mul(tangentToWorld, normalTS);

				Light light = GetMainLight();
				float lambert = saturate(dot(light.direction, normal));
				return float4((float3)lambert, 1);
			}
			ENDHLSL
		}
	}
}