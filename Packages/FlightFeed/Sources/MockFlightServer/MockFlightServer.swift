import Foundation
import FlightFeed

/// In-process stand-in for the live-feed backend.
///
/// Behaves like the server side of a bidirectional streaming RPC:
/// - a new stream gets a full snapshot of everything inside its viewport,
/// - then delta frames every `tickInterval` with the reports that came due,
/// - when the client sends a new viewport, the server diffs what that client
///   already knows and sends only the flights entering/leaving it,
/// - with an error threshold, a report is only forwarded when the client's
///   own prediction has drifted too far (see `Subscriber.needsUpdate`).
public actor MockFlightServer {
    public struct Configuration: Sendable {
        public var flightCount: Int
        public var timeScale: Double
        public var tickInterval: Duration
        public var reportInterval: ClosedRange<Double>
        public var seed: UInt64

        public init(flightCount: Int = 50_000, timeScale: Double = 1, tickInterval: Duration = .milliseconds(200),
                    reportInterval: ClosedRange<Double> = 1...3, seed: UInt64 = 24) {
            self.flightCount = flightCount
            self.timeScale = timeScale
            self.tickInterval = tickInterval
            self.reportInterval = reportInterval
            self.seed = seed
        }
    }

    /// What a client last received for one flight, i.e. what it is extrapolating from.
    private struct SentState {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        var time: Double
        var altitudeFt: Double
        var heartbeatDue: Double
    }

    private final class Subscriber {
        /// Heartbeat so the client never extrapolates for long (the shader caps
        /// at 60 s). Spread per flight so a snapshot doesn't make every flight
        /// heartbeat in the same frame.
        static let maxSilence = 45.0
        /// Altitude drives the icon colour and the detail card.
        static let altitudeTolerance = 500.0

        var request: SubscribeRequest
        var sent: [UInt32: SentState] = [:]
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        let timeScale: Double

        init(request: SubscribeRequest, timeScale: Double,
             continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.request = request
            self.timeScale = timeScale
            self.continuation = continuation
        }

        func wants(_ r: PositionReport) -> Bool {
            request.viewport?.contains(latitude: r.latitude, longitude: r.longitude) ?? true
        }

        func record(_ r: PositionReport, observedAt time: Double) {
            sent[r.id] = SentState(
                position: WebMercator.project(latitude: r.latitude, longitude: r.longitude),
                velocity: WebMercator.velocity(latitude: r.latitude, groundSpeedKt: r.groundSpeedKt,
                                               trackDeg: r.trackDeg) * timeScale,
                time: time,
                altitudeFt: r.altitudeFt,
                heartbeatDue: time + Self.maxSilence * (0.6 + 0.4 * Self.jitter(r.id))
            )
        }

        private static func jitter(_ id: UInt32) -> Double {
            Double((UInt64(id) &* 2_654_435_761) % 1000) / 1000
        }

        /// Runs the same straight-line prediction as the client's vertex
        /// shader and forwards the report only if that prediction is now
        /// visibly wrong at the client's zoom level.
        func needsUpdate(_ r: PositionReport, observedAt time: Double) -> Bool {
            guard let threshold = request.errorThresholdPoints, let zoom = request.zoom,
                  let last = sent[r.id] else { return true }
            let dt = time - last.time
            if time >= last.heartbeatDue || abs(r.altitudeFt - last.altitudeFt) >= Self.altitudeTolerance {
                return true
            }
            let predicted = last.position + last.velocity * min(max(dt, 0), 60)
            var error = WebMercator.project(latitude: r.latitude, longitude: r.longitude) - predicted
            error.x -= error.x.rounded()
            let errorPoints = (error * error).sum().squareRoot() * 256 * pow(2, zoom)
            return errorPoints > threshold
        }
    }

    public let configuration: Configuration
    private var simulator: FlightSimulator
    private var subscribers: [UUID: Subscriber] = [:]
    private var loop: Task<Void, Never>?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        simulator = FlightSimulator(flightCount: configuration.flightCount, timeScale: configuration.timeScale,
                                    reportInterval: configuration.reportInterval, seed: configuration.seed,
                                    now: FeedClock.now())
    }

    // MARK: - Stream lifecycle

    func subscribe(_ request: SubscribeRequest,
                   continuation: AsyncThrowingStream<Data, any Error>.Continuation) -> UUID {
        let id = UUID()
        let subscriber = Subscriber(request: request, timeScale: configuration.timeScale, continuation: continuation)
        subscribers[id] = subscriber
        sendSnapshot(to: subscriber)
        startLoopIfNeeded()
        return id
    }

    func update(_ id: UUID, request: SubscribeRequest) {
        guard let subscriber = subscribers[id] else { return }
        subscriber.request = request
        resync(subscriber)
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
        if subscribers.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    private func startLoopIfNeeded() {
        guard loop == nil else { return }
        let interval = configuration.tickInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    // MARK: - Frames

    private var serverTimeMs: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func sendSnapshot(to subscriber: Subscriber) {
        let now = FeedClock.now()
        var batch = FeedBatch(serverTimeMs: serverTimeMs, isSnapshot: true)
        subscriber.sent.removeAll()
        for i in simulator.flights.indices {
            let report = simulator.report(for: i, wallNow: now)
            guard subscriber.wants(report) else { continue }
            subscriber.record(report, observedAt: now)
            batch.added.append(simulator.flights[i].info)
            batch.positions.append(report)
        }
        subscriber.continuation.yield(FeedCodec.encode(batch))
    }

    /// Request changed: add what entered the viewport, remove what left.
    private func resync(_ subscriber: Subscriber) {
        let now = FeedClock.now()
        var batch = FeedBatch(serverTimeMs: serverTimeMs)
        for i in simulator.flights.indices {
            let report = simulator.report(for: i, wallNow: now)
            let inside = subscriber.wants(report)
            let known = subscriber.sent[report.id] != nil
            if inside, !known {
                subscriber.record(report, observedAt: now)
                batch.added.append(simulator.flights[i].info)
                batch.positions.append(report)
            } else if !inside, known {
                subscriber.sent[report.id] = nil
                batch.removed.append(report.id)
            }
        }
        if !batch.isEmpty {
            subscriber.continuation.yield(FeedCodec.encode(batch))
        }
    }

    func tick(at now: Double = FeedClock.now()) {
        let step = simulator.step(wallNow: now)
        let timestamp = serverTimeMs
        for subscriber in subscribers.values {
            var batch = FeedBatch(serverTimeMs: timestamp)
            batch.positions.reserveCapacity(step.reports.count)
            for id in step.landed where subscriber.sent.removeValue(forKey: id) != nil {
                batch.removed.append(id)
            }
            for (index, report) in step.reports {
                let observedAt = now - Double(report.ageMs) / 1000
                let inside = subscriber.wants(report)
                if subscriber.sent[report.id] != nil {
                    if !inside {
                        subscriber.sent[report.id] = nil
                        batch.removed.append(report.id)
                    } else if subscriber.needsUpdate(report, observedAt: observedAt) {
                        subscriber.record(report, observedAt: observedAt)
                        batch.positions.append(report)
                    }
                } else if inside {
                    subscriber.record(report, observedAt: observedAt)
                    batch.added.append(simulator.flights[index].info)
                    batch.positions.append(report)
                }
            }
            if !batch.isEmpty {
                subscriber.continuation.yield(FeedCodec.encode(batch))
            }
        }
    }
}

/// `FeedTransport` backed by an in-process `MockFlightServer`.
public struct MockFeedTransport: FeedTransport {
    public let server: MockFlightServer

    public init(server: MockFlightServer) {
        self.server = server
    }

    public func openLiveFeed(_ request: SubscribeRequest) async -> FeedConnection {
        // Unbounded like an HTTP/2 stream with a generous window: dropping a
        // delta frame would desync the client, so we never drop.
        let (frames, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let server = server
        let id = await server.subscribe(request, continuation: continuation)
        continuation.onTermination = { _ in
            Task { await server.unsubscribe(id) }
        }
        return FeedConnection(
            frames: frames,
            send: { await server.update(id, request: $0) },
            close: { await server.unsubscribe(id) }
        )
    }
}
