using System.Collections.Generic;
using UnityEngine;

[ExecuteAlways]
[RequireComponent(typeof(MeshFilter))]
public class ShowMeshInfo : MonoBehaviour
{
    [SerializeField] bool showNormals;
    [SerializeField] bool showTangents;
    [SerializeField] bool showBitangents;
    [SerializeField] float rayLength = 0.05f;

    Mesh mesh;
    List<Vector3> vertices;
    List<Vector3> normals;
    List<Vector4> tangents;

    void OnEnable()
    {
        mesh = Application.isPlaying ? GetComponent<MeshFilter>().mesh : GetComponent<MeshFilter>().sharedMesh;
        vertices = new List<Vector3>();
        normals = new List<Vector3>();
        tangents = new List<Vector4>();
    }

    void OnDrawGizmosSelected()
    {
        mesh.GetVertices(vertices);
        Gizmos.matrix = transform.localToWorldMatrix;

        if (showNormals)
        {
            Gizmos.color = Color.blue;
            mesh.GetNormals(normals);
            for (int index = 0; index < vertices.Count; index++)
                Gizmos.DrawRay(vertices[index], normals[index] * rayLength);
        }

        if (showTangents)
        {
            Gizmos.color = Color.red;
            mesh.GetTangents(tangents);
            for (int index = 0; index < vertices.Count; index++)
                Gizmos.DrawRay(vertices[index], tangents[index] * rayLength);
        }

        if (showBitangents)
        {
            Gizmos.color = Color.green;
            mesh.GetTangents(tangents);
            for (int index = 0; index < vertices.Count; index++)
                Gizmos.DrawRay(vertices[index], Vector3.Cross(tangents[index], normals[index]) * rayLength);
        }
    }
}
