import QuartzCore

/// Measures how often the main run loop actually delivers frames. This is the
/// honest lag metric: it drops for both render modes if the main thread stalls.
@MainActor
final class FrameRateMonitor: NSObject {
    var onUpdate: ((_ fps: Double, _ worstFrameMs: Double) -> Void)?

    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = link.timestamp
        if lastTimestamp > 0 { worst = max(worst, t - lastTimestamp) }
        lastTimestamp = t
        if windowStart == 0 { windowStart = t }
        frames += 1
        if t - windowStart >= 0.5 {
            onUpdate?(Double(frames) / (t - windowStart), worst * 1000)
            frames = 0
            worst = 0
            windowStart = t
        }
    }
}
