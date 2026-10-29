import MapKit
import FlightFeed

/// Snapshot of how the map currently maps normalized Mercator to view points.
/// Rotation and pitch are disabled on the map, so this is a scale + offset.
struct MapProjection {
    var center: SIMD2<Double>
    var pointsPerUnit: Double
    var viewSize: CGSize

    @MainActor init(mapView: MKMapView) {
        let rect = mapView.visibleMapRect
        let world = MKMapSize.world.width
        viewSize = mapView.bounds.size
        pointsPerUnit = Double(viewSize.width) / max(rect.size.width / world, .leastNonzeroMagnitude)
        center = SIMD2(rect.midX / world, rect.midY / world)
    }

    /// Web map zoom level (world is 256 * 2^zoom points wide).
    var zoom: Double { log2(pointsPerUnit / 256) }

    /// Icons shrink when zoomed out, where thousands overlap.
    var iconHalfSize: Double {
        let t = min(max((zoom - 2) / 6, 0), 1)
        return 4 + t * 8
    }

    func screenPoint(_ mercator: SIMD2<Double>) -> CGPoint {
        var d = mercator - center
        d.x -= d.x.rounded()
        return CGPoint(x: viewSize.width / 2 + d.x * pointsPerUnit, y: viewSize.height / 2 + d.y * pointsPerUnit)
    }
}

extension MKMapView {
    /// The visible area plus a margin, as a feed viewport (`nil` = whole world).
    var feedViewport: Viewport? {
        let r = region
        guard r.span.longitudeDelta < 300 else { return nil }
        let halfLat = r.span.latitudeDelta * 0.65
        let halfLon = r.span.longitudeDelta * 0.65
        func wrap(_ lon: Double) -> Double {
            var l = lon.truncatingRemainder(dividingBy: 360)
            if l > 180 { l -= 360 } else if l < -180 { l += 360 }
            return l
        }
        return Viewport(minLat: max(r.center.latitude - halfLat, -90), maxLat: min(r.center.latitude + halfLat, 90),
                        minLon: wrap(r.center.longitude - halfLon), maxLon: wrap(r.center.longitude + halfLon))
    }
}
