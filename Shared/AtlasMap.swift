import SwiftUI
import MapKit
import CoreLocation
import AtlasCore

/// The Apple Maps base layer. Everything else floats above it.
struct AtlasMapCanvas: View {
    @ObservedObject var tabs: AtlasTabs
    @ObservedObject var map: MapViewModel
    var feature: AtlasFeature
    var selection: AtlasSelection?
    var walkOverlays: [WalkOverlay]
    var focusFlightID: UUID?
    var onSelect: (AtlasSelection) -> Void

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: GeoRegion.london.center.latitude,
                                           longitude: GeoRegion.london.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: GeoRegion.london.latitudeDelta,
                                   longitudeDelta: GeoRegion.london.longitudeDelta)
        )
    )

    // Render inputs are prepared off the body path. `body` must only read these.
    @State private var renderedRoutes: [RenderedRoute] = []
    @State private var renderedPlaces: [Place] = []
    @State private var renderedArcs: [FlightArc] = []
    @State private var cameraCells: [CameraCell] = []
    @State private var lastAppliedRegion: GeoRegion?
    @StateObject private var cameraDots = CameraDotTracker()

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                content
            }
            .mapStyle(map.state.style.mapStyle)
            .preferredColorScheme(.dark)
            .accessibilityIdentifier("atlas.map")
            .overlay {
                if feature == .cameras {
                    CameraDotCanvas(
                        cameras: tabs.cameras.cameras,
                        cells: cameraCells,
                        tracker: cameraDots,
                        proxy: proxy
                    )
                    .allowsHitTesting(false)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                map.sync(
                    region: GeoRegion(
                        center: GeoCoordinate(context.region.center),
                        latitudeDelta: context.region.span.latitudeDelta,
                        longitudeDelta: context.region.span.longitudeDelta
                    ),
                    pitch: context.camera.pitch,
                    heading: context.camera.heading
                )
            }
            .onMapCameraChange(frequency: .continuous) { context in
                cameraDots.update(
                    center: GeoCoordinate(context.region.center),
                    latitudeDelta: context.region.span.latitudeDelta,
                    longitudeDelta: context.region.span.longitudeDelta
                )
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                    guard feature == .cameras else { return }
                    let layer = CameraDotCanvas(
                        cameras: tabs.cameras.cameras,
                        cells: cameraCells,
                        tracker: cameraDots,
                        proxy: proxy
                    )
                    if let camera = layer.camera(at: value.location) {
                        onSelect(.camera(camera.id))
                    }
                }
            )
            .onChange(of: map.revision) { _, _ in
                applyCamera(animated: map.cameraAnimation)
            }
            .onChange(of: selection) { _, _ in
                refreshRoutes()
                refreshPlaces()
            }
            .onChange(of: map.state.region) { _, _ in
                // Route overlays deliberately do not depend on the camera: the
                // set stays stable so panning and zooming never inserts/removes
                // dozens of MapPolyline objects in one frame. Places are only
                // culled while the Places tab is actually visible.
                if feature == .places { refreshPlaces() }
            }
            .onChange(of: walkOverlays.map(\.id)) { _, _ in
                refreshRoutes()
            }
            .onChange(of: tabs.places.places.count) { _, _ in
                refreshPlaces()
            }
            .onChange(of: tabs.flights.flights.count) { _, _ in
                refreshArcs()
            }
            .onChange(of: tabs.cameras.cameras.count) { _, _ in
                rebuildCameraCells()
            }
            .onChange(of: feature) { _, _ in
                if feature == .cameras, cameraCells.isEmpty { rebuildCameraCells() }
                if feature == .places { refreshPlaces() }
            }
            .onAppear {
                AtlasPerformance.shared.mark("map.appeared")
                applyCamera(animated: false)
                refreshRoutes()
                refreshPlaces()
                refreshArcs()
                rebuildCameraCells()
            }
        }
    }

    // MARK: - Camera

    private func applyCamera(animated: Bool) {
        let region = map.state.region
        let center = CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude)
        let span = MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
        // A tab switch can move the camera across an ocean. Animating that flyover
        // makes MapKit stream a hemisphere of tiles and pins in one transaction.
        // Jump instantly when the move is large; animate the local moves.
        let animate = animated && shouldAnimate(from: lastAppliedRegion, to: region)
        lastAppliedRegion = region

        let update = {
            if map.state.pitch > 0.5 {
                let distance = max(420, region.latitudeDelta * 111_000 * 1.25)
                position = .camera(MapCamera(
                    centerCoordinate: center,
                    distance: distance,
                    heading: map.state.heading,
                    pitch: map.state.pitch
                ))
            } else {
                position = .region(MKCoordinateRegion(center: center, span: span))
            }
        }

        if animate {
            withAnimation(.easeInOut(duration: 0.85)) { update() }
        } else {
            update()
        }
    }

    private func shouldAnimate(from previous: GeoRegion?, to next: GeoRegion) -> Bool {
        guard let previous else { return false }
        let spanRatio = next.latitudeDelta / max(previous.latitudeDelta, 1e-9)
        guard spanRatio > 0.4, spanRatio < 2.5 else { return false }
        let moved = previous.center.distance(to: next.center)
        let previousSpan = previous.latitudeDelta * 111_000
        return moved < max(60_000, previousSpan * 2)
    }

    // MARK: - Render inputs

    @MainActor
    private func refreshRoutes() {
        let started = AtlasPerformance.shared.isSamplingEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let selectedID: UUID?
        if case .walk(let id)? = selection { selectedID = id } else { selectedID = nil }

        var routes: [RenderedRoute] = []
        routes.reserveCapacity(min(walkOverlays.count, 24))
        for overlay in walkOverlays {
            let isSelected = overlay.id == selectedID
            // The selected route is submitted at full detail. Everything else
            // uses the overview LOD, so the whole archive costs a few thousand
            // vertices and the overlay set never changes while the camera moves.
            routes.append(RenderedRoute(
                id: overlay.id,
                coordinates: isSelected ? overlay.coordinates : overlay.simplified,
                isSelected: isSelected
            ))
        }
        routes.sort { lhs, rhs in
            if lhs.isSelected != rhs.isSelected { return rhs.isSelected }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        renderedRoutes = routes

        if started > 0 {
            AtlasPerformance.shared.record(
                "ui.routes.build",
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            )
            AtlasPerformance.shared.increment("ui.routes.visible", by: Double(routes.count))
            AtlasPerformance.shared.increment("ui.route.vertices", by: Double(routes.reduce(0) { $0 + $1.coordinates.count }))
        }
    }

    /// The coverage grid is fixed to the whole camera network, not the camera.
    /// Rebuilding it on every pan/zoom was the main source of camera-page
    /// hitches; now only the selected camera pin and the map camera move.
    @MainActor
    private func rebuildCameraCells() {
        let cameras = tabs.cameras.cameras
        guard !cameras.isEmpty else {
            cameraCells = []
            return
        }

        let columns = 12
        let rows = 12
        let minLatitude = cameras.map(\.coordinate.latitude).min() ?? 51.3
        let maxLatitude = cameras.map(\.coordinate.latitude).max() ?? 51.7
        let minLongitude = cameras.map(\.coordinate.longitude).min() ?? -0.5
        let maxLongitude = cameras.map(\.coordinate.longitude).max() ?? 0.3
        let latitudeSpan = max(1e-9, maxLatitude - minLatitude)
        let longitudeSpan = max(1e-9, maxLongitude - minLongitude)
        var cells: [Int: (latitude: Double, longitude: Double, count: Int)] = [:]

        for camera in cameras {
            let x = min(columns - 1, max(0, Int((camera.coordinate.longitude - minLongitude) / longitudeSpan * Double(columns))))
            let y = min(rows - 1, max(0, Int((camera.coordinate.latitude - minLatitude) / latitudeSpan * Double(rows))))
            let key = y * columns + x
            let cell = cells[key]
            cells[key] = (
                cell?.latitude ?? camera.coordinate.latitude,
                cell?.longitude ?? camera.coordinate.longitude,
                (cell?.count ?? 0) + 1
            )
        }

        cameraCells = cells
            .map { key, value in
                CameraCell(
                    id: String(key),
                    coordinate: GeoCoordinate(latitude: value.latitude, longitude: value.longitude),
                    count: value.count
                )
            }
            .sorted { $0.id < $1.id }
        AtlasPerformance.shared.increment("ui.cameras.visible", by: Double(cameraCells.count))
    }

    @MainActor
    private func refreshPlaces() {
        let started = AtlasPerformance.shared.isSamplingEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let all = tabs.places.places
        let region = map.state.region
        let span = region.latitudeDelta
        let limit = span > 4 ? 30 : (span > 0.8 ? 50 : 80)

        var visible: [Place]
        if all.count <= limit {
            visible = all
        } else {
            let center = region.center
            let cosLatitude = cos(center.latitude * .pi / 180)
            // Rank in local degree space: one cosine instead of 1,550 haversines.
            visible = all
                .map { place -> (Place, Double) in
                    let dLat = place.coordinate.latitude - center.latitude
                    let dLon = (place.coordinate.longitude - center.longitude) * cosLatitude
                    return (place, dLat * dLat + dLon * dLon)
                }
                .sorted { $0.1 < $1.1 }
                .prefix(limit)
                .map(\.0)
            if case .place(let selectedID)? = selection,
               !visible.contains(where: { $0.id == selectedID }),
               let selected = all.first(where: { $0.id == selectedID }) {
                visible.append(selected)
            }
        }
        renderedPlaces = visible

        if started > 0 {
            AtlasPerformance.shared.record(
                "ui.places.cull",
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            )
            AtlasPerformance.shared.increment("ui.places.visible", by: Double(visible.count))
        }
    }

    @MainActor
    private func refreshArcs() {
        let started = AtlasPerformance.shared.isSamplingEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let arcs: [FlightArc] = tabs.flights.flights.compactMap { flight in
            guard let origin = flight.originCoordinate, let destination = flight.destinationCoordinate else { return nil }
            let path = origin.greatCircle(to: destination, steps: 72)
            guard let middle = path[safe: path.count / 2] else { return nil }
            return FlightArc(
                id: flight.id,
                flight: flight,
                coordinates: path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                midpoint: CLLocationCoordinate2D(latitude: middle.latitude, longitude: middle.longitude),
                bearing: origin.bearing(to: destination)
            )
        }
        renderedArcs = arcs

        if started > 0 {
            AtlasPerformance.shared.record(
                "ui.flight.arcs",
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            )
            AtlasPerformance.shared.increment("ui.arcs", by: Double(arcs.count))
        }
    }

    // MARK: - Map content

    @MapContentBuilder
    private var content: some MapContent {
        switch feature {
        case .walks:
            ForEach(renderedRoutes) { route in
                if route.isSelected {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(AtlasTheme.lime.opacity(0.32), lineWidth: 13)
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(AtlasTheme.lime, lineWidth: 3.5)
                } else {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(AtlasTheme.lime.opacity(0.55), lineWidth: 2)
                }
            }

            ForEach(selectedWalkEndpoints) { endpoint in
                Annotation(coordinate: endpoint.coordinate, anchor: .center) {
                    EndpointPin(title: endpoint.title, isStart: endpoint.isStart)
                } label: {
                    EmptyView()
                }
            }

        case .places:
            ForEach(renderedPlaces) { place in
                MapCircle(center: place.coordinate, radius: placeDotRadius)
                    .foregroundStyle(AtlasTheme.cyan.opacity(selection == .place(place.id) ? 0.95 : 0.55))
                    .stroke(Color.white.opacity(selection == .place(place.id) ? 0.9 : 0.22), lineWidth: 0.5)
            }

            if case .place(let selectedID)? = selection,
               let place = renderedPlaces.first(where: { $0.id == selectedID }) {
                Annotation(coordinate: place.coordinate, anchor: .center) {
                    PlacePin(name: place.name, isSelected: true)
                } label: {
                    EmptyView()
                }
            }

        case .flights:
            ForEach(renderedArcs) { arc in
                let isSelected = selection == .flight(arc.flight.id)
                let isFocus = arc.flight.id == focusFlightID
                MapPolyline(coordinates: arc.coordinates)
                    .stroke(
                        AtlasTheme.violet.opacity(isSelected ? 0.95 : (isFocus ? 0.78 : 0.18)),
                        lineWidth: isSelected ? 3.5 : (isFocus ? 2.6 : 1.2)
                    )

                if isSelected || isFocus {
                    Annotation(coordinate: arc.midpoint, anchor: .center) {
                        FlightPin(flight: arc.flight, bearing: arc.bearing, isSelected: isSelected)
                            .onTapGesture { onSelect(.flight(arc.flight.id)) }
                    } label: {
                        EmptyView()
                    }
                }
            }

        case .parcels:
            ForEach(tabs.parcels.parcels) { parcel in
                if let location = parcel.lastLocation {
                    Annotation(coordinate: location, anchor: .center) {
                        ParcelPin(parcel: parcel, isSelected: selection == .parcel(parcel.id))
                            .onTapGesture { onSelect(.parcel(parcel.id)) }
                    } label: {
                        EmptyView()
                    }
                }
            }

        case .tfl:
            ForEach(tabs.tfl.stations) { station in
                Annotation(coordinate: station.coordinate, anchor: .center) {
                    StationPin(station: station, isSelected: selection == .station(station.id))
                        .onTapGesture { onSelect(.station(station.id)) }
                } label: {
                    EmptyView()
                }
            }

        case .cameras:
            // Coverage grid and street-level dots are drawn by CameraDotCanvas
            // above the map. Camera overlays would churn MapKit's whole content
            // set on every zoom level; a canvas costs one projected fill each.

            if case .camera(let id)? = selection,
               let camera = tabs.cameras.cameras.first(where: { $0.id == id }) {
                Annotation(coordinate: coordinate(of: camera), anchor: .center) {
                    CameraPin(camera: camera)
                } label: {
                    EmptyView()
                }
            }
        }
    }

    private func coordinate(of camera: JamCam) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: camera.coordinate.latitude, longitude: camera.coordinate.longitude)
    }

    // MARK: - Derived content

    /// Roughly 3 screen pixels at any zoom, derived from the latitude span.
    private var placeDotRadius: CLLocationDistance {
        max(4, map.state.region.latitudeDelta * 420)
    }

    private struct WalkEndpoint: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
        let isStart: Bool
    }

    private var selectedWalkEndpoints: [WalkEndpoint] {
        guard case .walk(let id)? = selection,
              let coordinates = walkOverlays.first(where: { $0.id == id })?.coordinates,
              let first = coordinates.first, let last = coordinates.last else { return [] }
        return [
            WalkEndpoint(id: "start", title: "START", coordinate: first, isStart: true),
            WalkEndpoint(id: "end", title: "FINISH", coordinate: last, isStart: false),
        ]
    }

    private struct FlightArc: Identifiable {
        let id: UUID
        let flight: Flight
        let coordinates: [CLLocationCoordinate2D]
        let midpoint: CLLocationCoordinate2D
        let bearing: Double
    }
}

