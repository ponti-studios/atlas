import XCTest
import CoreLocation
@testable import AtlasCore

/// Route culling: only the walks that touch the viewport go to MapKit.
final class ViewportCullingTests: XCTestCase {
    private func bounds(lat: Double, lon: Double, spread: Double = 0.01) -> GeoBounds {
        GeoBounds(points: [
            GeoCoordinate(latitude: lat - spread, longitude: lon - spread),
            GeoCoordinate(latitude: lat + spread, longitude: lon + spread),
        ])!
    }

    // MARK: - Viewport

    func testViewportCoversTheVisibleSpanWithMargin() {
        let viewport = GeoBounds.viewport(
            center: GeoCoordinate(latitude: 51.5, longitude: -0.12),
            latitudeDelta: 0.1,
            longitudeDelta: 0.2
        )
        XCTAssertLessThan(viewport.minLatitude, 51.5 - 0.05)
        XCTAssertGreaterThan(viewport.maxLatitude, 51.5 + 0.05)
        XCTAssertLessThan(viewport.minLongitude, -0.12 - 0.10)
        XCTAssertGreaterThan(viewport.maxLongitude, -0.12 + 0.10)
    }

    func testViewportIsClampedToTheEarth() {
        let viewport = GeoBounds.viewport(
            center: GeoCoordinate(latitude: 89.9, longitude: 179.9),
            latitudeDelta: 1.0,
            longitudeDelta: 1.0
        )
        XCTAssertLessThanOrEqual(viewport.maxLatitude, 90)
        XCTAssertGreaterThanOrEqual(viewport.minLatitude, -90)
    }

    // MARK: - Overlap

    func testRouteInsideTheViewportIsVisible() {
        let viewport = GeoBounds.viewport(
            center: GeoCoordinate(latitude: 51.5, longitude: -0.12),
            latitudeDelta: 0.1,
            longitudeDelta: 0.1
        )
        XCTAssertTrue(bounds(lat: 51.51, lon: -0.11).intersects(viewport))
    }

    func testRouteOnAnotherContinentIsCulled() {
        let viewport = GeoBounds.viewport(
            center: GeoCoordinate(latitude: 51.5, longitude: -0.12),
            latitudeDelta: 0.1,
            longitudeDelta: 0.1
        )
        XCTAssertFalse(bounds(lat: 34.05, lon: -118.25).intersects(viewport), "a Los Angeles walk is not on screen in London")
    }

    func testExpandedByKilometresGrowsEveryEdge() {
        let base = bounds(lat: 51.5, lon: -0.12, spread: 0.01)
        let grown = base.expanded(byKilometers: 50)
        XCTAssertEqual(grown.minLatitude, base.minLatitude - 0.449, accuracy: 0.01, "50 km is about 0.45° of latitude")
        XCTAssertEqual(grown.maxLatitude, base.maxLatitude + 0.449, accuracy: 0.01)
        XCTAssertLessThan(grown.minLongitude, base.minLongitude)
        XCTAssertGreaterThan(grown.maxLongitude, base.maxLongitude)
    }

    func testCornersFrameTheBounds() {
        let base = bounds(lat: 51.5, lon: -0.12)
        XCTAssertEqual(base.corners.count, 4)
        XCTAssertEqual(base.corners.map(\.latitude).min(), base.minLatitude)
        XCTAssertEqual(base.corners.map(\.longitude).max(), base.maxLongitude)
    }

    func testRouteNearTheDatelineOverlapsAViewportThere() {        let fiji = GeoBounds(points: [
            GeoCoordinate(latitude: -17.0, longitude: 179.9),
            GeoCoordinate(latitude: -17.1, longitude: -179.9),
        ])!
        let viewport = GeoBounds.viewport(
            center: GeoCoordinate(latitude: -17.0, longitude: 180),
            latitudeDelta: 0.5,
            longitudeDelta: 0.5
        )
        XCTAssertTrue(fiji.intersects(viewport))
        XCTAssertFalse(bounds(lat: 51.5, lon: -0.12).intersects(viewport), "London is not on screen in Fiji")
    }
}
