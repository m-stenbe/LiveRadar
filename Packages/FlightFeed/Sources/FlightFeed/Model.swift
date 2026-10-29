import Foundation

/// Static, rarely changing data about a flight. Sent once when the flight
/// enters a subscription, never repeated in position updates.
public struct FlightInfo: Sendable, Hashable {
    public var id: UInt32
    public var callsign: String
    public var aircraftType: String
    public var origin: String
    public var destination: String

    public init(id: UInt32, callsign: String, aircraftType: String, origin: String, destination: String) {
        self.id = id
        self.callsign = callsign
        self.aircraftType = aircraftType
        self.origin = origin
        self.destination = destination
    }
}

/// Position reports in columnar form ("struct of arrays").
///
/// Columns compress far better than an array of per-aircraft messages: each
/// column holds values of similar magnitude, so varint/delta encoding wins,
/// and decoding is a tight loop per column instead of per-object parsing.
public struct PositionColumns: Sendable, Equatable {
    public var ids: [UInt32] = []
    /// Latitude/longitude in 1e-5 degrees (~1.1 m resolution).
    public var latE5: [Int32] = []
    public var lonE5: [Int32] = []
    public var altitudeFt: [Int32] = []
    public var groundSpeedKt: [UInt16] = []
    /// Track over ground in tenths of a degree, clockwise from true north.
    public var trackDeci: [UInt16] = []
    public var verticalRateFpm: [Int16] = []
    /// How old the report was when the frame was sent.
    public var ageMs: [UInt16] = []

    public init() {}

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public mutating func reserveCapacity(_ n: Int) {
        ids.reserveCapacity(n)
        latE5.reserveCapacity(n)
        lonE5.reserveCapacity(n)
        altitudeFt.reserveCapacity(n)
        groundSpeedKt.reserveCapacity(n)
        trackDeci.reserveCapacity(n)
        verticalRateFpm.reserveCapacity(n)
        ageMs.reserveCapacity(n)
    }

    public mutating func append(_ r: PositionReport) {
        ids.append(r.id)
        latE5.append(Int32((r.latitude * 1e5).rounded()))
        lonE5.append(Int32((r.longitude * 1e5).rounded()))
        altitudeFt.append(Int32(r.altitudeFt.rounded()))
        groundSpeedKt.append(UInt16(clamping: Int(r.groundSpeedKt.rounded())))
        trackDeci.append(UInt16(clamping: Int((r.trackDeg * 10).rounded()) % 3600))
        verticalRateFpm.append(Int16(clamping: Int(r.verticalRateFpm.rounded())))
        ageMs.append(UInt16(clamping: r.ageMs))
    }

    public subscript(i: Int) -> PositionReport {
        PositionReport(
            id: ids[i],
            latitude: Double(latE5[i]) / 1e5,
            longitude: Double(lonE5[i]) / 1e5,
            altitudeFt: Double(altitudeFt[i]),
            groundSpeedKt: Double(groundSpeedKt[i]),
            trackDeg: Double(trackDeci[i]) / 10,
            verticalRateFpm: Double(verticalRateFpm[i]),
            ageMs: Int(ageMs[i])
        )
    }
}

/// One decoded position report (row view over `PositionColumns`).
public struct PositionReport: Sendable, Equatable {
    public var id: UInt32
    public var latitude: Double
    public var longitude: Double
    public var altitudeFt: Double
    public var groundSpeedKt: Double
    public var trackDeg: Double
    public var verticalRateFpm: Double
    public var ageMs: Int

    public init(id: UInt32, latitude: Double, longitude: Double, altitudeFt: Double,
                groundSpeedKt: Double, trackDeg: Double, verticalRateFpm: Double, ageMs: Int) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.trackDeg = trackDeg
        self.verticalRateFpm = verticalRateFpm
        self.ageMs = ageMs
    }
}

/// Geographic bounding box. `minLon > maxLon` means the box crosses the antimeridian.
public struct Viewport: Sendable, Equatable {
    public var minLat: Double
    public var maxLat: Double
    public var minLon: Double
    public var maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= minLat, latitude <= maxLat else { return false }
        if minLon <= maxLon {
            return longitude >= minLon && longitude <= maxLon
        }
        return longitude >= minLon || longitude <= maxLon
    }
}

/// What the client asks the server for. Sent when the stream opens and again
/// whenever it changes (e.g. the user pans), mirroring a bidirectional RPC.
public struct SubscribeRequest: Sendable, Equatable {
    /// `nil` = the whole world.
    public var viewport: Viewport?
    /// Web map zoom level the client is showing (world = 256 * 2^zoom points).
    public var zoom: Double?
    /// When set (with `zoom`), the server only forwards a report once the
    /// client's own dead-reckoned position would be off by more than this
    /// many screen points. `nil` = forward every report.
    public var errorThresholdPoints: Double?

    public init(viewport: Viewport? = nil, zoom: Double? = nil, errorThresholdPoints: Double? = nil) {
        self.viewport = viewport
        self.zoom = zoom
        self.errorThresholdPoints = errorThresholdPoints
    }
}

/// One frame on the stream. The first frame of a stream is a snapshot;
/// every later frame is a delta against what the client already has.
public struct FeedBatch: Sendable, Equatable {
    public var serverTimeMs: UInt64
    public var isSnapshot: Bool
    public var added: [FlightInfo]
    public var removed: [UInt32]
    public var positions: PositionColumns

    public init(serverTimeMs: UInt64, isSnapshot: Bool = false, added: [FlightInfo] = [],
                removed: [UInt32] = [], positions: PositionColumns = PositionColumns()) {
        self.serverTimeMs = serverTimeMs
        self.isSnapshot = isSnapshot
        self.added = added
        self.removed = removed
        self.positions = positions
    }

    public var isEmpty: Bool {
        !isSnapshot && added.isEmpty && removed.isEmpty && positions.isEmpty
    }
}
