import Foundation

enum GraphShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct NodeVertex {
        float3 position;
        float size;
        float4 color;
    };

    struct LineVertex {
        float3 position;
        float4 color;
    };

    struct Uniforms {
        float4x4 viewProjection;
        float2 viewport;
        float pointScale;
        float _pad;
    };

    struct NodeOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
    };

    struct LineOut {
        float4 position [[position]];
        float4 color;
    };

    vertex NodeOut node_vertex(const device NodeVertex *nodes [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]],
                               uint vid [[vertex_id]]) {
        NodeVertex n = nodes[vid];
        NodeOut out;
        float4 clip = u.viewProjection * float4(n.position, 1.0);
        out.position = clip;
        out.color = n.color;
        float w = max(abs(clip.w), 0.001);
        out.pointSize = clamp((n.size * u.pointScale) / w * u.viewport.y * 0.045, 3.0, 48.0);
        return out;
    }

    fragment float4 node_fragment(NodeOut in [[stage_in]],
                                  float2 pc [[point_coord]]) {
        float2 d = pc * 2.0 - 1.0;
        float r2 = dot(d, d);
        if (r2 > 1.0) discard_fragment();
        float alpha = smoothstep(1.0, 0.55, r2);
        float3 col = in.color.rgb * (0.65 + 0.35 * (1.0 - r2));
        return float4(col, in.color.a * alpha);
    }

    vertex LineOut line_vertex(const device LineVertex *verts [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]],
                               uint vid [[vertex_id]]) {
        LineVertex v = verts[vid];
        LineOut out;
        out.position = u.viewProjection * float4(v.position, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 line_fragment(LineOut in [[stage_in]]) {
        return in.color;
    }
    """
}
