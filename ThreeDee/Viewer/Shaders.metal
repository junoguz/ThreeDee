//
//  Shaders.metal
//  ThreeDee
//
//  Duotone shading: surfaces blend from a shadow ink to a lit paper tone,
//  with a soft rim; lines and points share the same palette. With original
//  colours on, the file's own appearance (vertex colours × material colour ×
//  texture, plus emission) is shown with neutral, colour-preserving light.
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
    float4 material;      // x: base texture, y: emissive texture, z: shading amount (0 = unlit), w: alpha cutoff
    float4 baseColor;     // material colour (sRGB)
    float4 emissive;      // rgb: emitted colour (sRGB), w: vertex colours present
    float4 points;        // x: world radius (0 = fixed size), y: focal length (px), z: per-point radii, w: max size (px)
    float4 splat;         // x: splats nearer than this (view depth) are skipped
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float4 color;
    float2 uv;
    float pointSize [[point_size]];
};

vertex MeshOut meshVertex(uint vid [[vertex_id]],
                          const device packed_float3 *positions [[buffer(0)]],
                          const device packed_float3 *normals [[buffer(1)]],
                          const device uchar4 *colors [[buffer(2)]],
                          constant Uniforms &u [[buffer(3)]],
                          const device packed_float2 *uvs [[buffer(4)]],
                          const device float *radii [[buffer(5)]]) {
    MeshOut out;
    float3 p = float3(positions[vid]);
    out.world = p;
    out.position = u.viewProjection * float4(p, 1.0);
    out.position.z -= u.params.w * out.position.w;
    out.normal = u.params.z > 0.5 ? float3(normals[vid]) : float3(0.0);
    out.color = (u.params.y > 0.5 && u.emissive.w > 0.5) ? float4(colors[vid]) / 255.0 : float4(1.0);
    out.uv = (u.material.x > 0.5 || u.material.y > 0.5) ? float2(uvs[vid]) : float2(0.0);
    float size = u.params.x;
    float radius = u.points.z > 0.5 ? radii[vid] : 0.0;
    if (radius <= 0.0) { radius = u.points.x; }
    if (radius > 0.0) {
        // World-sized discs: a splat or scan point covers what it covered in the real space.
        size = clamp(2.0 * radius * u.points.y / max(out.position.w, 1e-6), 1.0, u.points.w);
    }
    out.pointSize = size;
    return out;
}

constexpr sampler materialSampler(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));

/// Key + fill light term (0…1) shared by both shading styles.
static float lightTerm(MeshOut in, constant Uniforms &u, bool frontFacing, thread float &key, thread float &rim) {
    float3 n = normalize(in.normal);
    if (!frontFacing) { n = -n; }
    float3 v = normalize(u.cameraPosition.xyz - in.world);
    float3 l = normalize(u.lightDirection.xyz);
    key = max(dot(n, l), 0.0);
    float fill = max(dot(n, normalize(v + float3(0, 0, 0.6))), 0.0);
    rim = pow(1.0 - saturate(dot(n, v)), 3.0);
    return saturate(0.08 + 0.62 * key + 0.32 * fill);
}

/// The file's own surface colour before lighting.
static float4 albedo(MeshOut in, constant Uniforms &u, texture2d<float> baseTexture) {
    float4 c = in.color * u.baseColor;
    if (u.material.x > 0.5) { c *= baseTexture.sample(materialSampler, in.uv); }
    return c;
}

/// Original colours: neutral light that only modulates brightness, so hues stay true. Emission
/// (often a baked-lighting copy of the base texture) wins where it is brighter.
static float3 shadeAppearance(MeshOut in, constant Uniforms &u, bool frontFacing, float3 base, float3 emitted) {
    float key = 0.0, rim = 0.0;
    float amount = u.material.z;
    float3 lit = base;
    if (amount > 0.0 && u.params.z > 0.5) {
        float t = lightTerm(in, u, frontFacing, key, rim);
        lit = base * mix(1.0, 0.38 + 0.72 * t, amount) + float3(0.08 * amount) * pow(key, 24.0);
    }
    return max(lit, emitted);
}

static float3 shadeDuotone(MeshOut in, constant Uniforms &u, bool frontFacing) {
    float key = 0.0, rim = 0.0;
    float t = lightTerm(in, u, frontFacing, key, rim);
    float3 base = mix(u.shadowColor.rgb, u.litColor.rgb, t);
    base = mix(base, u.shadowColor.rgb, rim * 0.35);
    base += (u.litColor.rgb - base) * pow(key, 32.0) * 0.6;
    return base;
}

