#include <metal_stdlib>
using namespace metal;

struct CubismUniforms {
    float4 canvas;
    float4 multiplyColor;
    float4 screenColor;
    float4 options;
    float4 maskTransform;
};
struct CubismRaster {
    float4 position [[position]];
    float2 uv;
    float2 maskUV;
};
vertex CubismRaster astray_cubism_vertex(uint index [[vertex_id]],
                                       const device float2 *positions [[buffer(0)]],
                                       const device float2 *coordinates [[buffer(1)]],
                                       constant CubismUniforms &u [[buffer(2)]]) {
    float2 clip = positions[index] * u.canvas.xy + u.canvas.zw;
    return {float4(clip, 0, 1), float2(coordinates[index].x, 1 - coordinates[index].y), float2(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5)};
}
fragment float4 astray_cubism_fragment(CubismRaster in [[stage_in]],
                                     constant CubismUniforms &u [[buffer(2)]],
                                     texture2d<float> source [[texture(0)]],
                                     texture2d<float> mask [[texture(1)]]) {
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    constexpr sampler maskSampling(filter::linear, address::clamp_to_zero);
    float4 color = source.sample(sampling, in.uv);
    color.rgb *= u.multiplyColor.rgb;
    color.rgb += u.screenColor.rgb * color.a - color.rgb * u.screenColor.rgb;
    float coverage = u.options.y > 0.5 ? mask.sample(maskSampling, in.maskUV * u.maskTransform.xy + u.maskTransform.zw).r : 1;
    if (u.options.z > 0.5) { coverage = 1 - coverage; }
    return color * u.options.x * coverage;
}
fragment float4 astray_cubism_mask(CubismRaster in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    return float4(source.sample(sampling, in.uv).a);
}
