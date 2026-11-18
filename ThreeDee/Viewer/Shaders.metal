//
//  Shaders.metal
//  ThreeDee
//
//  Duotone shading: surfaces blend from a shadow ink to a lit paper tone,
//  with a soft rim; lines and points share the same palette.
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4x4 view;
    float4 shadowColor;   // deep tone
    float4 litColor;      // light tone
    float4 lineColor;     // edges / wireframe
    float4 cameraPosition;
    float4 lightDirection;
    float4 params;        // x: point size (px), y: original colours (0/1), z: has normals, w: depth bias
    float4 grid;          // xy: fade centre, z: fade radius (camera distance for points), w: scene radius
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float4 color;
    float pointSize [[point_size]];
};

vertex MeshOut meshVertex(uint vid [[vertex_id]],
                          const device packed_float3 *positions [[buffer(0)]],
                          const device packed_float3 *normals [[buffer(1)]],
                          const device uchar4 *colors [[buffer(2)]],
                          constant Uniforms &u [[buffer(3)]]) {
    MeshOut out;
    float3 p = float3(positions[vid]);
    out.world = p;
    out.position = u.viewProjection * float4(p, 1.0);
    out.position.z -= u.params.w * out.position.w;
    out.normal = u.params.z > 0.5 ? float3(normals[vid]) : float3(0.0);
    out.color = u.params.y > 0.5 ? float4(colors[vid]) / 255.0 : float4(1.0);
    out.pointSize = u.params.x;
    return out;
}

static float3 shade(MeshOut in, constant Uniforms &u, bool frontFacing) {
    float3 n = normalize(in.normal);
    if (!frontFacing) { n = -n; }
    float3 v = normalize(u.cameraPosition.xyz - in.world);
    float3 l = normalize(u.lightDirection.xyz);
    float key = max(dot(n, l), 0.0);
    float fill = max(dot(n, normalize(v + float3(0, 0, 0.6))), 0.0);
    float rim = pow(1.0 - saturate(dot(n, v)), 3.0);
    float t = saturate(0.08 + 0.62 * key + 0.32 * fill);
    float3 base;
    if (u.params.y > 0.5) {
        float3 c = in.color.rgb;
        base = c * (0.30 + 0.70 * t) + float3(0.10) * pow(key, 24.0);
        base = mix(base, u.shadowColor.rgb, rim * 0.25);
    } else {
        base = mix(u.shadowColor.rgb, u.litColor.rgb, t);
        base = mix(base, u.shadowColor.rgb, rim * 0.35);
        base += (u.litColor.rgb - base) * pow(key, 32.0) * 0.6;
    }
    return base;
}

fragment float4 meshFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]], bool front [[front_facing]]) {
    return float4(shade(in, u, front), 1.0);
}

fragment float4 flatFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]]) {
    return u.lineColor;
}

fragment float4 pointFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]],
                              float2 coord [[point_coord]], bool front [[front_facing]]) {
    float2 d = coord - 0.5;
    if (dot(d, d) > 0.25) { discard_fragment(); }
    float3 c;
    if (u.params.z > 0.5) {
        c = shade(in, u, true);
    } else if (u.params.y > 0.5) {
        c = in.color.rgb;
    } else {
        // Depth cue without normals: nearer points are deeper ink, farther ones fade towards paper.
        float dist = length(u.cameraPosition.xyz - in.world);
        float k = saturate((dist - (u.grid.z - u.grid.w)) / max(2.0 * u.grid.w, 1e-6));
        c = mix(u.shadowColor.rgb, mix(u.shadowColor.rgb, u.litColor.rgb, 0.7), k);
    }
    return float4(c, 1.0);
}

// MARK: Lines (grid, axes, feature edges)

struct LineOut {
    float4 position [[position]];
    float alpha;
    float2 planar;
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          const device float4 *vertices [[buffer(0)]],
                          constant Uniforms &u [[buffer(3)]]) {
    LineOut out;
    float4 v = vertices[vid];
    out.position = u.viewProjection * float4(v.xyz, 1.0);
    out.position.z -= u.params.w * out.position.w;
    out.alpha = v.w;
    out.planar = v.xy;
    return out;
}

fragment float4 lineFragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(3)]]) {
    return float4(u.lineColor.rgb, u.lineColor.a * in.alpha);
}

fragment float4 gridFragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(3)]]) {
    float r = length(in.planar - u.grid.xy) / max(u.grid.z, 1e-3);
    float fade = 1.0 - smoothstep(0.55, 1.0, r);
    return float4(u.lineColor.rgb, u.lineColor.a * in.alpha * fade);
}