// MARK: - Overlay model

struct WalkOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let simplified: [CLLocationCoordinate2D]
    let bounds: GeoBounds
}

struct RenderedRoute: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let isSelected: Bool
}

// MARK: - Pins

private struct EndpointPin: View {
    let title: String
    let isStart: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(AtlasTheme.lime.opacity(0.18)).frame(width: 26, height: 26)
                Circle().stroke(AtlasTheme.lime.opacity(0.7), lineWidth: 1).frame(width: 26, height: 26)
                Circle().fill(isStart ? AtlasTheme.lime : AtlasTheme.background).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(AtlasTheme.lime, lineWidth: isStart ? 0 : 1.5))
            }
            Text(title)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(AtlasTheme.lime, in: Capsule())
        }
    }
}

private struct PlacePin: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(AtlasTheme.cyan.opacity(isSelected ? 0.32 : 0.16))
                    .frame(width: isSelected ? 42 : 34, height: isSelected ? 42 : 34)
                Circle()
                    .stroke(AtlasTheme.cyan.opacity(0.75), lineWidth: 1)
                    .frame(width: isSelected ? 42 : 34, height: isSelected ? 42 : 34)
                Image(systemName: "mappin")
                    .font(.system(size: isSelected ? 16 : 12, weight: .black))
                    .foregroundStyle(AtlasTheme.cyan)
            }
            .shadow(color: AtlasTheme.cyan.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 12 : 0)

            Text(name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(AtlasTheme.cyan.opacity(0.35), lineWidth: 0.5))
        }
    }
}

