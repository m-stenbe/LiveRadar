import SwiftUI
import FlightFeed

struct FlightCard: View {
    let detail: FlightDetail
    let onClose: () -> Void

    var body: some View {
        let r = detail.report
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.info?.callsign ?? "#\(r.id)").font(.title3.bold())
                Text(detail.info?.aircraftType ?? "").foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
            }
            if let info = detail.info {
                Label("\(info.origin) → \(info.destination)", systemImage: "airplane.departure")
            }
            HStack(spacing: 16) {
                value("Altitude", "\(Int(r.altitudeFt).formatted()) ft")
                value("Speed", "\(Int(r.groundSpeedKt)) kt")
                value("Track", "\(Int(r.trackDeg))°")
                value("V/S", "\(Int(r.verticalRateFpm)) fpm")
            }
            Text(String(format: "%.4f, %.4f", r.latitude, r.longitude))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func value(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}
