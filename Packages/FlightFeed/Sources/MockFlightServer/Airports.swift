struct Airport: Sendable {
    let code: String
    let latitude: Double
    let longitude: Double
    /// Relative share of departures, so traffic clusters like real traffic does.
    let weight: Double
}

enum Airports {
    static let all: [Airport] = [
        // Europe
        Airport(code: "LHR", latitude: 51.470, longitude: -0.454, weight: 5),
        Airport(code: "CDG", latitude: 49.010, longitude: 2.548, weight: 5),
        Airport(code: "AMS", latitude: 52.310, longitude: 4.768, weight: 5),
        Airport(code: "FRA", latitude: 50.033, longitude: 8.570, weight: 5),
        Airport(code: "IST", latitude: 41.275, longitude: 28.752, weight: 4),
        Airport(code: "MAD", latitude: 40.472, longitude: -3.561, weight: 4),
        Airport(code: "BCN", latitude: 41.297, longitude: 2.078, weight: 3),
        Airport(code: "MUC", latitude: 48.354, longitude: 11.786, weight: 3),
        Airport(code: "FCO", latitude: 41.800, longitude: 12.239, weight: 3),
        Airport(code: "ARN", latitude: 59.650, longitude: 17.930, weight: 2),
        Airport(code: "CPH", latitude: 55.618, longitude: 12.656, weight: 2),
        Airport(code: "OSL", latitude: 60.194, longitude: 11.100, weight: 2),
        Airport(code: "HEL", latitude: 60.317, longitude: 24.963, weight: 2),
        Airport(code: "GOT", latitude: 57.663, longitude: 12.280, weight: 1),
        Airport(code: "DUB", latitude: 53.421, longitude: -6.270, weight: 2),
        Airport(code: "ZRH", latitude: 47.458, longitude: 8.548, weight: 2),
        Airport(code: "VIE", latitude: 48.110, longitude: 16.570, weight: 2),
        Airport(code: "WAW", latitude: 52.166, longitude: 20.967, weight: 2),
        Airport(code: "LIS", latitude: 38.774, longitude: -9.134, weight: 2),
        Airport(code: "ATH", latitude: 37.936, longitude: 23.947, weight: 2),
        Airport(code: "PMI", latitude: 39.552, longitude: 2.739, weight: 2),
        Airport(code: "MAN", latitude: 53.354, longitude: -2.275, weight: 2),
        Airport(code: "BRU", latitude: 50.901, longitude: 4.484, weight: 2),
        // North America
        Airport(code: "ATL", latitude: 33.640, longitude: -84.427, weight: 6),
        Airport(code: "ORD", latitude: 41.978, longitude: -87.904, weight: 5),
        Airport(code: "DFW", latitude: 32.899, longitude: -97.040, weight: 5),
        Airport(code: "DEN", latitude: 39.856, longitude: -104.674, weight: 5),
        Airport(code: "LAX", latitude: 33.942, longitude: -118.408, weight: 5),
        Airport(code: "JFK", latitude: 40.641, longitude: -73.778, weight: 4),
        Airport(code: "SFO", latitude: 37.621, longitude: -122.379, weight: 3),
        Airport(code: "SEA", latitude: 47.450, longitude: -122.309, weight: 3),
        Airport(code: "LAS", latitude: 36.084, longitude: -115.154, weight: 3),
        Airport(code: "MCO", latitude: 28.431, longitude: -81.308, weight: 3),
        Airport(code: "MIA", latitude: 25.796, longitude: -80.287, weight: 3),
        Airport(code: "CLT", latitude: 35.214, longitude: -80.943, weight: 3),
        Airport(code: "PHX", latitude: 33.437, longitude: -112.008, weight: 3),
        Airport(code: "IAH", latitude: 29.990, longitude: -95.337, weight: 3),
        Airport(code: "BOS", latitude: 42.366, longitude: -71.010, weight: 2),
        Airport(code: "MSP", latitude: 44.885, longitude: -93.222, weight: 2),
        Airport(code: "DTW", latitude: 42.216, longitude: -83.355, weight: 2),
        Airport(code: "YYZ", latitude: 43.677, longitude: -79.625, weight: 3),
        Airport(code: "YVR", latitude: 49.195, longitude: -123.184, weight: 2),
        Airport(code: "MEX", latitude: 19.436, longitude: -99.072, weight: 3),
        // South America
        Airport(code: "GRU", latitude: -23.435, longitude: -46.473, weight: 3),
        Airport(code: "BOG", latitude: 4.702, longitude: -74.147, weight: 2),
        Airport(code: "SCL", latitude: -33.393, longitude: -70.786, weight: 2),
        Airport(code: "EZE", latitude: -34.822, longitude: -58.536, weight: 2),
        Airport(code: "LIM", latitude: -12.022, longitude: -77.114, weight: 2),
        // Middle East & Africa
        Airport(code: "DXB", latitude: 25.253, longitude: 55.365, weight: 4),
        Airport(code: "DOH", latitude: 25.273, longitude: 51.608, weight: 3),
        Airport(code: "JED", latitude: 21.680, longitude: 39.157, weight: 2),
        Airport(code: "CAI", latitude: 30.122, longitude: 31.406, weight: 2),
        Airport(code: "JNB", latitude: -26.139, longitude: 28.246, weight: 2),
        Airport(code: "NBO", latitude: -1.319, longitude: 36.928, weight: 1),
        Airport(code: "ADD", latitude: 8.978, longitude: 38.799, weight: 1),
        Airport(code: "CMN", latitude: 33.367, longitude: -7.590, weight: 1),
        // Asia & Oceania
        Airport(code: "PEK", latitude: 40.080, longitude: 116.585, weight: 5),
        Airport(code: "PVG", latitude: 31.143, longitude: 121.805, weight: 5),
        Airport(code: "CAN", latitude: 23.392, longitude: 113.299, weight: 4),
        Airport(code: "HKG", latitude: 22.308, longitude: 113.918, weight: 4),
        Airport(code: "HND", latitude: 35.549, longitude: 139.780, weight: 5),
        Airport(code: "ICN", latitude: 37.460, longitude: 126.441, weight: 4),
        Airport(code: "SIN", latitude: 1.364, longitude: 103.991, weight: 4),
        Airport(code: "BKK", latitude: 13.690, longitude: 100.750, weight: 4),
        Airport(code: "KUL", latitude: 2.746, longitude: 101.710, weight: 3),
        Airport(code: "CGK", latitude: -6.126, longitude: 106.656, weight: 3),
        Airport(code: "MNL", latitude: 14.509, longitude: 121.020, weight: 3),
        Airport(code: "DEL", latitude: 28.556, longitude: 77.100, weight: 4),
        Airport(code: "BOM", latitude: 19.090, longitude: 72.866, weight: 4),
        Airport(code: "BLR", latitude: 13.199, longitude: 77.707, weight: 2),
        Airport(code: "CTU", latitude: 30.578, longitude: 103.947, weight: 3),
        Airport(code: "TPE", latitude: 25.080, longitude: 121.233, weight: 2),
        Airport(code: "SYD", latitude: -33.940, longitude: 151.175, weight: 3),
        Airport(code: "MEL", latitude: -37.669, longitude: 144.841, weight: 3),
        Airport(code: "BNE", latitude: -27.384, longitude: 153.117, weight: 2),
        Airport(code: "AKL", latitude: -37.008, longitude: 174.792, weight: 2),
        Airport(code: "PER", latitude: -31.940, longitude: 115.967, weight: 1),
    ]
}

enum Fleet {
    static let airlines = ["SAS", "DLH", "BAW", "AFR", "KLM", "UAL", "DAL", "AAL", "SWA", "RYR",
                           "EZY", "THY", "UAE", "QTR", "SIA", "CPA", "ANA", "JAL", "QFA", "ACA",
                           "IBE", "FIN", "NAX", "WZZ", "CES", "CSN", "AIC", "KAL", "LAN", "AZU"]
    static let types = ["A320", "A20N", "A321", "A21N", "B738", "B38M", "B739", "A319", "E190",
                        "A333", "A359", "B789", "B77W", "B788", "A388", "B744", "CRJ9", "AT76"]
}