fragment float4 meshFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]], bool front [[front_facing]],
                             texture2d<float> baseTexture [[texture(0)]], texture2d<float> emissiveTexture [[texture(1)]]) {
    if (u.params.y < 0.5) { return float4(shadeDuotone(in, u, front), 1.0); }
    float4 c = albedo(in, u, baseTexture);
    if (u.material.w > 0.0 && c.a < u.material.w) { discard_fragment(); }
    float3 emitted = u.emissive.rgb;
    if (u.material.y > 0.5) { emitted *= emissiveTexture.sample(materialSampler, in.uv).rgb; }
    return float4(shadeAppearance(in, u, front, c.rgb, emitted), 1.0);
}

fragment float4 flatFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]]) {
    return u.lineColor;
}

fragment float4 pointFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(3)]],
                              float2 coord [[point_coord]], bool front [[front_facing]]) {
    float2 d = coord - 0.5;
    if (dot(d, d) > 0.25) { discard_fragment(); }
    float3 c;
    if (u.params.y > 0.5) {
        float3 base = in.color.rgb * u.baseColor.rgb;
        c = u.params.z > 0.5 ? shadeAppearance(in, u, true, base, float3(0.0)) : base;
    } else if (u.params.z > 0.5) {
        c = shadeDuotone(in, u, true);
    } else {
        // Depth cue without normals: nearer points are deeper ink, farther ones fade towards paper.
        float dist = length(u.cameraPosition.xyz - in.world);
        float k = saturate((dist - (u.grid.z - u.grid.w)) / max(2.0 * u.grid.w, 1e-6));
        c = mix(u.shadowColor.rgb, mix(u.shadowColor.rgb, u.litColor.rgb, 0.7), k);
    }
    return float4(c, 1.0);
}

// MARK: Gaussian splats

struct SplatShape { float3 upper; float3 lower; };   // covariance (xx, xy, xz), (yy, yz, zz)

struct SplatOut {
    float4 position [[position]];
    float4 color;
    float2 corner;
};

/// One screen-aligned quad per splat (instanced), drawn far-to-near in `order`. The 3D covariance is
/// projected to 2D (EWA splatting); the quad spans the ellipse's axes, scaled so that the Gaussian
/// is simply exp(-|corner|²) across it.
vertex SplatOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device packed_float3 *positions [[buffer(0)]],
                            const device uchar4 *colors [[buffer(2)]],
                            constant Uniforms &u [[buffer(3)]],
                            const device SplatShape *shapes [[buffer(5)]],
                            const device uint *order [[buffer(6)]]) {
    SplatOut out;
    uint i = order[iid];
    out.corner = float2((vid & 1) ? 2.0 : -2.0, (vid & 2) ? 2.0 : -2.0);
    out.color = float4(0.0);
    out.position = float4(0.0, 0.0, 2.0, 1.0); // outside the clip volume: culled
    float3 p = float3(positions[i]);
    float4 t = u.view * float4(p, 1.0);
    float4 clip = u.viewProjection * float4(p, 1.0);
    float z = -t.z;
    if (z <= max(u.splat.x, 1e-6) || clip.w <= 0.0) { return out; }
    float fx = u.points.x, fy = u.points.y;
    // Jacobian of the projection in pixels (x right, y up), as columns.
    float3x3 J = float3x3(float3(fx / z, 0.0, 0.0), float3(0.0, fy / z, 0.0),
                          float3(fx * t.x / (z * z), fy * t.y / (z * z), 0.0));
    float3x3 W = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    SplatShape c = shapes[i];
    float3x3 S = float3x3(float3(c.upper.x, c.upper.y, c.upper.z), float3(c.upper.y, c.lower.x, c.lower.y),
                          float3(c.upper.z, c.lower.y, c.lower.z));
    float3x3 T = J * W;
    float3x3 cov = T * S * transpose(T);
    // Low-pass: at least ~half a pixel, which also keeps tiny splats from aliasing.
    float a = cov[0][0] + 0.3, b = cov[0][1], d = cov[1][1] + 0.3;
    float mid = 0.5 * (a + d);
    float spread = length(float2(0.5 * (a - d), b));
    float l1 = mid + spread, l2 = max(mid - spread, 0.1);
    float2 v1 = abs(b) > 1e-9 ? normalize(float2(b, l1 - a)) : (a >= d ? float2(1.0, 0.0) : float2(0.0, 1.0));
    float2 major = min(sqrt(2.0 * l1), 1024.0) * v1;
    float2 minor = min(sqrt(2.0 * l2), 1024.0) * float2(v1.y, -v1.x);
    float2 offset = out.corner.x * major + out.corner.y * minor;
    out.position = clip + float4(offset * 2.0 / u.points.zw * clip.w, 0.0, 0.0);
    float4 rgba = float4(colors[i]) / 255.0;
    float3 rgb = rgba.rgb;
    if (u.params.y < 0.5) {
        // Drafting look: depth-cued ink like other point clouds.
        float k = saturate((length(u.cameraPosition.xyz - p) - (u.grid.z - u.grid.w)) / max(2.0 * u.grid.w, 1e-6));
        rgb = mix(u.shadowColor.rgb, mix(u.shadowColor.rgb, u.litColor.rgb, 0.7), k);
    }
    out.color = float4(rgb, rgba.a);
    return out;
}

