import XCTest
import AtlasCore

final class MapStateTests: XCTestCase {
    func testFittingASinglePointProducesAUsableRegion() {
        let point = GeoCoordinate(latitude: 51.5, longitude: -0.12)
        let region = GeoRegion.fitting([point])
        XCTAssertNotNil(region)
        XCTAssertEqual(region?.center.latitude ?? 0, 51.5, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(region?.latitudeDelta ?? 0, 0.004)
    }

    func testFittingKeepsWideSpansWide() {
        let london = AirportCatalog.coordinate(for: "LHR")!
        let newYork = AirportCatalog.coordinate(for: "JFK")!
        let region = GeoRegion.fitting([london, newYork])
        XCTAssertNotNil(region)
        XCTAssertGreaterThan(region?.longitudeDelta ?? 0, 30)
        XCTAssertGreaterThan(region?.latitudeDelta ?? 0, 5)
    }

    func testGreatCircleHitsBothEndpoints() {
        let london = AirportCatalog.coordinate(for: "LHR")!
        let newYork = AirportCatalog.coordinate(for: "JFK")!
        let arc = london.greatCircle(to: newYork, steps: 24)
        XCTAssertEqual(arc.count, 25)
        XCTAssertEqual(arc.first?.latitude ?? 0, london.latitude, accuracy: 0.001)
        XCTAssertEqual(arc.last?.latitude ?? 0, newYork.latitude, accuracy: 0.001)
        // A great-circle path bows away from the straight lat/lon line.
        let midpoints = arc.dropFirst().dropLast()
        XCTAssertTrue(midpoints.contains { $0.latitude > max(london.latitude, newYork.latitude) })
    }

    func testBearing() {
        let london = AirportCatalog.coordinate(for: "LHR")!
        let newYork = AirportCatalog.coordinate(for: "JFK")!
        let bearing = london.bearing(to: newYork)
        XCTAssertGreaterThan(bearing, 270)
        XCTAssertLessThan(bearing, 300)
    }

    @MainActor
    func testMapActions() {
        let map = MapViewModel()
        XCTAssertEqual(map.style, .midnight)
        XCTAssertFalse(map.is3D)

        let before = map.state.region.latitudeDelta
        map.send(.zoom(by: 2))
        XCTAssertLessThan(map.state.region.latitudeDelta, before)

        map.send(.toggle3D)
        XCTAssertTrue(map.state.is3D)
        XCTAssertGreaterThan(map.state.pitch, 0)

        map.send(.cycleStyle)
        XCTAssertNotEqual(map.style, .midnight)

        map.send(.focus([GeoCoordinate(latitude: 40.6, longitude: -73.8)]))
        XCTAssertEqual(map.state.region.center.latitude, 40.6, accuracy: 0.01)
        XCTAssertGreaterThan(map.revision, 0)
    }

    @MainActor
    func testSyncDoesNotBumpRevision() {
        let map = MapViewModel()
        let revision = map.revision
        map.send(.sync(GeoRegion.london, pitch: 0, heading: 0))
        XCTAssertEqual(map.revision, revision)
    }

    @MainActor
    func testMapActionsAreReachableFromActiveTab() async {
        let store = InMemoryAtlasStore(seed: true)
        let (tree, _) = makeAtlasTree(store: store)
        let titles = Set(tree.focused.actionTitles())
        XCTAssertTrue(titles.contains("MapZoomIn"))
        XCTAssertTrue(titles.contains("MapToggle3D"))
        XCTAssertTrue(titles.contains("MapCycleStyle"))
    }
}
