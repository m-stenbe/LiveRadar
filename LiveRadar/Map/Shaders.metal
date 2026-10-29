#include <metal_stdlib>
using namespace metal;

// Must match AircraftInstance in FlightFeed/Engine/RenderFeed.swift (32 bytes).
struct AircraftInstance {
    float2 position;   // normalized Web Mercator
    float2 velocity;   // mercator units / second
    float heading;     // radians clockwise from north
    float timestamp;   // FeedClock seconds
    float altitudeFt;
    uint id;
};

// Must match Uniforms in AircraftRenderer.swift (40 bytes).
struct Uniforms {
    float2 center;     // mercator point at the middle of the view
    float2 scale;      // mercator units -> clip space
    float2 iconSize;   // half icon size in clip space
    float now;
    uint selectedID;
    uint selectedOnly;
    uint padding;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

constant float2 corners[6] = { {-1, -1}, {1, -1}, {-1, 1}, {-1, 1}, {1, -1}, {1, 1} };

static float4 altitudeColor(float ft) {
    // Ground/low: teal -> mid: yellow -> cruise: orange/pink.
    float t = saturate(ft / 40000.0);
    float3 low = float3(0.25, 0.85, 0.75);
    float3 mid = float3(1.0, 0.85, 0.25);
    float3 high = float3(1.0, 0.45, 0.55);
    float3 c = t < 0.5 ? mix(low, mid, t * 2.0) : mix(mid, high, (t - 0.5) * 2.0);
    return float4(c, 1.0);
}

vertex VertexOut aircraftVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device AircraftInstance *instances [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
    AircraftInstance a = instances[iid];
    VertexOut out;
    bool selected = a.id == u.selectedID;
    if (u.selectedOnly != 0 && !selected) {
        out.position = float4(2, 2, 2, 1); // outside clip space: culled
        return out;
    }

    // Dead reckoning: the network delivers ~1 report/s per aircraft, the GPU
    // moves every aircraft every frame. Capped so stale aircraft don't fly off.
    float dt = clamp(u.now - a.timestamp, 0.0, 60.0);
    float2 d = a.position + a.velocity * dt - u.center;
    d.x -= rint(d.x); // shortest way around the antimeridian

    float2 corner = corners[vid];
    float s = sin(a.heading), c = cos(a.heading);
    float2 rotated = float2(corner.x * c + corner.y * s, -corner.x * s + corner.y * c);
    float size = selected ? 1.6 : 1.0;

    out.position = float4(d * u.scale + rotated * u.iconSize * size, 0, 1);
    out.uv = corner * float2(0.5, -0.5) + 0.5;
    out.color = selected ? float4(1.0, 0.25, 0.3, 1.0) : altitudeColor(a.altitudeFt);
    return out;
}

fragment float4 aircraftFragment(VertexOut in [[stage_in]],
                                 texture2d<float> icon [[texture(0)]],
                                 sampler iconSampler [[sampler(0)]]) {
    float4 t = icon.sample(iconSampler, in.uv);
    // Icon is premultiplied: white fill gets tinted, black outline stays black.
    return float4(t.rgb * in.color.rgb, t.a);
}
