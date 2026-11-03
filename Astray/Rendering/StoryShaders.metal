#include <metal_stdlib>
using namespace metal;

struct QuadUniforms {
    float4 rect;
    float4 uvRect;
    float4 color;
    float4 effects;
    float4 parameters;
};
struct RasterData {
    float4 position [[position]];
    float2 uv;
};
vertex RasterData astray_vertex(uint id [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    constexpr float2 corners[] = { {0,0}, {0,1}, {1,0}, {1,0}, {0,1}, {1,1} };
    float2 corner = corners[id];
    float2 point = u.rect.xy + corner * u.rect.zw;
    return {float4(point.x * 2 - 1, 1 - point.y * 2, 0, 1), u.uvRect.xy + corner * u.uvRect.zw};
}
float backgroundWeight(int index) {
    return index == 0 || index == 6 ? 0.036 : index == 1 || index == 5 ? 0.113 : index == 2 || index == 4 ? 0.216 : 0.269;
}
fragment float4 astray_fragment(RasterData in [[stage_in]],
                               constant QuadUniforms &u [[buffer(0)]],
                               texture2d<float> texture [[texture(0)]],
                               texture2d<float> noise [[texture(1)]]) {
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    constexpr sampler repeating(filter::linear, address::repeat);
    float4 value;
    int mode = int(u.effects.x + 0.5);
    if (mode == 4) {
        float2 d = in.uv - 0.5;
        float2 uv = clamp(d * (u.effects.z * dot(d, d) + 1) + 0.5, 0.0, 1.0);
        value = float4(0);
        if (u.effects.y <= 0.001) { value = texture.sample(sampling, uv); }
        else {
            float2 texel = u.effects.y / float2(texture.get_width(), texture.get_height());
            for (int i = 0; i < 7; ++i) {
                value += texture.sample(sampling, clamp(uv + float2((i - 3) * texel.x, 0), 0.0, 1.0)) * backgroundWeight(i) * 0.5;
                value += texture.sample(sampling, clamp(uv + float2(0, (i - 3) * texel.y), 0.0, 1.0)) * backgroundWeight(i) * 0.5;
            }
        }
    } else { value = texture.sample(sampling, in.uv); }
    value.rgb *= u.color.rgb;
    if (mode == 1 || mode == 2) {
        float3 mono = mode == 1 ? float3(0.5) : float3(0.298912, 0.586611, 0.114478);
        float3 tone = mode == 1 ? float3(0.5) : float3(1.07, 0.74, 0.43);
        value.rgb = mix(value.rgb, dot(value.rgb, mono) * tone, mode == 1 ? 0.5 : 0.75);
    } else if (mode == 3) {
        float3 straight = value.a > 0 ? value.rgb / value.a : float3(0);
        float gray = dot(straight, float3(0.2, 0.45, 0.35)) * value.a;
        float3 rgb = gray * float3(0.9, 1.2, 1.15) * 0.6 + straight * 0.4;
        float2 uv = float2((in.uv.x - 0.5) * u.parameters.x + u.parameters.z * 0.5, (0.5 - in.uv.y) * u.parameters.y + 0.5) * 0.25 + float2(0, u.effects.z * 0.005);
        float n = noise.sample(repeating, uv).r;
        rgb += u.effects.y >= n ? n * 0.07 : 0;
        value.a *= u.effects.w;
        value.rgb = rgb * value.a;
    } else if (mode == 6) {
        float feather = min(min(in.uv.x * 4, (1 - in.uv.x) * 4), 1.0);
        value *= max(0.0, feather);
    } else if (mode == 7) {
        value = texture.sample(repeating, in.uv) * float4(u.color.rgb, 1);
    } else if (mode == 8) {
        float2 p = (in.uv - 0.5) * float2(u.parameters.x, 1);
        float radius = u.parameters.y > 0 ? u.parameters.y : 0.5;
        float2 q = abs(p) - float2(u.parameters.x * 0.5 - radius, 0.5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        value *= 1 - smoothstep(-fwidth(distance), fwidth(distance), distance);
    } else if (mode == 9) {
        constexpr float stops[] = {0.7111, 0.7293, 0.7475, 0.7654, 0.7836, 0.8018, 0.82, 0.8382};
        constexpr float alpha[] = {0, 0.059, 0.141, 0.235, 0.329, 0.416, 0.482, 0.502};
        float a = in.uv.y <= stops[0] ? 0 : 0.502;
        for (int i = 1; i < 8; ++i) {
            if (in.uv.y > stops[i - 1] && in.uv.y <= stops[i]) { a = mix(alpha[i - 1], alpha[i], (in.uv.y - stops[i - 1]) / (stops[i] - stops[i - 1])); }
        }
        value *= a;
    } else if (mode == 10) {
        value *= u.parameters.x > 0 ? in.uv.x : 1 - in.uv.x;
    } else if (mode == 11) {
        value *= u.parameters.x > 0 ? in.uv.y : 1 - in.uv.y;
    }
    if (mode == 12) {
        float edge = 1 - abs(in.uv.y * 2 - 1) - in.uv.x;
        value *= smoothstep(-fwidth(edge), fwidth(edge), edge);
    }
    if (mode == 13) {
        float2 point = float2(in.uv.x * u.parameters.x - 0.5, in.uv.y - 0.5);
        float distance = length(float2(min(point.x, 0.0), point.y)) - 0.5;
        value *= (1 - in.uv.x) * (1 - smoothstep(-fwidth(distance), fwidth(distance), distance));
    }
    return value * u.color.a;
}
fragment float4 astray_blur_fragment(RasterData in [[stage_in]],
                                    constant QuadUniforms &u [[buffer(0)]],
                                    texture2d<float> texture [[texture(0)]]) {
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    float2 offset = u.parameters.xy * u.effects.y / float2(texture.get_width(), texture.get_height());
    if (u.effects.w > 0.5) {
        return texture.sample(sampling, in.uv) * 0.250301
            + (texture.sample(sampling, in.uv + offset) + texture.sample(sampling, in.uv - offset)) * 0.221461
            + (texture.sample(sampling, in.uv + offset * 2) + texture.sample(sampling, in.uv - offset * 2)) * 0.153388;
    }
    return texture.sample(sampling, in.uv) * 0.4026
        + (texture.sample(sampling, clamp(in.uv + offset, 0.0, 1.0)) + texture.sample(sampling, clamp(in.uv - offset, 0.0, 1.0))) * 0.2442
        + (texture.sample(sampling, clamp(in.uv + offset * 2, 0.0, 1.0)) + texture.sample(sampling, clamp(in.uv - offset * 2, 0.0, 1.0))) * 0.0545;
}
struct EffectVertex {
    float2 position;
    float2 uv;
    float4 color;
    float keep;
};
struct EffectRaster {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float keep;
};
vertex EffectRaster astray_effect_vertex(uint id [[vertex_id]],
                                        const device EffectVertex *vertices [[buffer(0)]],
                                        constant float4 &transform [[buffer(1)]],
                                        constant float4 &st [[buffer(2)]]) {
    EffectVertex value = vertices[id];
    float2 position = (value.position / float2(1280, 720) - 0.5) * transform.z + 0.5 + transform.xy;
    return {float4(position.x * 2 - 1, 1 - position.y * 2, 0, 1), value.uv * st.xy + st.zw, value.color, value.keep};
}
fragment float4 astray_effect_fragment(EffectRaster in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler sampling(filter::linear, address::repeat);
    float4 value = source.sample(sampling, in.uv);
    float alpha = value.a * in.color.a;
    return float4(value.rgb * in.color.rgb * in.color.a, alpha * in.keep);
}
