import MapKit
import MetalKit
import FlightFeed

/// Draws every aircraft in one instanced draw call on a transparent Metal
/// layer above the MKMapView.
///
/// Per display frame the CPU does O(1) work: read the latest snapshot,
/// re-upload only if it changed (a few times per second), and push a 40-byte
/// uniform block describing the map camera. Movement between reports is
/// computed per vertex on the GPU.
@MainActor
final class AircraftRenderer: NSObject {
    private struct Uniforms {
        var center: SIMD2<Float>
        var scale: SIMD2<Float>
        var iconSize: SIMD2<Float>
        var now: Float
        var selectedID: UInt32
        var selectedOnly: UInt32 = 0
        var padding: UInt32 = 0
    }

    var feed: RenderFeed
    weak var mapView: MKMapView?
    var selectedID: UInt32 = 0

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let icon: MTLTexture
    private let sampler: MTLSamplerState
    private var instanceBuffer: MTLBuffer?
    private var instanceCount = 0
    private var uploadedVersion: UInt64 = .max
    /// The CPU copy matching what is on screen, for hit-testing.
    private var snapshot = RenderFeed.Snapshot.empty

    init?(view: MTKView, feed: RenderFeed) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let icon = AircraftIcon.texture(device: device, queue: queue) else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "aircraftVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "aircraftFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = view.colorPixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.feed = feed
        self.queue = queue
        self.pipeline = pipeline
        self.icon = icon
        self.sampler = sampler
        super.init()
        view.device = device
        view.delegate = self
    }

    /// Nearest aircraft within `radius` points of `point`, using the same
    /// extrapolation as the shader. A linear scan of 50k is well under a
    /// millisecond, so a spatial index only pays off for continuous hover.
    func hitTest(_ point: CGPoint, radius: CGFloat = 24) -> UInt32? {
        guard let mapView else { return nil }
        let projection = MapProjection(mapView: mapView)
        let now = FeedClock.now()
        var best: (id: UInt32, distance: CGFloat)?
        for a in snapshot.instances {
            let dt = min(max(now - Double(a.timestamp), 0), 60)
            let merc = SIMD2<Double>(a.position) + SIMD2<Double>(a.velocity) * dt
            let p = projection.screenPoint(merc)
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance < radius, distance < best?.distance ?? .infinity {
                best = (a.id, distance)
            }
        }
        return best?.id
    }

    private func uploadIfNeeded(device: MTLDevice) {
        let latest = feed.latest()
        guard latest.version != uploadedVersion else { return }
        uploadedVersion = latest.version
        snapshot = latest
        instanceCount = latest.instances.count
        // A fresh buffer per upload: in-flight command buffers keep the old one
        // alive, so there is no need for triple-buffering semaphores.
        instanceBuffer = latest.instances.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }
    }
}

extension AircraftRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let mapView, let device = view.device else { return }
        uploadIfNeeded(device: device)
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let instanceBuffer, instanceCount > 0 {
            let projection = MapProjection(mapView: mapView)
            let w = Double(projection.viewSize.width), h = Double(projection.viewSize.height)
            let half = projection.iconHalfSize
            var uniforms = Uniforms(
                center: SIMD2<Float>(projection.center),
                scale: SIMD2<Float>(Float(projection.pointsPerUnit * 2 / w), Float(-projection.pointsPerUnit * 2 / h)),
                iconSize: SIMD2<Float>(Float(half * 2 / w), Float(half * 2 / h)),
                now: Float(FeedClock.now()),
                selectedID: selectedID
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(icon, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)

            if selectedID != 0 {
                // Second pass so the selected aircraft is drawn on top of the rest.
                uniforms.selectedOnly = 1
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
            }
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
