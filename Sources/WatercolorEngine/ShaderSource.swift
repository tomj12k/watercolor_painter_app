enum ShaderSource {
    static let watercolor = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant uint allLayers = 0xffffffffu;

    struct StampParameters {
        float4 centerRadius;
        float4 color;
        float4 brush;
        float4 effects;
        uint4 modes;
        uint4 extra;
        uint4 stampRect;
    };

    struct SimulationParameters {
        float4 rates;
        uint4 selection;
    };

    struct CompositeParameters {
        uint4 dimensions;
    };

    struct MergeParameters {
        uint2 slices;
        float2 opacities;
        uint2 visibility;
    };

    struct SmudgeParameters {
        float4 centerRadius;
        float4 directionStrength;
        uint4 extra;
        uint4 stampRect;
    };

    uint hashValue(uint value) {
        value ^= value >> 16;
        value *= 0x7feb352du;
        value ^= value >> 15;
        value *= 0x846ca68bu;
        value ^= value >> 16;
        return value;
    }

    float randomValue(uint2 position, uint seed) {
        return float(hashValue(position.x ^ (position.y * 0x9e3779b9u) ^ seed)) / 4294967295.0f;
    }

    float3 linearToSRGB(float3 color) {
        float3 low = color * 12.92f;
        float3 high = 1.055f * pow(max(color, 0.0f), float3(1.0f / 2.4f)) - 0.055f;
        return select(high, low, color <= 0.0031308f);
    }

    float paperNoise(uint2 position, uint paper, uint seed) {
        float frequency;
        float secondary;
        switch (paper) {
            case 0: frequency = 15.0f; secondary = 0.18f; break;
            case 1: frequency = 9.0f; secondary = 0.34f; break;
            case 2: frequency = 5.0f; secondary = 0.55f; break;
            case 3: frequency = 7.0f; secondary = 0.72f; break;
            default: frequency = 3.0f; secondary = 0.42f; break;
        }
        uint2 coarse = uint2(float2(position) / frequency);
        float base = randomValue(coarse, seed ^ (paper * 0x51ed270bu));
        float fiber = randomValue(uint2(position.x / 2u, position.y * (paper + 1u)), seed ^ 0xa511e9b3u);
        return mix(base, fiber, secondary);
    }

    float shapeCoverage(float2 normalized, uint shape) {
        float distance;
        switch (shape) {
            case 0:
                distance = length(normalized);
                break;
            case 1:
                distance = max(abs(normalized.x), abs(normalized.y) * 1.45f);
                break;
            case 2:
                distance = pow(
                    pow(abs(normalized.x), 2.5f) + pow(abs(normalized.y) * 1.18f, 2.5f),
                    0.4f
                );
                break;
            case 3: {
                float angle = atan2(normalized.y, normalized.x);
                float lobes = 0.72f + 0.28f * abs(sin(angle * 5.0f));
                distance = length(normalized) / lobes;
                break;
            }
            default:
                distance = max(abs(normalized.x) * 0.34f, abs(normalized.y) * 1.8f);
                break;
        }
        return clamp((1.0f - distance) / 0.28f, 0.0f, 1.0f);
    }

    float hairCoverage(float coverage, uint hair, float noise) {
        switch (hair) {
            case 0: return pow(coverage, 0.92f);
            case 1: return pow(coverage, 1.28f) * 0.92f;
            case 2: return coverage > 0.16f ? coverage * 0.88f : 0.0f;
            case 3: return coverage * mix(0.30f, 1.0f, step(0.31f, noise));
            default: return pow(coverage, 0.68f) * 0.82f;
        }
    }

    float textureCoverage(float coverage, uint texture, float paper, float detail) {
        switch (texture) {
            case 0: return coverage;
            case 1: return coverage * mix(0.48f, 1.18f, paper);
            case 2: return coverage * smoothstep(0.42f, 0.76f, detail);
            case 3: return coverage * mix(0.35f, 1.0f, 0.5f + 0.5f * sin(detail * 19.0f));
            default: return coverage * (detail < 0.24f ? 0.08f : 0.82f + 0.18f * paper);
        }
    }

    kernel void stampKernel(
        texture2d_array<half, access::read_write> pigment [[texture(0)]],
        texture2d_array<half, access::read_write> wetness [[texture(1)]],
        constant StampParameters& parameters [[buffer(0)]],
        uint2 localPosition [[thread_position_in_grid]]
    ) {
        if (localPosition.x >= parameters.stampRect.z || localPosition.y >= parameters.stampRect.w) {
            return;
        }

        uint2 position = parameters.stampRect.xy + localPosition;
        if (position.x >= pigment.get_width() || position.y >= pigment.get_height()) {
            return;
        }

        uint slice = parameters.extra.z;
        float2 normalized = (float2(position) + 0.5f - parameters.centerRadius.xy) / parameters.centerRadius.zw;
        float coverage = shapeCoverage(normalized, parameters.modes.y);
        if (coverage <= 0.0f) {
            return;
        }

        float grain = paperNoise(position, parameters.extra.y, parameters.extra.w);
        float detail = randomValue(position, parameters.extra.w ^ 0x6d2b79f5u);
        coverage = hairCoverage(coverage, parameters.modes.z, detail);
        coverage = textureCoverage(coverage, parameters.modes.w, grain, detail);
        coverage *= mix(0.86f, 1.08f, grain);
        float edgeBand = 4.0f * coverage * (1.0f - coverage);
        coverage = clamp(
            coverage + parameters.effects.y * edgeBand * 0.16f * mix(0.65f, 1.2f, grain),
            0.0f,
            1.0f
        );

        float stylePaint = 1.0f;
        float styleWater = 1.0f;
        switch (parameters.extra.x) {
            case 0: stylePaint = 0.78f; styleWater = 1.0f; break;
            case 1: stylePaint = 0.72f; styleWater = 1.28f; break;
            case 2: stylePaint = 1.18f; styleWater = 0.34f; break;
            case 3: stylePaint = 0.62f; styleWater = 0.68f; break;
            default: stylePaint = 0.88f; styleWater = 1.42f; break;
        }

        float pressure = clamp(parameters.brush.x, 0.0f, 1.0f);
        float amount = clamp(coverage * pressure * parameters.brush.y * parameters.brush.z * stylePaint, 0.0f, 1.0f);
        float waterAmount = clamp(coverage * pressure * parameters.brush.w * styleWater, 0.0f, 1.0f);
        half4 existingPigment = pigment.read(position, slice);
        half existingWetness = wetness.read(position, slice).r;

        switch (parameters.modes.x) {
            case 0: {
                float granulation = mix(1.0f, mix(0.72f, 1.2f, grain), parameters.effects.x);
                float deposited = amount * granulation;
                float alphaDeposit = deposited * clamp(parameters.color.a, 0.0f, 1.0f);
                float4 next = float4(existingPigment) + float4(parameters.color.rgb * alphaDeposit, alphaDeposit);
                pigment.write(half4(clamp(next, 0.0f, 8.0f)), position, slice);
                wetness.write(half4(min(float(existingWetness) + waterAmount, 1.0f)), position, slice);
                break;
            }
            case 1:
                wetness.write(half4(min(float(existingWetness) + max(waterAmount, coverage * pressure * 0.5f), 1.0f)), position, slice);
                break;
            case 2: {
                float remaining = 1.0f - clamp(coverage * pressure * 0.92f, 0.0f, 0.96f);
                pigment.write(existingPigment * half(remaining), position, slice);
                wetness.write(existingWetness * half(remaining), position, slice);
                break;
            }
            case 3: {
                float2 direction = parameters.effects.zw;
                if (length_squared(direction) < 0.001f) direction = float2(1.0f, 0.0f);
                direction = normalize(direction);
                float directional = dot(normalized, direction);
                float movement = 1.0f + directional * coverage * pressure * 0.34f;
                pigment.write(half4(clamp(float4(existingPigment) * movement, 0.0f, 8.0f)), position, slice);
                wetness.write(half4(min(float(existingWetness) + coverage * 0.16f, 1.0f)), position, slice);
                break;
            }
            case 4: {
                float2 direction = parameters.effects.zw;
                if (length_squared(direction) < 0.001f) direction = float2(1.0f, 0.0f);
                direction = normalize(direction);
                float directional = dot(normalized, direction);
                float movement = 1.0f + directional * coverage * pressure * 0.68f;
                pigment.write(half4(clamp(float4(existingPigment) * movement, 0.0f, 8.0f)), position, slice);
                wetness.write(half4(min(float(existingWetness) + coverage * 0.08f, 1.0f)), position, slice);
                break;
            }
            default: {
                float remaining = 1.0f - clamp(coverage * pressure * 0.84f, 0.0f, 0.95f);
                wetness.write(existingWetness * half(remaining), position, slice);
                break;
            }
        }
    }

    kernel void simulationKernel(
        texture2d_array<half, access::read> sourcePigment [[texture(0)]],
        texture2d_array<half, access::read> sourceWetness [[texture(1)]],
        texture2d_array<half, access::write> destinationPigment [[texture(2)]],
        texture2d_array<half, access::write> destinationWetness [[texture(3)]],
        constant SimulationParameters& parameters [[buffer(0)]],
        uint3 localPosition [[thread_position_in_grid]]
    ) {
        uint slice = parameters.selection.x == allLayers ? localPosition.z : parameters.selection.x;
        uint3 position = uint3(
            localPosition.x + parameters.selection.z,
            localPosition.y + parameters.selection.w,
            slice
        );
        if (position.x >= sourcePigment.get_width() || position.y >= sourcePigment.get_height() || position.z >= sourcePigment.get_array_size()) {
            return;
        }

        uint2 pixel = position.xy;
        half4 centerPigment = sourcePigment.read(pixel, slice);
        half centerWetness = sourceWetness.read(pixel, slice).r;

        uint2 left = uint2(pixel.x == 0u ? 0u : pixel.x - 1u, pixel.y);
        uint2 right = uint2(min(pixel.x + 1u, sourcePigment.get_width() - 1u), pixel.y);
        uint2 up = uint2(pixel.x, pixel.y == 0u ? 0u : pixel.y - 1u);
        uint2 down = uint2(pixel.x, min(pixel.y + 1u, sourcePigment.get_height() - 1u));

        float4 pigmentAverage = (
            float4(sourcePigment.read(left, slice)) +
            float4(sourcePigment.read(right, slice)) +
            float4(sourcePigment.read(up, slice)) +
            float4(sourcePigment.read(down, slice))
        ) * 0.25f;
        float wetnessAverage = (
            float(sourceWetness.read(left, slice).r) +
            float(sourceWetness.read(right, slice).r) +
            float(sourceWetness.read(up, slice).r) +
            float(sourceWetness.read(down, slice).r)
        ) * 0.25f;

        float fiber = paperNoise(pixel, parameters.selection.y, 0x45d9f3bu);
        float mobility = mix(0.72f, 1.16f, fiber);
        float retention = mix(0.978f, 0.993f, fiber);
        float wet = float(centerWetness);
        float nextWetness = (wet + parameters.rates.x * mobility * (wetnessAverage - wet))
            * parameters.rates.z * retention;
        float pigmentRate = parameters.rates.y * mobility * clamp(wet + wetnessAverage, 0.0f, 1.0f);
        float4 nextPigment = mix(float4(centerPigment), pigmentAverage, pigmentRate);

        destinationPigment.write(half4(clamp(nextPigment, 0.0f, 8.0f)), pixel, slice);
        destinationWetness.write(half4(clamp(nextWetness, 0.0f, 1.0f)), pixel, slice);
    }

    kernel void synchronizeRegionKernel(
        texture2d_array<half, access::read> sourcePigment [[texture(0)]],
        texture2d_array<half, access::read> sourceWetness [[texture(1)]],
        texture2d_array<half, access::write> destinationPigment [[texture(2)]],
        texture2d_array<half, access::write> destinationWetness [[texture(3)]],
        constant SimulationParameters& parameters [[buffer(0)]],
        uint3 localPosition [[thread_position_in_grid]]
    ) {
        uint slice = parameters.selection.x == allLayers ? localPosition.z : parameters.selection.x;
        uint3 position = uint3(
            localPosition.x + parameters.selection.z,
            localPosition.y + parameters.selection.w,
            slice
        );
        if (position.x >= sourcePigment.get_width() || position.y >= sourcePigment.get_height()
            || position.z >= sourcePigment.get_array_size()) return;
        destinationPigment.write(sourcePigment.read(position.xy, position.z), position.xy, position.z);
        destinationWetness.write(sourceWetness.read(position.xy, position.z), position.xy, position.z);
    }

    kernel void smudgeKernel(
        texture2d_array<half, access::read> sourcePigment [[texture(0)]],
        texture2d_array<half, access::read> sourceWetness [[texture(1)]],
        texture2d_array<half, access::write> destinationPigment [[texture(2)]],
        texture2d_array<half, access::write> destinationWetness [[texture(3)]],
        constant SmudgeParameters& parameters [[buffer(0)]],
        uint2 localPosition [[thread_position_in_grid]]
    ) {
        if (localPosition.x >= parameters.stampRect.z || localPosition.y >= parameters.stampRect.w) return;
        uint2 position = parameters.stampRect.xy + localPosition;
        if (position.x >= sourcePigment.get_width() || position.y >= sourcePigment.get_height()) return;

        uint slice = parameters.extra.x;
        float2 normalized = (float2(position) + 0.5f - parameters.centerRadius.xy) / parameters.centerRadius.zw;
        float coverage = clamp((1.0f - length(normalized)) / 0.3f, 0.0f, 1.0f);
        float strength = parameters.directionStrength.z;
        float distance = parameters.centerRadius.z * parameters.directionStrength.w * coverage;
        float2 upstream = float2(position) - parameters.directionStrength.xy * distance;
        uint2 sourcePosition = uint2(clamp(
            round(upstream),
            float2(0.0f),
            float2(sourcePigment.get_width() - 1u, sourcePigment.get_height() - 1u)
        ));
        float amount = clamp(coverage * strength, 0.0f, 0.92f);
        float4 center = float4(sourcePigment.read(position, slice));
        float4 transported = float4(sourcePigment.read(sourcePosition, slice));
        float4 nextPigment = mix(center, transported, amount);
        float centerWetness = float(sourceWetness.read(position, slice).r);
        float transportedWetness = float(sourceWetness.read(sourcePosition, slice).r);
        destinationPigment.write(half4(clamp(nextPigment, 0.0f, 8.0f)), position, slice);
        destinationWetness.write(half4(clamp(mix(centerWetness, transportedWetness, amount), 0.0f, 1.0f)), position, slice);
    }

    kernel void clearKernel(
        texture2d_array<half, access::write> pigment [[texture(0)]],
        texture2d_array<half, access::write> wetness [[texture(1)]],
        constant uint& targetSlice [[buffer(0)]],
        uint3 position [[thread_position_in_grid]]
    ) {
        if (position.x >= pigment.get_width() || position.y >= pigment.get_height() || position.z >= pigment.get_array_size()) {
            return;
        }
        if (targetSlice == allLayers || position.z == targetSlice) {
            pigment.write(half4(0.0h), position.xy, position.z);
            wetness.write(half4(0.0h), position.xy, position.z);
        }
    }

    kernel void mergeKernel(
        texture2d_array<half, access::read_write> pigment [[texture(0)]],
        texture2d_array<half, access::read_write> wetness [[texture(1)]],
        constant MergeParameters& parameters [[buffer(0)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= pigment.get_width() || position.y >= pigment.get_height()) return;
        float sourceWeight = parameters.visibility.x == 0u ? 0.0f : parameters.opacities.x;
        float destinationWeight = parameters.visibility.y == 0u ? 0.0f : parameters.opacities.y;
        float4 source = float4(pigment.read(position, parameters.slices.x)) * sourceWeight;
        float4 destination = float4(pigment.read(position, parameters.slices.y)) * destinationWeight;
        pigment.write(half4(clamp(destination + source, 0.0f, 8.0f)), position, parameters.slices.y);
        pigment.write(half4(0.0h), position, parameters.slices.x);
        float sourceWetness = float(wetness.read(position, parameters.slices.x).r) * sourceWeight;
        float destinationWetness = float(wetness.read(position, parameters.slices.y).r) * destinationWeight;
        wetness.write(half4(max(sourceWetness, destinationWetness)), position, parameters.slices.y);
        wetness.write(half4(0.0h), position, parameters.slices.x);
    }

    kernel void copyLayerKernel(
        texture2d_array<half, access::read_write> pigment [[texture(0)]],
        texture2d_array<half, access::read_write> wetness [[texture(1)]],
        constant uint2& slices [[buffer(0)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= pigment.get_width() || position.y >= pigment.get_height()) return;
        pigment.write(pigment.read(position, slices.x), position, slices.y);
        wetness.write(wetness.read(position, slices.x), position, slices.y);
    }

    kernel void wetnessTileMaximumKernel(
        texture2d_array<half, access::read> wetness [[texture(0)]],
        device uint* tileMaximums [[buffer(0)]],
        constant uint& activeSlices [[buffer(1)]],
        threadgroup uint* localMaximums [[threadgroup(0)]],
        uint3 position [[thread_position_in_grid]],
        uint localIndex [[thread_index_in_threadgroup]],
        uint3 threadsInGroup [[threads_per_threadgroup]],
        uint3 groupPosition [[threadgroup_position_in_grid]],
        uint3 groupsPerGrid [[threadgroups_per_grid]]
    ) {
        uint value = 0u;
        if (position.x < wetness.get_width() && position.y < wetness.get_height()
            && position.z < wetness.get_array_size() && (activeSlices & (1u << position.z)) != 0u) {
            value = uint(clamp(float(wetness.read(position.xy, position.z).r), 0.0f, 1.0f) * 1000000.0f);
        }
        localMaximums[localIndex] = value;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint threadCount = threadsInGroup.x * threadsInGroup.y * threadsInGroup.z;
        for (uint stride = threadCount / 2u; stride > 0u; stride /= 2u) {
            if (localIndex < stride) {
                localMaximums[localIndex] = max(localMaximums[localIndex], localMaximums[localIndex + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (localIndex == 0u) {
            uint tileIndex = (groupPosition.z * groupsPerGrid.y + groupPosition.y) * groupsPerGrid.x + groupPosition.x;
            tileMaximums[tileIndex] = localMaximums[0];
        }
    }

    kernel void wetnessFinalMaximumKernel(
        device const uint* tileMaximums [[buffer(0)]],
        device uint* maximum [[buffer(1)]],
        constant uint& tileCount [[buffer(2)]],
        threadgroup uint* localMaximums [[threadgroup(0)]],
        uint localIndex [[thread_index_in_threadgroup]],
        uint3 threadsInGroup [[threads_per_threadgroup]]
    ) {
        uint threadCount = threadsInGroup.x * threadsInGroup.y * threadsInGroup.z;
        uint value = 0u;
        for (uint index = localIndex; index < tileCount; index += threadCount) {
            value = max(value, tileMaximums[index]);
        }
        localMaximums[localIndex] = value;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = threadCount / 2u; stride > 0u; stride /= 2u) {
            if (localIndex < stride) {
                localMaximums[localIndex] = max(localMaximums[localIndex], localMaximums[localIndex + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (localIndex == 0u) {
            maximum[0] = localMaximums[0];
        }
    }

    kernel void compositeKernel(
        texture2d_array<half, access::read> pigment [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        device const float4* layers [[buffer(0)]],
        constant CompositeParameters& parameters [[buffer(1)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= output.get_width() || position.y >= output.get_height()) return;

        uint paper = parameters.dimensions.z;
        float grain = paperNoise(position, paper, 0x74a7c15du);
        float grainStrength;
        switch (paper) {
            case 0: grainStrength = 0.012f; break;
            case 1: grainStrength = 0.024f; break;
            case 2: grainStrength = 0.043f; break;
            case 3: grainStrength = 0.034f; break;
            default: grainStrength = 0.029f; break;
        }
        float paperValue = clamp(0.965f + (grain - 0.5f) * grainStrength, 0.88f, 1.0f);
        float3 color = float3(paperValue, paperValue * 0.994f, paperValue * 0.978f);

        for (uint index = 0u; index < parameters.dimensions.w; ++index) {
            float4 metadata = layers[index];
            if (metadata.z < 0.5f || metadata.y <= 0.0f) continue;
            uint slice = uint(metadata.x + 0.5f);
            float4 sample = float4(pigment.read(position, slice));
            float concentration = max(sample.a, 0.0f);
            if (concentration <= 0.0001f) continue;
            float3 pigmentColor = clamp(sample.rgb / max(concentration, 0.0001f), 0.0f, 1.0f);
            float paperDeposit = mix(0.90f, 1.08f, grain);
            float alpha = clamp((1.0f - exp(-concentration)) * metadata.y * paperDeposit, 0.0f, 1.0f);
            color = mix(color, pigmentColor, alpha);
        }

        output.write(float4(clamp(linearToSRGB(color), 0.0f, 1.0f), 1.0f), position);
    }

    struct DisplayVertex {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex DisplayVertex displayVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = {
            float2(-1.0f, -1.0f),
            float2( 3.0f, -1.0f),
            float2(-1.0f,  3.0f)
        };
        const float2 textureCoordinates[3] = {
            float2(0.0f, 1.0f),
            float2(2.0f, 1.0f),
            float2(0.0f, -1.0f)
        };
        DisplayVertex result;
        result.position = float4(positions[vertexID], 0.0f, 1.0f);
        result.textureCoordinate = textureCoordinates[vertexID];
        return result;
    }

    fragment float4 displayFragment(
        DisplayVertex input [[stage_in]],
        texture2d<float, access::sample> image [[texture(0)]],
        constant float4& paperRect [[buffer(0)]]
    ) {
        float2 paperCoordinate = (input.textureCoordinate - paperRect.xy) / paperRect.zw;
        if (any(paperCoordinate < 0.0f) || any(paperCoordinate > 1.0f)) {
            discard_fragment();
        }
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(imageSampler, paperCoordinate);
    }
    """#
}
