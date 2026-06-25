/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`. Kept as a Swift
/// string deliberately: it sidesteps SwiftPM `.metal` → metallib bundling, which is fragile under
/// `swift run`. `TrailVertex` here must match the Swift `TrailVertex` (packed_float3 + uint, 16 B).
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TrailVertex {
    packed_float3 position;
    uint color;
};

struct Uniforms {
    float4x4 mvp;
};

struct VOut {
    float4 position [[position]];
    float4 color;
};

vertex VOut line_vertex(uint vid [[vertex_id]],
                        device const TrailVertex* verts [[buffer(0)]],
                        constant Uniforms& u [[buffer(1)]]) {
    TrailVertex v = verts[vid];
    VOut out;
    out.position = u.mvp * float4(v.position, 1.0);
    out.color = unpack_unorm4x8_to_float(v.color);
    return out;
}

fragment float4 line_fragment(VOut in [[stage_in]]) {
    // Additive blend (set in the pipeline) turns overlapping segments into a density glow.
    return float4(in.color.rgb * in.color.a, in.color.a);
}
"""