/// Premultiplied output for back-to-front "over" blending.
fragment float4 splatFragment(SplatOut in [[stage_in]]) {
    float power = -dot(in.corner, in.corner);
    if (power < -4.0) { discard_fragment(); }
    float alpha = min(exp(power) * in.color.a, 0.99);
    if (alpha < 1.0 / 255.0) { discard_fragment(); }
    return float4(in.color.rgb * alpha, alpha);
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

/// Grid and axis lines with real thickness: each segment (one instance) becomes a screen-space quad
/// `width.x` pixels wide in a viewport of `width.yz` pixels. Segments are clipped to the near plane
/// first so lines that pass behind the eye (inside a model) still draw correctly.
vertex LineOut wideLineVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device float4 *vertices [[buffer(0)]],
                              constant Uniforms &u [[buffer(3)]],
                              constant float4 &width [[buffer(7)]]) {
    LineOut out;
    float4 va = vertices[iid * 2], vb = vertices[iid * 2 + 1];
    float4 a = u.viewProjection * float4(va.xyz, 1.0);
    float4 b = u.viewProjection * float4(vb.xyz, 1.0);
    // Near plane is clip z = 0 (Metal depth 0…1).
    if (a.z < 0.0 && b.z < 0.0) {
        out.position = float4(2.0, 2.0, 2.0, 1.0);   // fully behind: degenerate, nothing drawn
        out.alpha = 0.0;
        out.planar = va.xy;
        return out;
    }
    float ta = 0.0, tb = 1.0;
    if (a.z < 0.0) { ta = a.z / (a.z - b.z); }
    if (b.z < 0.0) { tb = 1.0 - b.z / (b.z - a.z); }
    float4 ca = mix(a, b, ta), cb = mix(a, b, tb);
    float2 half_viewport = max(width.yz * 0.5, float2(1.0));
    float2 sa = ca.xy / ca.w * half_viewport, sb = cb.xy / cb.w * half_viewport;
    float2 dir = sb - sa;
    float len = length(dir);
    float2 normal = len > 1e-5 ? float2(-dir.y, dir.x) / len : float2(0.0, 1.0);
    bool endB = vid >= 2;
    float side = (vid & 1) ? 1.0 : -1.0;
    float4 p = endB ? cb : ca;
    p.xy += normal * side * (width.x * 0.5) / half_viewport * p.w;
    out.position = p;
    out.position.z -= u.params.w * out.position.w;
    out.alpha = va.w;
    out.planar = mix(va.xy, vb.xy, endB ? tb : ta);
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

// MARK: VR lens pre-distortion

struct DistortionUniforms {
    float4 lens;        // xy: lens centre (px), z: mm per px, w: screen-to-lens distance (mm)
    float4 distortion;  // x: k1, y: k2, z: divider x (px), w: divider half-width (px)
    float4 tangents;    // min x, max x, min y, max y of the eye's render frustum
    float4 uvRect;      // eye image rectangle in the shared eye texture (u0, v0, u1, v1)
    float4 background;
};

struct QuadOut { float4 position [[position]]; };

vertex QuadOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QuadOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

/// For each screen pixel: where does the lens make it appear (tangent-angle units, radial
/// polynomial), and what does the undistorted eye image show in that direction?
fragment float4 distortionFragment(QuadOut in [[stage_in]], constant DistortionUniforms &d [[buffer(0)]],
                                   texture2d<float> eyeImage [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (abs(in.position.x - d.distortion.z) < d.distortion.w) { return float4(0.42, 0.47, 0.56, 1.0); }
    float2 mm = (in.position.xy - d.lens.xy) * d.lens.z;
    float2 t = float2(mm.x, -mm.y) / d.lens.w;
    float r2 = dot(t, t);
    t *= 1.0 + d.distortion.x * r2 + d.distortion.y * r2 * r2;
    float2 uv = float2((t.x - d.tangents.x) / (d.tangents.y - d.tangents.x),
                       (d.tangents.w - t.y) / (d.tangents.w - d.tangents.z));
    if (any(uv < 0.0) || any(uv > 1.0)) { return d.background; }
    float2 edge = min(uv, 1.0 - uv);
    float fade = smoothstep(0.0, 0.035, min(edge.x, edge.y));
    float3 c = eyeImage.sample(s, mix(d.uvRect.xy, d.uvRect.zw, uv)).rgb;
    return float4(mix(d.background.rgb, c, fade), 1.0);
}
