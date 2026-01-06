Shader "Hidden/ObjectToClip"
{
	Properties {}
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
			
			struct Vertex
			{
				float3 positionOS : POSITION;
			};

			struct Fragment
			{
				float4 positionCS_SV : SV_POSITION;
			};

			float4x4 MATRIX_M;
			float4x4 MATRIX_V;
			float4x4 MATRIX_P;
			float4x4 MATRIX_MVP;

			Fragment VertexPass(Vertex vertex)
			{
				float4 positionWS = mul(MATRIX_M, float4(vertex.positionOS, 1));
				float4 positionVS = mul(MATRIX_V, positionWS);
				float4 positionCS = mul(MATRIX_P, positionVS);

				Fragment fragment;
				fragment.positionCS_SV = positionCS;
				// fragment.positionCS_SV = mul(MATRIX_MVP, float4(vertex.positionOS, 1));
				return fragment;
			}

			float4 FragmentPass(Fragment fragment) : SV_Target
			{
				return 1;
			}
			ENDHLSL
		}
	}
}