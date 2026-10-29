import SwiftUI

@main
struct LiveRadarApp: App {
    @State private var model = RadarViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    let model: RadarViewModel

    var body: some View {
        ZStack {
            RadarMapView(model: model)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HUDView(stats: model.hud, mode: model.renderMode)
                Spacer()
                if let detail = model.selectedDetail {
                    FlightCard(detail: detail) { model.select(nil) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ControlPanel(model: model)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
            .animation(.snappy, value: model.selectedDetail == nil)
        }
    }
}
