import Foundation
import Combine
import GeoCore

public enum AtlasMapStyle: String, Codable, CaseIterable, Sendable {
    case midnight
    case terrain
    case hybrid
    case imagery

    public var title: String {
        switch self {
        case .midnight: "Midnight"
        case .terrain: "Terrain"
        case .hybrid: "Hybrid"
        case .imagery: "Satellite"
        }
    }
}

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
    @Published public private(set) var revision: Int = 0
    @Published public private(set) var cameraAnimation: Bool = true
    private var lastFocusedRegion: GeoRegion?

    public init(state: State = State()) {
        self.state = state
    }

    public var region: GeoRegion { state.region }
    public var style: AtlasMapStyle { state.style }
    public var is3D: Bool { state.is3D }

    public func focus(
        on points: [GeoCoordinate],
        padding: Double = 1.4,
        verticalBias: Double = 0,
        animated: Bool = true
    ) {
        guard var fitted = GeoRegion.fitting(points, padding: padding) else { return }
        if verticalBias != 0 {
            fitted.center.latitude = min(
                max(
                    fitted.center.latitude + fitted.latitudeDelta * verticalBias,
                    -85
                ),
                85
            )
        }
        state.region = fitted
        state.heading = 0
        lastFocusedRegion = fitted
        cameraAnimation = animated
        bump()
    }

    public func zoom(by factor: Double) {
        let clamped = min(max(factor, 0.25), 4)
        state.region.latitudeDelta = clamp(
            state.region.latitudeDelta / clamped,
            0.0008,
            120
        )
        state.region.longitudeDelta = clamp(
            state.region.longitudeDelta / clamped,
            0.0008,
            340
        )
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

    public func sync(region: GeoRegion, pitch: Double, heading: Double) {
        state.region = region
        state.pitch = pitch
        state.heading = heading
        state.is3D = pitch > 1
    }

    public func send(_ action: Action) {
        switch action {
        case .focus(let points):
            focus(on: points)
        case .zoom(let factor):
            zoom(by: factor)
        case .setStyle(let style):
            setStyle(style)
        case .cycleStyle:
            cycleStyle()
        case .toggle3D:
            toggle3D()
        case .set3D(let enabled):
            set3D(enabled)
        case .tilt(let degrees):
            state.pitch = clamp(degrees, 0, 75)
            state.is3D = state.pitch > 1
            bump()
        case .reset:
            reset()
        case .sync(let region, let pitch, let heading):
            sync(region: region, pitch: pitch, heading: heading)
        }
    }

    private func bump() {
        revision &+= 1
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
