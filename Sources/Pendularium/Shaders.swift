/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`. Kept as a Swift
/// string deliberately: it sidesteps SwiftPM `.metal` → metallib bundling, which is fragile under
/// `swift run`. `TrailVertex`/`Uniforms` here must match the Swift structs.
///
/// Color is computed here from per-vertex scalars + the `colorMode` uniform, so changing color
/// mode recolors the entire accumulated painting instantly with no buffer rewrite.
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TrailVertex {
    packed_float3 position;
    uint attribs;
};

struct Uniforms {
    float4x4 mvp;
    float4 modeParams;  // x = colorMode
};

struct VOut {
    float4 position [[position]];
    float4 color;
};

// Cool→hot gradient (deep blue → cyan → green → yellow → orange → red).
static float3 coolHot(float t) {
    t = clamp(t, 0.0, 1.0);
    const int N = 6;
    float ts[N]   = { 0.0, 0.25, 0.5, 0.7, 0.85, 1.0 };
    float3 cs[N]  = { float3(0.10,0.12,0.48), float3(0.10,0.55,0.85), float3(0.12,0.80,0.42),
                      float3(0.95,0.90,0.20), float3(1.00,0.55,0.10), float3(1.00,0.22,0.16) };
    float3 c = cs[N-1];
    for (int i = 1; i < N; i++) {
        if (t <= ts[i]) {
            float f = (t - ts[i-1]) / max(1e-5, ts[i] - ts[i-1]);
            c = mix(cs[i-1], cs[i], f);
            break;
        }
    }
    return c;
}

// Full-wheel HSV (hue in [0,1]) for per-pendulum and angle coloring.
static float3 hsv(float h, float s, float v) {
    float3 p = abs(fract(h + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

vertex VOut line_vertex(uint vid [[vertex_id]],
                        device const TrailVertex* verts [[buffer(0)]],
                        constant Uniforms& u [[buffer(1)]]) {
    TrailVertex v = verts[vid];
    float speed = float(v.attribs & 0xFF) / 255.0;
    float hue   = float((v.attribs >> 8)  & 0xFF) / 255.0;
    float angle = float((v.attribs >> 16) & 0xFF) / 255.0;
    float alpha = float((v.attribs >> 24) & 0xFF) / 255.0;

    int mode = int(u.modeParams.x + 0.5);
    float3 rgb;
    if (mode == 0) {            // speed → energy distribution
        rgb = coolHot(speed);
    } else if (mode == 1) {     // identity → per-pendulum hue (divergence/mixing)
        rgb = hsv(hue, 0.85, 1.0);
    } else {                    // phase → swing angle
        rgb = hsv(angle, 0.85, 1.0);
    }

    VOut out;
    out.position = u.mvp * float4(v.position, 1.0);
    out.color = float4(rgb, alpha);
    return out;
}

fragment float4 line_fragment(VOut in [[stage_in]]) {
    // Premultiplied additive blend (set in the pipeline) → overlapping segments accumulate in an
    // HDR (rgba16Float) target, so the dense core no longer clips to white.
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// --- Tone-mapping pass: HDR accumulation → display, compressing the huge dynamic range so both
//     the dense core and the faint edges show, with hue preserved (luminance-based Reinhard).

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0),(2,0),(0,2) — fullscreen triangle
    FSOut o;
    o.uv = p;
    o.position = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

fragment float4 tonemap_fragment(FSOut in [[stage_in]],
                                 texture2d<float> hdr [[texture(0)]],
                                 constant float2& params [[buffer(0)]]) {
    float exposure = params.x;
    float saturation = params.y;
    constexpr sampler smp(filter::nearest);
    float3 c = hdr.sample(smp, in.uv).rgb * exposure;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float mapped = lum / (1.0 + lum);                       // Reinhard on luminance
    float3 rgb = (lum > 1e-4) ? c * (mapped / lum) : float3(0.0);
    // Dense additive overlap of many hues desaturates toward white; pull saturation back up.
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = max(float3(0.0), mix(float3(l), rgb, saturation));
    rgb = pow(rgb, float3(1.0 / 2.2));                      // gamma for display
    return float4(rgb, 1.0);
}
"""
