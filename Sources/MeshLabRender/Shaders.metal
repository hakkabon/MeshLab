#include <metal_stdlib>
using namespace metal;

struct FEMVertex {
    float3 position;
    float3 normal;
};

struct Uniforms {
    float4x4 mvp;
    float4 lightDirection;
    float stressMin;
    float stressMax;
    float deformationScale;
    uint flags;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
};

static float3 stressColor(float t) {
    t = clamp(t, 0.0, 1.0);
    const float3 c0 = float3(0.09, 0.30, 0.75);
    const float3 c1 = float3(0.10, 0.75, 0.85);
    const float3 c2 = float3(0.25, 0.80, 0.30);
    const float3 c3 = float3(0.98, 0.82, 0.15);
    const float3 c4 = float3(0.90, 0.16, 0.12);
    float s = t * 4.0;
    int segment = min(int(floor(s)), 3);
    float f = s - float(segment);
    float3 a = segment == 0 ? c0 : segment == 1 ? c1 : segment == 2 ? c2 : c3;
    float3 b = segment == 0 ? c1 : segment == 1 ? c2 : segment == 2 ? c3 : c4;
    return mix(a, b, f);
}

vertex VertexOut femVertex(
    uint vertexID [[vertex_id]],
    const device FEMVertex *vertices [[buffer(0)]],
    const device float3 *displacements [[buffer(1)]],
    const device float *stress [[buffer(2)]],
    constant Uniforms &uniforms [[buffer(3)]])
{
    FEMVertex input = vertices[vertexID];
    float3 position = input.position + displacements[vertexID] * uniforms.deformationScale;

    VertexOut out;
    out.position = uniforms.mvp * float4(position, 1.0);
    out.normal = input.normal;

    float denominator = max(uniforms.stressMax - uniforms.stressMin, 1e-20);
    float t = (stress[vertexID] - uniforms.stressMin) / denominator;
    out.color = (uniforms.flags & 1u) != 0
        ? stressColor(t)
        : float3(0.62, 0.66, 0.70);
    return out;
}

fragment float4 femFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(3)]])
{
    float3 normal = normalize(in.normal);
    float3 light = normalize(-uniforms.lightDirection.xyz);
    float diffuse = abs(dot(normal, light));
    float3 color = in.color * (0.32 + 0.68 * diffuse);
    return float4(color, 1.0);
}
