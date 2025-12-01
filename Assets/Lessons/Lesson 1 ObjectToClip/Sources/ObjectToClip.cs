using Unity.Mathematics;
using UnityEngine;
using UnityEngine.Rendering;

[ExecuteAlways]
public class ObjectToClip : MonoBehaviour
{
    static readonly int MatrixM = Shader.PropertyToID("MATRIX_M");
    static readonly int MatrixV = Shader.PropertyToID("MATRIX_V");
    static readonly int MatrixP = Shader.PropertyToID("MATRIX_P");
    static readonly int MatrixMvp = Shader.PropertyToID("MATRIX_MVP");

    Material material;

    void OnEnable()
    {
        material = GetComponent<Renderer>().sharedMaterial;

        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
    }

    void OnDisable()
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
    }

    float4x4 GetObjectToWorld(Transform transform)
    {
        float3 position = transform.localPosition;
        float3 rotation = transform.localEulerAngles;
        float3 scale = transform.localScale;

        float4x4 translateMatrix = new float4x4(
            1, 0, 0, position.x,
            0, 1, 0, position.y,
            0, 0, 1, position.z,
            0, 0, 0, 1
        );

        float3 rotationRad = math.radians(rotation);
        float4x4 rotateXMatrix = new float4x4(
            1, 0, 0, 0,
            0, math.cos(rotationRad.x), -math.sin(rotationRad.x), 0,
            0, math.sin(rotationRad.x), math.cos(rotationRad.x), 0,
            0, 0, 0, 1
        );
        float4x4 rotateYMatrix = new float4x4(
            math.cos(rotationRad.y), 0, math.sin(rotationRad.y), 0,
            0, 1, 0, 0,
            -math.sin(rotationRad.y), 0, math.cos(rotationRad.y), 0,
            0, 0, 0, 1
        );
        float4x4 rotateZMatrix = new float4x4(
            math.cos(rotationRad.z), -math.sin(rotationRad.z), 0, 0,
            math.sin(rotationRad.z), math.cos(rotationRad.z), 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        );

        float4x4 scaleMatrix = new float4x4(
            scale.x, 0, 0, 0,
            0, scale.y, 0, 0,
            0, 0, scale.z, 0,
            0, 0, 0, 1
        );

        float4x4 localToParent = math.mul(translateMatrix, math.mul(rotateYMatrix, math.mul(rotateXMatrix, math.mul(rotateZMatrix, scaleMatrix))));
        if (transform.parent == null)
            return localToParent;
        return math.mul(GetObjectToWorld(transform.parent), localToParent);
    }
    float4x4 GetWorldToCamera(Transform cameraTransform)
    {
        float4x4 worldToCamera = math.inverse(GetObjectToWorld(cameraTransform.transform));
        // //math是按列存储，所以要么用矩阵，要么就得用如此抽象的方法按行赋值
        // worldToCamera[0][2] *= -1;
        // worldToCamera[1][2] *= -1;
        // worldToCamera[2][2] *= -1;
        // worldToCamera[3][2] *= -1;

        float4x4 inverseZ = new float4x4(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, -1, 0,
            0, 0, 0, 1
        );

        return math.mul(inverseZ, worldToCamera);
    }
    float4x4 GetViewToClip(Camera camera)
    {
        float n = camera.nearClipPlane;
        float f = camera.farClipPlane;
        float h = math.tan(math.radians(camera.fieldOfView) / 2) * n;
        float w = camera.aspect * h;

        float4x4 orthographic = new float4x4(
            1 / w, 0, 0, 0,
            0, 1 / h, 0, 0,
            0, 0, -2 / (f - n), 1 - (2 * f) / (f - n),
            0, 0, 0, 1
        );

        if (camera.orthographic)
            return orthographic;

        float4x4 projection = new float4x4(
            n, 0, 0, 0,
            0, n, 0, 0,
            0, 0, f + n, n * f,
            0, 0, -1, 0
        );

        return math.mul(orthographic, projection);
    }

    void OnBeginCameraRendering(ScriptableRenderContext arg1, Camera camera)
    {
        float4x4 objectToWorld = GetObjectToWorld(transform);
        float4x4 worldToView = GetWorldToCamera(camera.transform);
        float4x4 viewToClip = GL.GetGPUProjectionMatrix(GetViewToClip(camera), true);
        float4x4 mvp = math.mul(viewToClip, math.mul(worldToView, objectToWorld));

        material.SetMatrix(MatrixM, objectToWorld);
        material.SetMatrix(MatrixV, worldToView);
        material.SetMatrix(MatrixP, viewToClip);
        material.SetMatrix(MatrixMvp, mvp);
    }
}
