import MapKit
import FlightFeed

/// The "obvious" implementation, kept for comparison: one MKAnnotation per
/// aircraft, coordinates updated once per second on the main thread.
///
/// Each coordinate change goes through KVO, and every visible aircraft is a
/// UIView that MapKit lays out, hit-tests and collision-checks on the main
/// thread. Measured in the iOS 26 simulator: ~50–90 ms per update at 1k,
/// ~6 s at 10k, and 50k froze the main thread for over 90 s.
@MainActor
final class AnnotationBaseline {
    final class AircraftAnnotation: NSObject, MKAnnotation {
        let id: UInt32
        @objc dynamic var coordinate: CLLocationCoordinate2D
        var heading: Float

        init(id: UInt32, coordinate: CLLocationCoordinate2D, heading: Float) {
            self.id = id
            self.coordinate = coordinate
            self.heading = heading
        }
    }

    static let reuseIdentifier = "aircraft"
    /// Beyond this the app stops responding, so the comparison caps it.
    static let maxAnnotations = 10_000
    private static let icon = AircraftIcon.image()

    weak var mapView: MKMapView?
    var feed: RenderFeed
    /// Main-thread time spent in the last sync, surfaced in the HUD.
    private(set) var lastSyncMs = 0.0

    private var annotations: [UInt32: AircraftAnnotation] = [:]
    private var timer: Timer?

    init(feed: RenderFeed) {
        self.feed = feed
    }

    var isActive: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        mapView?.removeAnnotations(Array(annotations.values))
        annotations.removeAll()
        lastSyncMs = 0
    }

    func view(for annotation: AircraftAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.reuseIdentifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: Self.reuseIdentifier)
        view.annotation = annotation
        view.image = Self.icon
        view.transform = CGAffineTransform(rotationAngle: CGFloat(annotation.heading))
        return view
    }

    private func sync() {
        guard let mapView else { return }
        let start = CACurrentMediaTime()
        let instances = feed.latest().instances.prefix(Self.maxAnnotations)

        var seen = Set<UInt32>(minimumCapacity: instances.count)
        var added: [AircraftAnnotation] = []
        for a in instances {
            seen.insert(a.id)
            let (lat, lon) = WebMercator.unproject(SIMD2<Double>(a.position))
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if let existing = annotations[a.id] {
                existing.coordinate = coordinate
                existing.heading = a.heading
                mapView.view(for: existing)?.transform = CGAffineTransform(rotationAngle: CGFloat(a.heading))
            } else {
                let annotation = AircraftAnnotation(id: a.id, coordinate: coordinate, heading: a.heading)
                annotations[a.id] = annotation
                added.append(annotation)
            }
        }
        let gone = annotations.filter { !seen.contains($0.key) }
        gone.keys.forEach { annotations[$0] = nil }

        mapView.removeAnnotations(Array(gone.values))
        mapView.addAnnotations(added)
        lastSyncMs = (CACurrentMediaTime() - start) * 1000
    }
}
