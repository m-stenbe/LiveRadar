import Foundation
import Observation
import FlightFeed
import MockFlightServer

struct HUDStats: Equatable {
    var fps = 0.0
    var worstFrameMs = 0.0
    var mainThreadSyncMs = 0.0
    var aircraft = 0
    var kilobytesPerSecond = 0.0
    var framesPerSecond = 0.0
    var recordsPerSecond = 0.0
    var decodeMs = 0.0
    var applyMs = 0.0
    var lastFrameKB = 0.0
}

@MainActor
@Observable
final class RadarViewModel {
    enum RenderMode: String, CaseIterable, Identifiable {
        case metal = "Metal"
        case annotations = "MKAnnotation"
        var id: Self { self }
    }

    static let flightCounts = [1_000, 10_000, 50_000, 100_000]
    static let timeScales: [Double] = [1, 10, 60]

    var flightCount = 50_000 { didSet { if flightCount != oldValue { restart() } } }
    var timeScale = 10.0 { didSet { if timeScale != oldValue { restart() } } }
    var viewportOnly = false { didSet { sendRequest() } }
    /// Server forwards a report only when the client's prediction is off by
    /// more than `errorThresholdPoints` on screen.
    var adaptiveUpdates = true { didSet { sendRequest() } }
    static let errorThresholdPoints = 2.0
    var renderMode = RenderMode.metal

    private(set) var selectedID: UInt32?
    private(set) var selectedDetail: FlightDetail?
    private(set) var hud = HUDStats()

    private(set) var engine: LiveTrafficEngine
    private var viewport: Viewport?
    private var zoom: Double?
    private var viewportDebounce: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var previousStats = FeedStats()
    private var previousSample = Date()

    var renderFeed: RenderFeed { engine.renderFeed }

    init() {
        engine = Self.makeEngine(flightCount: 50_000, timeScale: 10)
        Task { [engine, request] in await engine.start(request) }
        startPolling()
    }

    private static func makeEngine(flightCount: Int, timeScale: Double) -> LiveTrafficEngine {
        let server = MockFlightServer(configuration: .init(flightCount: flightCount, timeScale: timeScale))
        return LiveTrafficEngine(transport: MockFeedTransport(server: server), timeScale: timeScale)
    }

    private var request: SubscribeRequest {
        SubscribeRequest(viewport: viewportOnly ? viewport : nil, zoom: zoom,
                         errorThresholdPoints: adaptiveUpdates ? Self.errorThresholdPoints : nil)
    }

    private func restart() {
        let old = engine
        Task { await old.stop() }
        engine = Self.makeEngine(flightCount: flightCount, timeScale: timeScale)
        previousStats = FeedStats()
        select(nil)
        Task { [engine, request] in await engine.start(request) }
    }

    private func sendRequest() {
        Task { [engine, request] in await engine.update(request) }
    }

    func viewportChanged(_ viewport: Viewport?, zoom: Double) {
        self.viewport = viewport
        self.zoom = zoom
        // Panning fires many region changes; only tell the server once it settles.
        viewportDebounce?.cancel()
        viewportDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            sendRequest()
        }
    }

    func select(_ id: UInt32?) {
        selectedID = id
        selectedDetail = nil
        refreshDetail()
    }

    func updateFrameStats(fps: Double, worstFrameMs: Double, mainThreadSyncMs: Double) {
        hud.fps = fps
        hud.worstFrameMs = worstFrameMs
        hud.mainThreadSyncMs = mainThreadSyncMs
    }

    private func refreshDetail() {
        guard let id = selectedID else { return }
        Task { [engine] in
            let detail = await engine.detail(for: id)
            guard selectedID == id else { return }
            selectedDetail = detail
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.sampleStats()
            }
        }
    }

    private func sampleStats() async {
        let stats = await engine.currentStats()
        let now = Date()
        let dt = max(now.timeIntervalSince(previousSample), 0.001)
        hud.aircraft = stats.aircraft
        hud.kilobytesPerSecond = Double(stats.bytes - previousStats.bytes) / 1024 / dt
        hud.framesPerSecond = Double(stats.frames - previousStats.frames) / dt
        hud.recordsPerSecond = Double(stats.records - previousStats.records) / dt
        hud.decodeMs = stats.lastDecodeMs
        hud.applyMs = stats.lastApplyMs
        hud.lastFrameKB = Double(stats.lastFrameBytes) / 1024
        previousStats = stats
        previousSample = now
        refreshDetail()
    }
}
