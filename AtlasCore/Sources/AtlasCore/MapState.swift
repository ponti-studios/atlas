import Foundation
import CoreLocation

// MARK: - Geography (UI-free)

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    /// Great-circle distance in metres.
    public func distance(to other: GeoCoordinate) -> Double {
        let earth = 6_371_000.0
        let φ1 = latitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let dφ = (other.latitude - latitude) * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return earth * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing in degrees, 0 = north, clockwise.
    public func bearing(to other: GeoCoordinate) -> Double {
        let φ1 = latitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Points along the great circle from here to `other`.
    public func greatCircle(to other: GeoCoordinate, steps: Int = 48) -> [GeoCoordinate] {
        guard isValid, other.isValid else { return [self, other] }
        let count = max(2, steps)
        let φ1 = latitude * .pi / 180
        let λ1 = longitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let λ2 = other.longitude * .pi / 180
        let d = 2 * asin(sqrt(pow(sin((φ2 - φ1) / 2), 2) + cos(φ1) * cos(φ2) * pow(sin((λ2 - λ1) / 2), 2)))
        guard d > 1e-9 else { return [self, other] }

        return (0...count).map { i in
            let f = Double(i) / Double(count)
            let a = sin((1 - f) * d) / sin(d)
            let b = sin(f * d) / sin(d)
            let x = a * cos(φ1) * cos(λ1) + b * cos(φ2) * cos(λ2)
            let y = a * cos(φ1) * sin(λ1) + b * cos(φ2) * sin(λ2)
            let z = a * sin(φ1) + b * sin(φ2)
            let φ = atan2(z, sqrt(x * x + y * y))
            let λ = atan2(y, x)
            return GeoCoordinate(latitude: φ * 180 / .pi, longitude: λ * 180 / .pi)
        }
    }
}

public struct GeoRegion: Codable, Hashable, Sendable {
    public var center: GeoCoordinate
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(center: GeoCoordinate, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    public static let london = GeoRegion(
        center: GeoCoordinate(latitude: 51.5074, longitude: -0.1278),
        latitudeDelta: 0.14,
        longitudeDelta: 0.20
    )

    public static func fitting(_ points: [GeoCoordinate], padding: Double = 1.4, minimumDelta: Double = 0.004) -> GeoRegion? {
        let valid = points.filter(\.isValid)
        guard let first = valid.first else { return nil }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in valid.dropFirst() {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }

        let center = GeoCoordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        var latitudeDelta = max((maxLat - minLat) * padding, minimumDelta)
        var longitudeDelta = max((maxLon - minLon) * padding, minimumDelta)

        // Keep a comfortable landscape aspect ratio for the region.
        if longitudeDelta < latitudeDelta * 1.35 {
            longitudeDelta = latitudeDelta * 1.35
        }

        latitudeDelta = min(latitudeDelta, 160)
        longitudeDelta = min(longitudeDelta, 340)
        return GeoRegion(center: center, latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
}

// MARK: - Map style

public enum AtlasMapStyle: String, Codable, CaseIterable, Sendable {
    case midnight
    case terrain
    case hybrid
    case imagery

    public var title: String {
        switch self {
        case .midnight: return "Midnight"
        case .terrain: return "Terrain"
        case .hybrid: return "Hybrid"
        case .imagery: return "Satellite"
        }
    }
}

// MARK: - Map ViewModel

@MainActor
public final class MapViewModel: ObservableObject {
    public struct State: Equatable, Codable, Sendable {
        public var region: GeoRegion
        public var style: AtlasMapStyle
        public var pitch: Double
        public var heading: Double
        public var is3D: Bool

        public init(
            region: GeoRegion = .london,
            style: AtlasMapStyle = .midnight,
            pitch: Double = 0,
            heading: Double = 0,
            is3D: Bool = false
        ) {
            self.region = region
            self.style = style
            self.pitch = pitch
            self.heading = heading
            self.is3D = is3D
        }
    }

    public enum Action: Equatable, Sendable {
        case focus([GeoCoordinate])
        case zoom(by: Double)
        case setStyle(AtlasMapStyle)
        case cycleStyle
        case toggle3D
        case set3D(Bool)
        case tilt(Double)
        case reset
        case sync(GeoRegion, pitch: Double, heading: Double)
    }

    @Published public private(set) var state: State
    /// Bumped only by explicit camera commands, so map gestures never fight the UI.
    @Published public private(set) var revision: Int = 0
    /// Whether the next revision should animate. Tab switches and 3D toggles
    /// snap; they are not a journey the user asked to watch.
    @Published public private(set) var cameraAnimation: Bool = true
    /// The last explicit camera fit. `reset()` returns here rather than to a
    /// hard-coded London view, so the worldwide walks archive stays on screen.
    private var lastFocusedRegion: GeoRegion?

    public init(state: State = State()) {
        self.state = state
    }

    public var region: GeoRegion { state.region }
    public var style: AtlasMapStyle { state.style }
    public var is3D: Bool { state.is3D }

    /// - Parameter verticalBias: fraction of the latitude span to shift the camera centre.
    ///   Negative values move the centre south, lifting content above a bottom sheet.
    public func focus(
        on points: [GeoCoordinate],
        padding: Double = 1.4,
        verticalBias: Double = 0,
        animated: Bool = true
    ) {
        guard var fitted = GeoRegion.fitting(points, padding: padding) else { return }
        if verticalBias != 0 {
            fitted.center.latitude = min(max(fitted.center.latitude + fitted.latitudeDelta * verticalBias, -85), 85)
        }
        state.region = fitted
        state.heading = 0
        lastFocusedRegion = fitted
        cameraAnimation = animated
        bump()
    }

    public func zoom(by factor: Double) {
        let clamped = min(max(factor, 0.25), 4)
        state.region.latitudeDelta = clamp(state.region.latitudeDelta / clamped, 0.0008, 120)
        state.region.longitudeDelta = clamp(state.region.longitudeDelta / clamped, 0.0008, 340)
        bump()
    }

    public func setStyle(_ style: AtlasMapStyle) {
        state.style = style
        bump()
    }

    public func cycleStyle() {
        let all = AtlasMapStyle.allCases
        let index = all.firstIndex(of: state.style) ?? 0
        state.style = all[(index + 1) % all.count]
        bump()
    }

    public func set3D(_ enabled: Bool, animated: Bool = true) {
        state.is3D = enabled
        state.pitch = enabled ? 52 : 0
        cameraAnimation = animated
        bump()
    }

    public func toggle3D() {
        set3D(!state.is3D, animated: false)
    }

    public func reset() {
        let style = state.style
        state = State(region: lastFocusedRegion ?? .london, style: style)
        bump()
    }

    /// Reflect a user gesture back into state without triggering a camera re-apply.
    public func sync(region: GeoRegion, pitch: Double, heading: Double) {
        state.region = region
        state.pitch = pitch
        state.heading = heading
        state.is3D = pitch > 1
    }

    public func send(_ action: Action) {
        switch action {
        case .focus(let points): focus(on: points)
        case .zoom(let factor): zoom(by: factor)
        case .setStyle(let style): setStyle(style)
        case .cycleStyle: cycleStyle()
        case .toggle3D: toggle3D()
        case .set3D(let enabled): set3D(enabled)
        case .tilt(let degrees):
            state.pitch = clamp(degrees, 0, 75)
            state.is3D = state.pitch > 1
            bump()
        case .reset: reset()
        case .sync(let region, let pitch, let heading): sync(region: region, pitch: pitch, heading: heading)
        }
    }

    private func bump() { revision &+= 1 }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

// MARK: - Airport lookup (flight arcs)

public enum AirportCatalog {
    public static let all: [String: GeoCoordinate] = [
        "LHR": GeoCoordinate(latitude: 51.4700, longitude: -0.4543),
        "LGW": GeoCoordinate(latitude: 51.1537, longitude: -0.1821),
        "JFK": GeoCoordinate(latitude: 40.6413, longitude: -73.7781),
        "EWR": GeoCoordinate(latitude: 40.6895, longitude: -74.1745),
        "LAX": GeoCoordinate(latitude: 33.9416, longitude: -118.4085),
        "SFO": GeoCoordinate(latitude: 37.6213, longitude: -122.3790),
        "ORD": GeoCoordinate(latitude: 41.9742, longitude: -87.9073),
        "CDG": GeoCoordinate(latitude: 49.0097, longitude: 2.5479),
        "AMS": GeoCoordinate(latitude: 52.3105, longitude: 4.7683),
        "FRA": GeoCoordinate(latitude: 50.0379, longitude: 8.5622),
        "BCN": GeoCoordinate(latitude: 41.2974, longitude: 2.0833),
        "FCO": GeoCoordinate(latitude: 41.8003, longitude: 12.2389),
        "DXB": GeoCoordinate(latitude: 25.2532, longitude: 55.3657),
        "HND": GeoCoordinate(latitude: 35.5494, longitude: 139.7798),
        "SIN": GeoCoordinate(latitude: 1.3644, longitude: 103.9915),
        "SYD": GeoCoordinate(latitude: -33.9399, longitude: 151.1753),
        "GRU": GeoCoordinate(latitude: -23.4356, longitude: -46.4731),
        "CPT": GeoCoordinate(latitude: -33.9715, longitude: 18.6021),
    ]

    public static func coordinate(for code: String) -> GeoCoordinate? {
        all[code.uppercased()]
    }
}
