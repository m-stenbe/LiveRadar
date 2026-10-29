import Foundation
import os

/// One aircraft as the GPU sees it. Layout must match `AircraftInstance` in
/// Shaders.metal (32 bytes, checked by a unit test).
public struct AircraftInstance: Sendable, Equatable {
    /// Normalized Web Mercator, x and y in [0, 1], y growing southwards.
    public var position: SIMD2<Float>
    /// Mercator units per second, used by the vertex shader to dead-reckon
    /// between reports so motion stays smooth at display rate.
    public var velocity: SIMD2<Float>
    /// Radians clockwise from north.
    public var heading: Float
    /// `FeedClock` seconds at which `position` was valid.
    public var timestamp: Float
    public var altitudeFt: Float
    public var id: UInt32
}

/// Lock-protected hand-off from the ingest engine to the render loop.
///
/// The engine publishes an immutable copy after each frame (a few times per
/// second); the renderer reads the latest one each display frame and uploads
/// it only if `version` changed. Neither side ever waits on the other.
public final class RenderFeed: Sendable {
    public struct Snapshot: Sendable {
        public var version: UInt64
        public var instances: ContiguousArray<AircraftInstance>

        public static let empty = Snapshot(version: 0, instances: [])
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot.empty)

    public init() {}

    public func latest() -> Snapshot {
        state.withLock { $0 }
    }

    func publish(_ instances: ContiguousArray<AircraftInstance>) {
        state.withLock { s in
            s = Snapshot(version: s.version &+ 1, instances: instances)
        }
    }
}

public enum WebMercator {
    public static let maxLatitude = 85.05112878
    static let earthRadius = 6_378_137.0

    /// Normalized coordinates, identical to `MKMapPoint / MKMapSize.world`.
    public static func project(latitude: Double, longitude: Double) -> SIMD2<Double> {
        let lat = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        let x = (longitude + 180) / 360
        let y = (1 - log(tan(.pi / 4 + lat / 2)) / .pi) / 2
        return SIMD2(x, y)
    }

    public static func unproject(_ p: SIMD2<Double>) -> (latitude: Double, longitude: Double) {
        let lon = p.x * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * p.y))) * 180 / .pi
        return (lat, lon)
    }

    /// Velocity in normalized Mercator units per second for a given ground
    /// speed and track at a latitude. Mercator stretches both axes by sec(lat).
    public static func velocity(latitude: Double, groundSpeedKt: Double, trackDeg: Double) -> SIMD2<Double> {
        let mps = groundSpeedKt * 0.514444
        let track = trackDeg * .pi / 180
        let lat = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        let unitsPerMeter = 1 / (2 * .pi * earthRadius * cos(lat))
        return SIMD2(mps * sin(track) * unitsPerMeter, -mps * cos(track) * unitsPerMeter)
    }
}
