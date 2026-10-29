import Metal
import UIKit

enum AircraftIcon {
    /// For the MKAnnotation baseline.
    static func image(size: CGFloat = 20) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            draw(in: ctx.cgContext, size: size)
        }
    }

    /// Premultiplied RGBA8 texture with mipmaps, nose at the top row.
    static func texture(device: MTLDevice, queue: MTLCommandQueue, size: Int = 64) -> MTLTexture? {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Bitmap memory starts at the top row; flip so path coordinates are top-down.
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            draw(in: ctx, size: CGFloat(size))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size,
                                                                  height: size, mipmapped: true)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        // Icons are drawn at 8–24 px from a 64 px source; mipmaps avoid shimmering.
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }

    /// A top-down aircraft silhouette pointing up: white fill, dark outline,
    /// so the shader can tint the fill. Drawn in code, no assets to ship.
    private static func draw(in ctx: CGContext, size: CGFloat) {
        let s = size / 64
        // Right half of the outline; mirrored for the left half.
        let right: [CGPoint] = [
            CGPoint(x: 32, y: 3), CGPoint(x: 35, y: 9), CGPoint(x: 35, y: 24), CGPoint(x: 60, y: 38),
            CGPoint(x: 60, y: 43), CGPoint(x: 35, y: 37), CGPoint(x: 35, y: 50), CGPoint(x: 45, y: 57),
            CGPoint(x: 45, y: 61), CGPoint(x: 32, y: 58),
        ]
        let outline = right + right.reversed().dropFirst().dropLast().map { CGPoint(x: 64 - $0.x, y: $0.y) }
        ctx.addLines(between: outline.map { CGPoint(x: $0.x * s, y: $0.y * s) })
        ctx.closePath()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(3.5 * s)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.setStrokeColor(UIColor(white: 0.05, alpha: 1).cgColor)
        ctx.drawPath(using: .fillStroke)
    }
}