private struct FlightPin: View {
    let flight: Flight
    let bearing: Double
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(AtlasTheme.violet.opacity(0.18))
                .frame(width: isSelected ? 46 : 38, height: isSelected ? 46 : 38)
            Circle()
                .stroke(AtlasTheme.violet.opacity(0.6), lineWidth: 1)
                .frame(width: isSelected ? 46 : 38, height: isSelected ? 46 : 38)
            Image(systemName: "airplane")
                .font(.system(size: isSelected ? 17 : 14, weight: .bold))
                .foregroundStyle(AtlasTheme.violet)
                .rotationEffect(.degrees(bearing - 90))
        }
        .shadow(color: AtlasTheme.violet.opacity(0.6), radius: isSelected ? 14 : 6)
        .overlay(alignment: .bottom) {
            Text(flight.number)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(AtlasTheme.background.opacity(0.75), in: Capsule())
                .offset(y: 18)
        }
    }
}

private struct ParcelPin: View {
    let parcel: Parcel
    let isSelected: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AtlasTheme.amber.opacity(0.5), lineWidth: 1)
                .frame(width: 52, height: 52)
                .scaleEffect(pulse ? 1.35 : 0.75)
                .opacity(pulse ? 0 : 0.9)
                .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)

            Circle()
                .fill(AtlasTheme.amber.opacity(isSelected ? 0.3 : 0.18))
                .frame(width: isSelected ? 42 : 36, height: isSelected ? 42 : 36)
            Circle()
                .stroke(AtlasTheme.amber.opacity(0.8), lineWidth: 1)
                .frame(width: isSelected ? 42 : 36, height: isSelected ? 42 : 36)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: isSelected ? 15 : 12, weight: .bold))
                .foregroundStyle(AtlasTheme.amber)
        }
        .shadow(color: AtlasTheme.amber.opacity(0.6), radius: 8)
        .onAppear { pulse = true }
    }
}

