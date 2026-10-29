import Foundation
import Testing
@testable import FlightFeed
@testable import MockFlightServer

@Suite struct WireFormatTests {
    @Test func varintAndZigzagRoundTrip() throws {
        var w = WireWriter()
        let unsigned: [UInt64] = [0, 1, 127, 128, 300, UInt64(UInt32.max), .max]
        let signed: [Int64] = [0, -1, 1, -64, 64, Int64(Int32.min), .max, .min]
        unsigned.forEach { w.varint($0) }
        signed.forEach { w.zigzag($0) }

        var r = WireReader(Data(w.bytes))
        for v in unsigned { #expect(try r.varint() == v) }
        for v in signed { #expect(try r.zigzag() == v) }
        #expect(r.isAtEnd)
    }

    @Test func truncatedInputThrows() {
        var r = WireReader(Data([0x80, 0x80]))
        #expect(throws: WireError.truncated) { try r.varint() }
    }
}

@Suite struct FeedCodecTests {
    static func sampleBatch() -> FeedBatch {
        var positions = PositionColumns()
        positions.append(PositionReport(id: 7, latitude: 59.65, longitude: 17.93, altitudeFt: 35000,
                                        groundSpeedKt: 452, trackDeg: 231.4, verticalRateFpm: -1200, ageMs: 340))
        positions.append(PositionReport(id: 3, latitude: -33.94, longitude: -179.99, altitudeFt: 0,
                                        groundSpeedKt: 0, trackDeg: 0, verticalRateFpm: 0, ageMs: 0))
        return FeedBatch(
            serverTimeMs: 1_761_744_000_000,
            isSnapshot: true,
            added: [FlightInfo(id: 7, callsign: "SAS123", aircraftType: "A20N", origin: "ARN", destination: "LHR")],
            removed: [42, 9, 100_000],
            positions: positions
        )
    }

    @Test func roundTrip() throws {
        let batch = Self.sampleBatch()
        #expect(try FeedCodec.decode(FeedCodec.encode(batch)) == batch)
    }

    @Test func rejectsUnknownVersion() {
        var data = FeedCodec.encode(Self.sampleBatch())
        data[0] = 99
        #expect(throws: WireError.unsupportedVersion(99)) { try FeedCodec.decode(data) }
    }

    @Test func fiftyThousandRecordsStayCompact() throws {
        var positions = PositionColumns()
        for i in 0..<50_000 {
            positions.append(PositionReport(id: UInt32(i + 1), latitude: 50 + Double(i % 100) * 0.1,
                                            longitude: 10 + Double(i % 77) * 0.1, altitudeFt: 36000,
                                            groundSpeedKt: 450, trackDeg: Double(i % 360),
                                            verticalRateFpm: 0, ageMs: 500))
        }
        let data = FeedCodec.encode(FeedBatch(serverTimeMs: 0, positions: positions))
        // Fixed-width packing of the same fields is 24 bytes per record.
        #expect(data.count < 50_000 * 20)
        #expect(try FeedCodec.decode(data).positions == positions)
    }
}

@Suite struct EngineTests {
    @Test func instanceLayoutMatchesShader() {
        #expect(MemoryLayout<AircraftInstance>.stride == 32)
        #expect(MemoryLayout<AircraftInstance>.offset(of: \.heading) == 16)
        #expect(MemoryLayout<AircraftInstance>.offset(of: \.id) == 28)
    }

    @Test func mercatorMatchesKnownPoints() {
        let origin = WebMercator.project(latitude: 0, longitude: 0)
        #expect(abs(origin.x - 0.5) < 1e-12 && abs(origin.y - 0.5) < 1e-12)
        let back = WebMercator.unproject(WebMercator.project(latitude: 59.65, longitude: 17.93))
        #expect(abs(back.latitude - 59.65) < 1e-9 && abs(back.longitude - 17.93) < 1e-9)
    }

    @Test func applyAddsUpdatesAndSwapRemoves() async throws {
        let engine = LiveTrafficEngine(transport: NoTransport())
        var positions = PositionColumns()
        for id: UInt32 in [1, 2, 3] {
            positions.append(PositionReport(id: id, latitude: 10, longitude: Double(id), altitudeFt: 1000,
                                            groundSpeedKt: 300, trackDeg: 90, verticalRateFpm: 0, ageMs: 0))
        }
        await engine.apply(FeedBatch(serverTimeMs: 0, isSnapshot: true, positions: positions), receivedAt: 0)
        #expect(await engine.currentStats().aircraft == 3)

        await engine.apply(FeedBatch(serverTimeMs: 0, removed: [1]), receivedAt: 1)
        #expect(await engine.currentStats().aircraft == 2)
        #expect(await engine.detail(for: 1) == nil)
        // ID 3 was swapped into slot 0; it must still be addressable.
        #expect(await engine.detail(for: 3)?.report.longitude == 3)

        await engine.apply(FeedBatch(serverTimeMs: 0, isSnapshot: true), receivedAt: 2)
        #expect(await engine.currentStats().aircraft == 0)
    }

    @Test func eastboundVelocityPointsEast() {
        let v = WebMercator.velocity(latitude: 0, groundSpeedKt: 450, trackDeg: 90)
        #expect(v.x > 0 && abs(v.y) < 1e-15)
        let north = WebMercator.velocity(latitude: 0, groundSpeedKt: 450, trackDeg: 0)
        #expect(north.y < 0) // Mercator y grows southwards.
    }
}

@Suite struct MockServerTests {
    @Test func simulatorIsDeterministicAndKeepsCount() {
        var a = FlightSimulator(flightCount: 500, timeScale: 1, reportInterval: 1...3, seed: 1, now: 0)
        let b = FlightSimulator(flightCount: 500, timeScale: 1, reportInterval: 1...3, seed: 1, now: 0)
        #expect(a.flights.map(\.info) == b.flights.map(\.info))
        _ = a.step(wallNow: 10_000) // far enough that some flights land and respawn
        #expect(a.flights.count == 500)
    }

    @Test func snapshotRespectsViewportAndResyncDiffs() async throws {
        let server = MockFlightServer(configuration: .init(flightCount: 2_000, tickInterval: .seconds(3600)))
        let transport = MockFeedTransport(server: server)
        let europe = Viewport(minLat: 35, maxLat: 70, minLon: -10, maxLon: 30)
        let connection = await transport.openLiveFeed(SubscribeRequest(viewport: europe))
        var frames = connection.frames.makeAsyncIterator()

        let snapshot = try FeedCodec.decode(try #require(try await frames.next()))
        #expect(snapshot.isSnapshot)
        #expect(snapshot.positions.count > 0 && snapshot.positions.count < 2_000)
        for i in 0..<snapshot.positions.count {
            let r = snapshot.positions[i]
            #expect(europe.contains(latitude: r.latitude, longitude: r.longitude))
        }

        await connection.send(SubscribeRequest(viewport: nil))
        let delta = try FeedCodec.decode(try #require(try await frames.next()))
        #expect(!delta.isSnapshot)
        #expect(delta.removed.isEmpty)
        #expect(snapshot.positions.count + delta.added.count == 2_000)
        await connection.close()
    }

    /// Two clients watch the same sky for 5 min (10x sim speed); one gets every
    /// report, the other only reports its own prediction can't absorb.
    @Test(arguments: [4.0, 8.0, 12.0])
    func errorThresholdForwardsFewerReports(zoom: Double) async throws {
        let server = MockFlightServer(configuration: .init(flightCount: 2_000, timeScale: 10,
                                                           tickInterval: .seconds(3600)))
        let transport = MockFeedTransport(server: server)
        let everyReport = await transport.openLiveFeed(SubscribeRequest())
        let adaptive = await transport.openLiveFeed(SubscribeRequest(zoom: zoom, errorThresholdPoints: 2))

        let start = FeedClock.now()
        for step in 1...1500 {
            await server.tick(at: start + Double(step) * 0.2)
        }
        await everyReport.close()
        await adaptive.close()

        func deltaRecords(_ c: FeedConnection) async throws -> Int {
            var total = 0
            for try await frame in c.frames {
                let batch = try FeedCodec.decode(frame)
                if !batch.isSnapshot { total += batch.positions.count }
            }
            return total
        }
        let fixed = try await deltaRecords(everyReport)
        let filtered = try await deltaRecords(adaptive)
        print("records/s, 2k aircraft, zoom \(zoom), 5 min: every report \(fixed / 300), error threshold \(filtered / 300)")
        #expect(fixed > 0)
        #expect(filtered < fixed)
        if zoom <= 4 { #expect(filtered * 3 < fixed) }

        // The client must still hear from every flight at least every `maxSilence`.
        #expect(filtered >= 2_000 * 300 / 45)
    }
}

private struct NoTransport: FeedTransport {
    func openLiveFeed(_ request: SubscribeRequest) async -> FeedConnection {
        FeedConnection(frames: AsyncThrowingStream { $0.finish() }, send: { _ in }, close: {})
    }
}
