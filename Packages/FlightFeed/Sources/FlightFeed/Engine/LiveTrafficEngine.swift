import Foundation

/// Latest known state of one flight, for the detail card.
public struct FlightDetail: Sendable, Equatable {
    public var info: FlightInfo?
    public var report: PositionReport
    public var receivedAt: Double
}

/// Cumulative counters; the UI derives rates by diffing two samples.
public struct FeedStats: Sendable, Equatable {
    public var aircraft = 0
    public var frames = 0
    public var bytes = 0
    public var records = 0
    public var lastFrameBytes = 0
    public var lastDecodeMs = 0.0
    public var lastApplyMs = 0.0
    public var reconnects = 0
    public var lastError: String?

    public init() {}
}

/// Consumes the live feed off the main thread and maintains the client-side
/// world state.
///
/// Storage is dense: `instances` (what the GPU draws) and `reports` (what the
/// detail card shows) are parallel arrays, with `slotByID` mapping flight IDs
/// to indices. Removal swaps the last element into the hole, so arrays never
/// have gaps and can be uploaded to the GPU with a single memcpy.
public actor LiveTrafficEngine {
    public nonisolated let renderFeed = RenderFeed()

    private let transport: any FeedTransport
    /// Mock-only knob: the simulated sky runs `timeScale` times faster than
    /// wall time, so extrapolation velocities are scaled to match.
    private let timeScale: Double

    private var instances = ContiguousArray<AircraftInstance>()
    private var reports = ContiguousArray<PositionReport>()
    private var receivedAt = ContiguousArray<Double>()
    private var slotByID: [UInt32: Int] = [:]
    private var info: [UInt32: FlightInfo] = [:]

    private var request = SubscribeRequest()
    private var connection: FeedConnection?
    private var runTask: Task<Void, Never>?
    private var stats = FeedStats()

    public init(transport: any FeedTransport, timeScale: Double = 1) {
        self.transport = transport
        self.timeScale = timeScale
    }

    public func start(_ request: SubscribeRequest) {
        runTask?.cancel()
        self.request = request
        runTask = Task { await self.run() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await connection?.close()
        connection = nil
    }

    /// Sends a new request on the open stream (e.g. the viewport moved).
    public func update(_ request: SubscribeRequest) async {
        guard request != self.request else { return }
        self.request = request
        await connection?.send(request)
    }

    public func currentStats() -> FeedStats {
        var s = stats
        s.aircraft = instances.count
        return s
    }

    public func detail(for id: UInt32) -> FlightDetail? {
        guard let slot = slotByID[id] else { return nil }
        return FlightDetail(info: info[id], report: reports[slot], receivedAt: receivedAt[slot])
    }

    // MARK: - Stream loop

    private func run() async {
        var backoff = 0.5
        while !Task.isCancelled {
            let connection = await transport.openLiveFeed(request)
            self.connection = connection
            do {
                for try await frame in connection.frames {
                    try ingest(frame)
                    backoff = 0.5
                }
            } catch {
                stats.lastError = String(describing: error)
            }
            guard !Task.isCancelled else { break }
            // Stream ended or failed: reconnect with exponential backoff. The
            // server starts every new stream with a snapshot, so no state
            // reconciliation is needed here.
            stats.reconnects += 1
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 8)
        }
    }

    func ingest(_ frame: Data) throws {
        let t0 = FeedClock.now()
        let batch = try FeedCodec.decode(frame)
        let t1 = FeedClock.now()
        apply(batch, receivedAt: t1)
        let t2 = FeedClock.now()
        renderFeed.publish(instances)

        stats.frames += 1
        stats.bytes += frame.count
        stats.records += batch.positions.count
        stats.lastFrameBytes = frame.count
        stats.lastDecodeMs = (t1 - t0) * 1000
        stats.lastApplyMs = (t2 - t1) * 1000
    }

    func apply(_ batch: FeedBatch, receivedAt now: Double) {
        if batch.isSnapshot {
            instances.removeAll(keepingCapacity: true)
            reports.removeAll(keepingCapacity: true)
            receivedAt.removeAll(keepingCapacity: true)
            slotByID.removeAll(keepingCapacity: true)
            info.removeAll(keepingCapacity: true)
        }

        for id in batch.removed {
            remove(id)
        }
        for flight in batch.added {
            info[flight.id] = flight
        }

        let positions = batch.positions
        for i in 0..<positions.count {
            let r = positions[i]
            let merc = WebMercator.project(latitude: r.latitude, longitude: r.longitude)
            let velocity = WebMercator.velocity(latitude: r.latitude, groundSpeedKt: r.groundSpeedKt,
                                                trackDeg: r.trackDeg) * timeScale
            let instance = AircraftInstance(
                position: SIMD2<Float>(merc),
                velocity: SIMD2<Float>(velocity),
                heading: Float(r.trackDeg * .pi / 180),
                timestamp: Float(now - Double(r.ageMs) / 1000),
                altitudeFt: Float(r.altitudeFt),
                id: r.id
            )
            if let slot = slotByID[r.id] {
                instances[slot] = instance
                reports[slot] = r
                receivedAt[slot] = now
            } else {
                slotByID[r.id] = instances.count
                instances.append(instance)
                reports.append(r)
                receivedAt.append(now)
            }
        }
    }

    private func remove(_ id: UInt32) {
        info[id] = nil
        guard let slot = slotByID.removeValue(forKey: id) else { return }
        let last = instances.count - 1
        if slot != last {
            instances[slot] = instances[last]
            reports[slot] = reports[last]
            receivedAt[slot] = receivedAt[last]
            slotByID[instances[slot].id] = slot
        }
        instances.removeLast()
        reports.removeLast()
        receivedAt.removeLast()
    }
}
