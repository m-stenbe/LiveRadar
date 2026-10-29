// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightFeed",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlightFeed", targets: ["FlightFeed"]),
        .library(name: "MockFlightServer", targets: ["MockFlightServer"]),
    ],
    targets: [
        // Client side: wire model, codec, transport seam and the ingest engine.
        .target(name: "FlightFeed"),
        // Fake backend: simulates global traffic and streams encoded frames.
        .target(name: "MockFlightServer", dependencies: ["FlightFeed"]),
        .testTarget(name: "FlightFeedTests", dependencies: ["FlightFeed", "MockFlightServer"]),
    ]
)
