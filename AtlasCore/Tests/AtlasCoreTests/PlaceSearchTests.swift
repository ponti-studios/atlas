import XCTest
import CoreLocation
@testable import AtlasCore

/// A search stub: the view model never talks to MapKit directly, so the
/// behaviour can be proven without a network.
private struct StubSearcher: PlaceSearching {
    var results: [PlaceSearchResult] = []
    var error: Error?

    func search(_ query: String, near: GeoCoordinate?, limit: Int) async throws -> [PlaceSearchResult] {
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

final class PlaceSearchTests: XCTestCase {
    private func result(_ name: String, _ lat: Double, _ lon: Double) -> PlaceSearchResult {
        PlaceSearchResult(name: name, address: "1 Test Street", category: "cafe",
                          coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @MainActor
    func testSearchPopulatesResults() async {
        let store = InMemoryAtlasStore(seed: false)
        let searcher = StubSearcher(results: [result("Blue Bottle", 51.5, -0.1)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("blue bottle")

        XCTAssertEqual(vm.results.count, 1)
        XCTAssertEqual(vm.results.first?.name, "Blue Bottle")
        XCTAssertEqual(vm.query, "blue bottle")
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testBlankQueryClearsResults() async {
        let store = InMemoryAtlasStore(seed: false)
        let searcher = StubSearcher(results: [result("Blue Bottle", 51.5, -0.1)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("blue bottle")
        await vm.search("   ")

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testFailedSearchReportsTheError() async {
        let store = InMemoryAtlasStore(seed: false)
        let searcher = StubSearcher(error: PlaceSearchError.noResults)
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("nowhere")

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(vm.errorMessage, PlaceSearchError.noResults.localizedDescription)
    }

    @MainActor
    func testSavingAResultAddsItToThePlaces() async {
        let store = InMemoryAtlasStore(seed: false)
        let searcher = StubSearcher(results: [result("Blue Bottle", 51.5, -0.1)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("blue bottle")
        let saved = await vm.save(resultAt: 0)

        XCTAssertNotNil(saved)
        XCTAssertEqual(vm.places.count, 1)
        XCTAssertEqual(vm.places.first?.name, "Blue Bottle")
        XCTAssertTrue(vm.isSaved(vm.results[0]))
    }

    @MainActor
    func testSavingTheSamePlaceTwiceUpdatesIt() async {
        let store = InMemoryAtlasStore(seed: false)
        let searcher = StubSearcher(results: [result("Blue Bottle", 51.5, -0.1)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("blue bottle")
        let first = await vm.save(resultAt: 0)
        let second = await vm.save(resultAt: 0)

        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(vm.places.count, 1)
    }

    @MainActor
    func testSavingAPlaceTheArchiveAlreadyHoldsUpdatesIt() async throws {
        let store = InMemoryAtlasStore(seed: false)
        // The archive holds the same door, with a slightly different coordinate.
        let archived = Place(
            id: StableID.uuid("place|bermondsey street|51.50311|-0.08277"),
            name: "Bermondsey Street",
            coordinate: CLLocationCoordinate2D(latitude: 51.5031102, longitude: -0.0827701)
        )
        try await store.savePlace(archived)
        let searcher = StubSearcher(results: [result("Bermondsey Street", 51.50311, -0.08277)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("bermondsey street")
        let saved = await vm.save(resultAt: 0)

        XCTAssertEqual(saved?.id, archived.id)
        XCTAssertEqual(vm.places.count, 1)
    }

    @MainActor
    func testADifferentPlaceIsNotTreatedAsTheSameOne() async throws {
        let store = InMemoryAtlasStore(seed: false)
        let archived = Place(
            name: "Bermondsey Street",
            coordinate: CLLocationCoordinate2D(latitude: 51.50311, longitude: -0.08277)
        )
        try await store.savePlace(archived)
        let searcher = StubSearcher(results: [result("Bermondsey Street", 52.5, -0.08)])
        let vm = PlacesViewModel(store: store, searcher: searcher)

        await vm.search("bermondsey street")
        await vm.save(resultAt: 0)

        XCTAssertEqual(vm.places.count, 2)
    }

    func testResultIdentityIsStable() {        let a = PlaceSearchResult(name: "Blue Bottle", address: "1 Test Street", category: "cafe",
                                  coordinate: CLLocationCoordinate2D(latitude: 51.5000001, longitude: -0.1000001))
        let b = PlaceSearchResult(name: "Blue Bottle", address: "1 Test Street", category: "cafe",
                                  coordinate: CLLocationCoordinate2D(latitude: 51.5000002, longitude: -0.1000002))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.makePlace().id, b.makePlace().id)
    }

    func testDifferentPlacesHaveDifferentIdentities() {
        let a = PlaceSearchResult(name: "Blue Bottle", address: "", category: "",
                                  coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1))
        let b = PlaceSearchResult(name: "Blue Bottle", address: "", category: "",
                                  coordinate: CLLocationCoordinate2D(latitude: 51.6, longitude: -0.1))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.makePlace().id, b.makePlace().id)
    }
}

// MARK: - Persistence

final class SavedPlacesStoreTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (FileAtlasStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshotURL = directory.appendingPathComponent("atlas-data.json")
        let imported = Place(
            id: StableID.uuid("place|imported|51.5|-0.1"),
            name: "Imported Place",
            coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
        )
        let data = AtlasData(places: [imported])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(data).write(to: snapshotURL)
        return (FileAtlasStore(url: snapshotURL), snapshotURL)
    }

    @MainActor
    func testSavedPlaceSurvivesANewStore() async throws {
        let (store, _) = try makeStore()
        let place = Place(name: "Blue Bottle", coordinate: CLLocationCoordinate2D(latitude: 51.51, longitude: -0.11))
        try await store.savePlace(place)

        // A fresh store over the same files is what a relaunch looks like.
        let reopened = FileAtlasStore(url: store.url, savedPlacesURL: store.savedPlacesURL)
        await reopened.waitUntilReady()
        let places = try await reopened.fetchPlaces()

        XCTAssertTrue(places.contains { $0.name == "Blue Bottle" })
        XCTAssertTrue(places.contains { $0.name == "Imported Place" })
    }

    @MainActor
    func testDeletingAnImportedPlaceHidesIt() async throws {
        let (store, _) = try makeStore()
        let imported = try await store.fetchPlaces().first { $0.name == "Imported Place" }
        let target = try XCTUnwrap(imported)

        try await store.deletePlace(id: target.id)

        let reopened = FileAtlasStore(url: store.url, savedPlacesURL: store.savedPlacesURL)
        await reopened.waitUntilReady()
        let places = try await reopened.fetchPlaces()
        XCTAssertFalse(places.contains { $0.id == target.id })
    }

    @MainActor
    func testSavingOverAnImportedPlaceReplacesIt() async throws {
        let (store, _) = try makeStore()
        let imported = try await store.fetchPlaces().first { $0.name == "Imported Place" }
        let target = try XCTUnwrap(imported)
        var edited = target
        edited.name = "Edited Place"

        try await store.savePlace(edited)

        let reopened = FileAtlasStore(url: store.url, savedPlacesURL: store.savedPlacesURL)
        await reopened.waitUntilReady()
        let places = try await reopened.fetchPlaces()
        XCTAssertEqual(places.filter { $0.id == target.id }.count, 1)
        XCTAssertEqual(places.first { $0.id == target.id }?.name, "Edited Place")
    }

    @MainActor
    func testDeletingASavedPlaceRemovesIt() async throws {
        let (store, _) = try makeStore()
        let place = Place(name: "Blue Bottle", coordinate: CLLocationCoordinate2D(latitude: 51.51, longitude: -0.11))
        try await store.savePlace(place)

        try await store.deletePlace(id: place.id)

        let reopened = FileAtlasStore(url: store.url, savedPlacesURL: store.savedPlacesURL)
        await reopened.waitUntilReady()
        let places = try await reopened.fetchPlaces()
        XCTAssertFalse(places.contains { $0.id == place.id })
    }
}
