import MapKit
import MetalKit
import SwiftUI
import FlightFeed

/// MKMapView for tiles and gestures, with a transparent, touch-through
/// MTKView on top that draws the aircraft.
struct RadarMapView: UIViewRepresentable {
    let model: RadarViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        let map = MKMapView(frame: container.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
                                        span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30))
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: AnnotationBaseline.reuseIdentifier)
        container.addSubview(map)

        let metal = MTKView(frame: container.bounds, device: MTLCreateSystemDefaultDevice())
        metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metal.isOpaque = false
        metal.backgroundColor = .clear
        metal.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metal.colorPixelFormat = .bgra8Unorm
        metal.preferredFramesPerSecond = 120
        metal.isUserInteractionEnabled = false
        container.addSubview(metal)

        context.coordinator.attach(map: map, metal: metal)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(feed: model.renderFeed, mode: model.renderMode, selectedID: model.selectedID)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        private let model: RadarViewModel
        private var renderer: AircraftRenderer?
        private var baseline: AnnotationBaseline
        private weak var metalView: MTKView?
        private let frameMonitor = FrameRateMonitor()
        private var mode: RadarViewModel.RenderMode?

        init(model: RadarViewModel) {
            self.model = model
            baseline = AnnotationBaseline(feed: model.renderFeed)
        }

        func attach(map: MKMapView, metal: MTKView) {
            map.delegate = self
            metalView = metal
            renderer = AircraftRenderer(view: metal, feed: model.renderFeed)
            renderer?.mapView = map
            baseline.mapView = map

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            map.addGestureRecognizer(tap)

            frameMonitor.onUpdate = { [weak self] fps, worst in
                guard let self else { return }
                model.updateFrameStats(fps: fps, worstFrameMs: worst, mainThreadSyncMs: baseline.lastSyncMs)
            }
            frameMonitor.start()
        }

        func update(feed: RenderFeed, mode: RadarViewModel.RenderMode, selectedID: UInt32?) {
            renderer?.feed = feed
            renderer?.selectedID = selectedID ?? 0
            baseline.feed = feed
            guard mode != self.mode else { return }
            self.mode = mode
            switch mode {
            case .metal:
                baseline.stop()
                metalView?.isHidden = false
                metalView?.isPaused = false
            case .annotations:
                metalView?.isHidden = true
                metalView?.isPaused = true
                baseline.start()
            }
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard mode == .metal, let renderer, let map = gesture.view else { return }
            model.select(renderer.hitTest(gesture.location(in: map)))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            model.viewportChanged(mapView.feedViewport, zoom: MapProjection(mapView: mapView).zoom)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let aircraft = annotation as? AnnotationBaseline.AircraftAnnotation else { return nil }
            return baseline.view(for: aircraft, in: mapView)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard let aircraft = annotation as? AnnotationBaseline.AircraftAnnotation else { return }
            model.select(aircraft.id)
        }
    }
}
