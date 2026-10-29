import Foundation
import FlightFeed

/// Deterministic PRNG so the simulated sky is reproducible across runs and tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct SimFlight {
    var info: FlightInfo
    var destinationIndex: Int
    // Great-circle route as unit vectors on the sphere.
    var from: SIMD3<Double>
    var to: SIMD3<Double>
    var angle: Double
    var distanceM: Double
    var speedMps: Double
    var cruiseAltFt: Double
    /// Simulated seconds.
    var departure: Double
    /// Wall-clock `FeedClock` seconds. Each aircraft reports on its own
    /// cadence, like ADS-B receivers do, so frames carry a rolling subset.
    var nextReport: Double
    var reportInterval: Double
}

/// Moves `flightCount` aircraft along great circles between real airports.
/// When a flight lands, a new one (new ID) departs from that airport.
struct FlightSimulator {
    private static let earthRadius = 6_371_000.0
    private static let climbDistance = 180_000.0
    private static let descentDistance = 220_000.0

    private(set) var flights: [SimFlight] = []
    private var rng: SplitMix64
    private var nextID: UInt32 = 1
    private let timeScale: Double
    private let reportInterval: ClosedRange<Double>
    private let startWall: Double
    private let cumulativeWeights: [Double]

    init(flightCount: Int, timeScale: Double, reportInterval: ClosedRange<Double>, seed: UInt64, now: Double) {
        rng = SplitMix64(seed: seed)
        self.timeScale = timeScale
        self.reportInterval = reportInterval
        startWall = now
        var sum = 0.0
        cumulativeWeights = Airports.all.map { sum += $0.weight; return sum }

        flights.reserveCapacity(flightCount)
        for _ in 0..<flightCount {
            var flight = makeFlight(from: randomAirport(), departingAt: 0, now: now)
            // Start mid-air at a random point of the trip.
            let duration = flight.distanceM / flight.speedMps
            flight.departure = -Double.random(in: 0...0.97, using: &rng) * duration
            flights.append(flight)
        }
    }

    func simTime(_ wallNow: Double) -> Double {
        (wallNow - startWall) * timeScale
    }

    struct StepResult {
        var reports: [(index: Int, report: PositionReport)] = []
        var landed: [UInt32] = []
        var departed: [Int] = []
    }

    /// Advances to `wallNow`: lands finished flights, spawns replacements and
    /// collects reports for every aircraft whose report is due.
    mutating func step(wallNow: Double) -> StepResult {
        var result = StepResult()
        let t = simTime(wallNow)
        for i in flights.indices where flights[i].nextReport <= wallNow {
            if t - flights[i].departure >= flights[i].distanceM / flights[i].speedMps {
                result.landed.append(flights[i].info.id)
                flights[i] = makeFlight(from: flights[i].destinationIndex, departingAt: t, now: wallNow)
                result.departed.append(i)
            }
            flights[i].nextReport = wallNow + flights[i].reportInterval
            let age = Int.random(in: 50...900, using: &rng)
            result.reports.append((i, report(for: i, wallNow: wallNow - Double(age) / 1000, age: age)))
        }
        return result
    }

    func report(for index: Int, wallNow: Double, age: Int = 0) -> PositionReport {
        let f = flights[index]
        let traveled = min(max((simTime(wallNow) - f.departure) * f.speedMps, 0), f.distanceM)
        let fraction = traveled / f.distanceM
        let s = sin(f.angle)
        let p = s > 1e-9
            ? f.from * (sin((1 - fraction) * f.angle) / s) + f.to * (sin(fraction * f.angle) / s)
            : f.from
        let (lat, lon) = Self.latLon(p)
        let (destLat, destLon) = Self.latLon(f.to)

        let remaining = f.distanceM - traveled
        let climb = traveled / Self.climbDistance
        let descent = remaining / Self.descentDistance
        let altitude = f.cruiseAltFt * min(1, climb, descent)
        var verticalRate = 0.0
        if climb < 1 || descent < 1 {
            let minutes = (climb < descent ? Self.climbDistance : Self.descentDistance) / f.speedMps / 60
            verticalRate = (climb < descent ? 1 : -1) * f.cruiseAltFt / minutes
        }

        return PositionReport(
            id: f.info.id,
            latitude: lat,
            longitude: lon,
            altitudeFt: altitude,
            groundSpeedKt: f.speedMps / 0.514444,
            trackDeg: Self.bearing(fromLat: lat, fromLon: lon, toLat: destLat, toLon: destLon),
            verticalRateFpm: verticalRate,
            ageMs: age
        )
    }

    // MARK: - Spawning

    private mutating func randomAirport() -> Int {
        let r = Double.random(in: 0..<cumulativeWeights.last!, using: &rng)
        return cumulativeWeights.firstIndex { $0 > r } ?? 0
    }

    private mutating func makeFlight(from origin: Int, departingAt t: Double, now: Double) -> SimFlight {
        let a = Airports.all[origin]
        var destination = randomAirport()
        var angle = 0.0
        // Re-roll until the route is at least ~400 km.
        for _ in 0..<16 {
            let b = Airports.all[destination]
            angle = Self.angle(Self.unit(a.latitude, a.longitude), Self.unit(b.latitude, b.longitude))
            if destination != origin, angle * Self.earthRadius > 400_000 { break }
            destination = randomAirport()
        }
        let b = Airports.all[destination]
        let id = nextID
        nextID &+= 1
        let airline = Fleet.airlines.randomElement(using: &rng)!

        return SimFlight(
            info: FlightInfo(
                id: id,
                callsign: "\(airline)\(Int.random(in: 10...9899, using: &rng))",
                aircraftType: Fleet.types.randomElement(using: &rng)!,
                origin: a.code,
                destination: b.code
            ),
            destinationIndex: destination,
            from: Self.unit(a.latitude, a.longitude),
            to: Self.unit(b.latitude, b.longitude),
            angle: angle,
            distanceM: max(angle * Self.earthRadius, 1),
            speedMps: Double.random(in: 205...255, using: &rng),
            cruiseAltFt: Double(Int.random(in: 28...41, using: &rng) * 1000),
            departure: t,
            nextReport: now + Double.random(in: 0...reportInterval.upperBound, using: &rng),
            reportInterval: Double.random(in: reportInterval, using: &rng)
        )
    }

    // MARK: - Spherical geometry

    private static func unit(_ lat: Double, _ lon: Double) -> SIMD3<Double> {
        let phi = lat * .pi / 180, lambda = lon * .pi / 180
        return SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    private static func latLon(_ v: SIMD3<Double>) -> (Double, Double) {
        (atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()) * 180 / .pi, atan2(v.y, v.x) * 180 / .pi)
    }

    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(max((a * b).sum(), -1), 1))
    }

    private static func bearing(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Double {
        let p1 = fromLat * .pi / 180, p2 = toLat * .pi / 180
        let dl = (toLon - fromLon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}
