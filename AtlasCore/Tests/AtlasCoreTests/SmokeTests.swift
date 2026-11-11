import XCTest
import AtlasCore

final class SmokeTests: XCTestCase {
    func testModels() {
        let p = Place(name: "X", coordinate: .init(latitude: 1, longitude: 2))
        XCTAssertEqual(p.name, "X")
    }
    @MainActor
    func testStoreSeed() async throws {
        let store = InMemoryAtlasStore(seed: true)
        await store.waitUntilReady()
        let walks = try await store.fetchWalkMonths()
        XCTAssertFalse(walks.isEmpty)
        let places = try await store.fetchPlaces()
        XCTAssertGreaterThanOrEqual(places.count, 2)
        let flights = try await store.fetchFlights()
        XCTAssertGreaterThanOrEqual(flights.count, 1)
        let page = try await store.fetchRouteSummaryPage(limit: 10, before: nil, in: nil, filter: nil)
        let first = try XCTUnwrap(page.summaries.first)
        let route = try await store.fetchRoute(id: first.id)
        XCTAssertGreaterThan(route?.locations.count ?? 0, 10)
    }
    @MainActor
    func testCLIPath() async {
        let store = InMemoryAtlasStore(seed: true)
        let (tree, tabs) = makeAtlasTree(store: store)
        await tabs.walks.refresh(force: true)
        XCTAssertEqual(tree.focused.name, "Walks")
    }
}