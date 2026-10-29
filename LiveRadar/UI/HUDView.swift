import SwiftUI

struct HUDView: View {
    let stats: HUDStats
    let mode: RadarViewModel.RenderMode

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("FPS", String(format: "%.0f", stats.fps), warn: stats.fps < 50)
            row("Worst frame", String(format: "%.0f ms", stats.worstFrameMs), warn: stats.worstFrameMs > 34)
            row("Aircraft", stats.aircraft.formatted())
            row("Feed", String(format: "%.0f KB/s · %.1f fr/s", stats.kilobytesPerSecond, stats.framesPerSecond))
            row("Records", String(format: "%.0f/s", stats.recordsPerSecond))
            row("Decode+apply", String(format: "%.1f + %.1f ms", stats.decodeMs, stats.applyMs))
            row("Last frame", String(format: "%.1f KB", stats.lastFrameKB))
            if mode == .annotations {
                row("Main-thread sync", String(format: "%.0f ms", stats.mainThreadSyncMs),
                    warn: stats.mainThreadSyncMs > 16)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(warn ? .red : .primary)
        }
    }
}
