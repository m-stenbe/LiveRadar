import Foundation

/// Encodes `FeedBatch` frames.
///
/// Layout (all integers varint, signed ones zigzag):
///
///     version u8 | flags u8 | serverTimeMs
///     addedCount  { id, callsign, type, origin, destination }*
///     removedCount  delta(id)*
///     n  delta(id)*n  lat*n  lon*n  alt*n  speed*n  track*n  vrate*n  age*n
///
/// IDs are delta-coded against the previous ID in the same column, so a
/// server that sorts by ID pays ~1 byte per ID instead of 3–4.
public enum FeedCodec {
    static let version: UInt8 = 1

    public static func encode(_ batch: FeedBatch) -> Data {
        let p = batch.positions
        var w = WireWriter(capacity: 16 + batch.added.count * 24 + batch.removed.count * 2 + p.count * 16)
        w.byte(version)
        w.byte(batch.isSnapshot ? 1 : 0)
        w.varint(batch.serverTimeMs)

        w.varint(UInt64(batch.added.count))
        for info in batch.added {
            w.varint(UInt64(info.id))
            w.string(info.callsign)
            w.string(info.aircraftType)
            w.string(info.origin)
            w.string(info.destination)
        }

        w.varint(UInt64(batch.removed.count))
        writeDeltaIDs(batch.removed, into: &w)

        w.varint(UInt64(p.count))
        writeDeltaIDs(p.ids, into: &w)
        for v in p.latE5 { w.zigzag(Int64(v)) }
        for v in p.lonE5 { w.zigzag(Int64(v)) }
        for v in p.altitudeFt { w.zigzag(Int64(v)) }
        for v in p.groundSpeedKt { w.varint(UInt64(v)) }
        for v in p.trackDeci { w.varint(UInt64(v)) }
        for v in p.verticalRateFpm { w.zigzag(Int64(v)) }
        for v in p.ageMs { w.varint(UInt64(v)) }

        return Data(w.bytes)
    }

    public static func decode(_ data: Data) throws -> FeedBatch {
        var r = WireReader(data)
        let v = try r.byte()
        guard v == version else { throw WireError.unsupportedVersion(v) }
        let flags = try r.byte()
        let serverTime = try r.varint()

        let addedCount = try r.count()
        var added: [FlightInfo] = []
        added.reserveCapacity(addedCount)
        for _ in 0..<addedCount {
            added.append(FlightInfo(
                id: UInt32(truncatingIfNeeded: try r.varint()),
                callsign: try r.string(),
                aircraftType: try r.string(),
                origin: try r.string(),
                destination: try r.string()
            ))
        }

        let removed = try readDeltaIDs(count: try r.count(), from: &r)

        let n = try r.count()
        var p = PositionColumns()
        p.reserveCapacity(n)
        p.ids = try readDeltaIDs(count: n, from: &r)
        for _ in 0..<n { p.latE5.append(Int32(truncatingIfNeeded: try r.zigzag())) }
        for _ in 0..<n { p.lonE5.append(Int32(truncatingIfNeeded: try r.zigzag())) }
        for _ in 0..<n { p.altitudeFt.append(Int32(truncatingIfNeeded: try r.zigzag())) }
        for _ in 0..<n { p.groundSpeedKt.append(UInt16(truncatingIfNeeded: try r.varint())) }
        for _ in 0..<n { p.trackDeci.append(UInt16(truncatingIfNeeded: try r.varint())) }
        for _ in 0..<n { p.verticalRateFpm.append(Int16(truncatingIfNeeded: try r.zigzag())) }
        for _ in 0..<n { p.ageMs.append(UInt16(truncatingIfNeeded: try r.varint())) }

        return FeedBatch(serverTimeMs: serverTime, isSnapshot: flags & 1 != 0,
                         added: added, removed: removed, positions: p)
    }

    private static func writeDeltaIDs(_ ids: [UInt32], into w: inout WireWriter) {
        var previous: Int64 = 0
        for id in ids {
            w.zigzag(Int64(id) - previous)
            previous = Int64(id)
        }
    }

    private static func readDeltaIDs(count: Int, from r: inout WireReader) throws -> [UInt32] {
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        var previous: Int64 = 0
        for _ in 0..<count {
            previous += try r.zigzag()
            ids.append(UInt32(truncatingIfNeeded: previous))
        }
        return ids
    }
}
