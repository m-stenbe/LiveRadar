import Foundation

/// The seam between the app and the network.
///
/// Shaped like a bidirectional-streaming gRPC call: the client opens a stream
/// with a request, may send updated requests (new viewport) at any time, and
/// receives encoded frames until the stream ends or fails. A production
/// implementation would wrap a generated grpc-swift client here; the app and
/// the engine only ever see this protocol.
public protocol FeedTransport: Sendable {
    func openLiveFeed(_ request: SubscribeRequest) async -> FeedConnection
}

public struct FeedConnection: Sendable {
    public let frames: AsyncThrowingStream<Data, any Error>
    public let send: @Sendable (SubscribeRequest) async -> Void
    public let close: @Sendable () async -> Void

    public init(frames: AsyncThrowingStream<Data, any Error>,
                send: @escaping @Sendable (SubscribeRequest) async -> Void,
                close: @escaping @Sendable () async -> Void) {
        self.frames = frames
        self.send = send
        self.close = close
    }
}

/// Shared monotonic time base (seconds) for the engine and the renderer.
/// Uses system uptime, the same clock as `CACurrentMediaTime`.
public enum FeedClock {
    public static let epoch = ProcessInfo.processInfo.systemUptime

    public static func now() -> Double {
        ProcessInfo.processInfo.systemUptime - epoch
    }
}