struct CameraCell: Identifiable {
    let id: String
    let coordinate: GeoCoordinate
    let count: Int
}

private struct CameraPin: View {
    let camera: JamCam

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(AtlasTheme.rose.opacity(0.2))
                    .frame(width: 42, height: 42)
                Circle()
                    .stroke(AtlasTheme.rose.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                Image(systemName: "video.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AtlasTheme.rose)
            }
            .shadow(color: AtlasTheme.rose.opacity(0.6), radius: 12)

            Text(camera.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(AtlasTheme.rose.opacity(0.4), lineWidth: 0.5))
        }
    }
}

private struct StationPin: View {
    let station: TFLStation
    let isSelected: Bool

    private var color: Color { TFLPalette.color(for: station.lines.first ?? "") }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(AtlasTheme.background.opacity(0.9))
                    .frame(width: isSelected ? 26 : 19, height: isSelected ? 26 : 19)
                Circle()
                    .stroke(color, lineWidth: isSelected ? 3.5 : 2.5)
                    .frame(width: isSelected ? 26 : 19, height: isSelected ? 26 : 19)
                Circle()
                    .fill(color)
                    .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
            }
            .shadow(color: color.opacity(0.7), radius: isSelected ? 10 : 4)

            if isSelected {
                Text(station.name)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

// MARK: - Camera overlay

/// Tracks the live map camera so the camera layer can cover the viewport
/// without asking SwiftUI to rebuild the whole map on every gesture frame.
@MainActor
final class CameraDotTracker: ObservableObject {
    @Published private(set) var region = GeoRegion.london

    func update(center: GeoCoordinate, latitudeDelta: Double, longitudeDelta: Double) {
        // A sub-pixel jitter publishes needlessly; 0.2% of the span is invisible.
        guard abs(latitudeDelta - region.latitudeDelta) > region.latitudeDelta * 0.002
            || abs(longitudeDelta - region.longitudeDelta) > region.longitudeDelta * 0.002
            || abs(center.latitude - region.center.latitude) > latitudeDelta * 0.0005
            || abs(center.longitude - region.center.longitude) > longitudeDelta * 0.0005
        else { return }
        region = GeoRegion(center: center, latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
}

/// The camera layer: a count-weighted coverage grid over the network, or the
/// cameras themselves once the map is close enough for street detail. Drawn
/// with projected canvas fills instead of MapKit overlays, so zooming never
/// inserts or removes eighty renderers in a single frame.
struct CameraDotCanvas: View {
    let cameras: [JamCam]
    let cells: [CameraCell]
    @ObservedObject var tracker: CameraDotTracker
    let proxy: MapProxy

    var body: some View {
        Canvas { context, _ in
            let region = tracker.region
            if region.latitudeDelta < CamerasViewModel.dotLayerMaximumSpan {
                drawDots(in: &context, region: region)
            } else {
                drawGrid(in: &context)
            }
        }
        .accessibilityHidden(true)
    }

    /// One projection for drawing and for hit-testing: a dot you can see is a
    /// dot you can click. `MapProxy.convert` is cheap enough to run again on a
    /// tap rather than caching screen positions between frames.
    func projectedDots(in region: GeoRegion) -> [(camera: JamCam, point: CGPoint)] {
        CamerasViewModel.dots(from: cameras, in: region).compactMap { camera in
            guard let point = proxy.convert(camera.coordinate.mapCoordinate, to: .local) else { return nil }
            return (camera, point)
        }
    }

    /// The camera under a tap, if any. The tolerance is generous relative to
    /// the 10 pt dot: a fingertip is not a cursor.
    func camera(at point: CGPoint, tolerance: CGFloat = 18) -> JamCam? {
        let region = tracker.region
        guard region.latitudeDelta < CamerasViewModel.dotLayerMaximumSpan else { return nil }

        var best: (camera: JamCam, distance: CGFloat)?
        for dot in projectedDots(in: region) {
            let distance = hypot(dot.point.x - point.x, dot.point.y - point.y)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (dot.camera, distance)
            }
        }
        return best?.camera
    }

    private func drawDots(in context: inout GraphicsContext, region: GeoRegion) {
        for dot in projectedDots(in: region) {
            let rect = CGRect(x: dot.point.x - 5, y: dot.point.y - 5, width: 10, height: 10)
            let path = Path(ellipseIn: rect)
            context.fill(
                path,
                with: .color(dot.camera.isAvailable ? AtlasTheme.rose : AtlasTheme.rose.opacity(0.32))
            )
            context.stroke(path, with: .color(.white.opacity(0.42)), lineWidth: 0.8)
        }
    }

    private func drawGrid(in context: inout GraphicsContext) {
        for cell in cells {
            guard let point = proxy.convert(cell.coordinate.mapCoordinate, to: .local) else { continue }
            let radius = 3 + min(4.5, 0.75 * Double(cell.count).squareRoot())
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(AtlasTheme.rose.opacity(min(0.62, 0.16 + 0.05 * Double(cell.count))))
            )
        }
    }
}

extension GeoCoordinate {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension AtlasMapStyle {
    var mapStyle: MapStyle {
        switch self {
        case .midnight:
            return .standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
        case .terrain:
            return .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        case .hybrid:
            return .hybrid(elevation: .realistic)
        case .imagery:
            return .imagery(elevation: .realistic)
        }
    }
}
