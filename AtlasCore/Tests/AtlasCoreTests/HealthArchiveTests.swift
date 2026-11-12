import XCTest
import CoreLocation
@testable import AtlasCore

final class HealthArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func locations(_ count: Int) -> [RouteLocation] {
        (0..<count).map {
            RouteLocation(
                latitude: 51.5 + Double($0) / 10_000,
                longitude: -0.12,
                elevation: 10,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0))
            )
        }
    }

    private func workout(id: UUID = UUID(), points: Int, activity: String = "walking") -> HealthWorkout {
        HealthWorkout(
            id: id,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            activity: activity,
            locations: locations(points)
        )
    }

    // MARK: - Conversion

    func testWorkoutWithRouteBecomesAWalkAndARoute() {
        let archive = HealthWalkArchive.merging([workout(points: 12)], into: HealthWalkArchive())
        XCTAssertEqual(archive.walks.count, 1)
        XCTAssertEqual(archive.routes.count, 1)
        XCTAssertEqual(archive.walks[0].hasGPSRoute, true)
        XCTAssertEqual(archive.walks[0].activity, "walking")
        XCTAssertEqual(archive.routes[0].locations.count, 12)
    }

    func testSummaryCarriesGeometrySoLaunchDoesNotScan() {
        let archive = HealthWalkArchive.merging([workout(points: 12)], into: HealthWalkArchive())
        let walk = archive.walks[0]
        XCTAssertNotNil(walk.bounds, "the map needs bounds without reading the route")
        XCTAssertEqual(walk.pointCount, 12)
        XCTAssertNotNil(walk.distanceMeters)
        XCTAssertGreaterThan(walk.distanceMeters ?? 0, 0)
    }

    func testBackfillRepairsAnArchiveWrittenBeforeGeometryFacts() {
        let archive = HealthWalkArchive.merging([workout(points: 5)], into: HealthWalkArchive())
        let legacy = HealthWalkArchive(
            walks: [WalkRouteSummary(id: archive.walks[0].id,
                                     startDate: archive.walks[0].startDate,
                                     endDate: archive.walks[0].endDate,
                                     hasGPSRoute: true)],
            routes: archive.routes
        )
        XCTAssertNil(legacy.walks[0].bounds)

        let filled = legacy.withGeometryFilled()
        XCTAssertNotNil(filled)
        XCTAssertNotNil(filled?.walks[0].bounds)
        XCTAssertEqual(filled?.walks[0].pointCount, 5)
        XCTAssertNil(filled?.withGeometryFilled(), "a repaired archive needs no second pass")
    }

    func testWorkoutWithoutRouteStaysInTheList() {
        let archive = HealthWalkArchive.merging([workout(points: 0)], into: HealthWalkArchive())
        XCTAssertEqual(archive.walks.count, 1, "a walk recorded without location still happened")
        XCTAssertEqual(archive.walks[0].hasGPSRoute, false)
        XCTAssertTrue(archive.routes.isEmpty)
    }

    func testResyncReplacesTheSameWorkout() {
        let id = UUID()
        let first = HealthWalkArchive.merging([workout(id: id, points: 3)], into: HealthWalkArchive())
        let second = HealthWalkArchive.merging([workout(id: id, points: 9)], into: first)

        XCTAssertEqual(second.walks.count, 1)
        XCTAssertEqual(second.routes.count, 1)
        XCTAssertEqual(second.routes[0].locations.count, 9)
    }

    func testSyncKeepsWalksOutsideItsWindow() {
        let older = workout(points: 4)
        let archive = HealthWalkArchive.merging([older], into: HealthWalkArchive())
        // A later sync that fetched a different workout must not drop the first.
        let next = HealthWalkArchive.merging([workout(points: 5)], into: archive)
        XCTAssertEqual(next.walks.count, 2)
    }

    // MARK: - Persistence

    func testArchiveRoundTripsThroughDisk() throws {
        let url = root.appendingPathComponent("atlas-health.json")
        let archive = HealthWalkArchive.merging([workout(points: 6)], into: HealthWalkArchive())
        try archive.write(to: url)

        let loaded = HealthWalkArchive.load(from: url)
        XCTAssertEqual(loaded.walks.count, 1)
        XCTAssertEqual(loaded.routes.count, 1)
        XCTAssertNotNil(loaded.lastSyncedAt)
    }

    func testMissingFileLoadsAsAnEmptyArchive() {
        let loaded = HealthWalkArchive.load(from: root.appendingPathComponent("nope.json"))
        XCTAssertTrue(loaded.walks.isEmpty)
    }

    // MARK: - Progress

    func testProgressReportsRealCountsAndClamps() {
        let progress = HealthSyncProgress(completed: 12, total: 951)
        XCTAssertEqual(progress.fraction, 12.0 / 951.0, accuracy: 0.0001)
        XCTAssertEqual(progress.summary, "Syncing 12 of 951")
        XCTAssertFalse(progress.isComplete)

        let done = HealthSyncProgress(completed: 951, total: 951)
        XCTAssertEqual(done.fraction, 1)
        XCTAssertTrue(done.isComplete)

        let unknown = HealthSyncProgress(completed: 0, total: 0)
        XCTAssertEqual(unknown.fraction, 0, "no total yet is not a divide by zero")
        XCTAssertEqual(unknown.summary, "Reading your workouts…")
    }

    // MARK: - Store merge
    @MainActor
    func testStoreMergesHealthWalksIntoTheSnapshot() async throws {
        let snapshotURL = root.appendingPathComponent("atlas-data.json")
        let base = AtlasData(
            walks: [WalkRouteSummary(id: UUID(), startDate: .distantPast, endDate: .distantPast,
                                     hasGPSRoute: true, title: "Imported", activity: "walking")]
        )
        try AtlasImporter.write(base, to: snapshotURL)

        let health = HealthWalkArchive.merging([workout(points: 5)], into: HealthWalkArchive())
        try health.write(to: HealthWalkArchive.url(beside: snapshotURL))

        let store = FileAtlasStore(url: snapshotURL)
        await store.waitUntilReady()
        let page = try await store.fetchRouteSummaryPage(limit: 10, before: nil, in: nil, filter: nil)

        XCTAssertEqual(page.summaries.count, 2)
        XCTAssertEqual(page.summaries.first?.startDate, health.walks.first?.startDate,
                       "the freshly synced walk is the newest, so it sorts first")
    }
}
