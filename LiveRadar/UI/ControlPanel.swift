import SwiftUI

struct ControlPanel: View {
    @Bindable var model: RadarViewModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("Aircraft", selection: $model.flightCount) {
                ForEach(RadarViewModel.flightCounts, id: \.self) { count in
                    Text(count >= 1000 ? "\(count / 1000)k" : "\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)

            Picker("Renderer", selection: $model.renderMode) {
                ForEach(RadarViewModel.RenderMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Viewport only", isOn: $model.viewportOnly)
                    .fixedSize()
                Spacer()
                Toggle("Adaptive", isOn: $model.adaptiveUpdates)
                    .fixedSize()
            }
            .font(.subheadline)

            Picker("Sim speed", selection: $model.timeScale) {
                ForEach(RadarViewModel.timeScales, id: \.self) { Text("\(Int($0))× speed").tag($0) }
            }
            .pickerStyle(.segmented)

            if model.renderMode == .annotations && model.flightCount > 1_000 {
                Text("MKAnnotation mode is capped at 10k so the app stays responsive. Even 10k stalls the main thread for seconds per update.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
