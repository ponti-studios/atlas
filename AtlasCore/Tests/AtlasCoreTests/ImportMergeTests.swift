import XCTest
@testable import AtlasCore

/// An Apple Health export nests its routes, and a second import must add to the
/// archive rather than replace it.
final class ImportMergeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func writeRoute(named name: String, in folder: URL, start: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AtlasTests">
          <trk><trkseg>
            <trkpt lat="51.5000" lon="-0.1200"><ele>10</ele><time>\(start)</time></trkpt>
            <trkpt lat="51.5010" lon="-0.1210"><ele>11</ele><time>\(start)</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Discovery

    func testFindsRoutesNestedInAHealthExport() throws {
        let routes = root.appendingPathComponent("apple_health_export/workout-routes", isDirectory: true)
        _ = try writeRoute(named: "route_2026-03-01_9.00am.gpx", in: routes, start: "2026-03-01T09:00:00Z")

        let (data, report) = try AtlasImporter.build(gpxDirectory: root)
        XCTAssertEqual(report.walks, 1)
        XCTAssertEqual(data.routes.count, 1)
    }

    func testFindsRoutesAcrossNestedYearFolders() throws {
        _ = try writeRoute(named: "a.gpx", in: root.appendingPathComponent("2024"), start: "2024-05-01T08:00:00Z")
        _ = try writeRoute(named: "b.gpx", in: root.appendingPathComponent("2025"), start: "2025-05-01T08:00:00Z")

        let (data, _) = try AtlasImporter.build(gpxDirectory: root)
        XCTAssertEqual(data.routes.count, 2)
        // Newest first, so the first card is the most recent walk.
        XCTAssertGreaterThan(data.walks[0].startDate, data.walks[1].startDate)
    }

    // MARK: - Health export layout

    func testRoutesDirectoryFindsWorkoutRoutes() throws {
        let routes = root.appendingPathComponent("apple_health_export/workout-routes", isDirectory: true)
        try FileManager.default.createDirectory(at: routes, withIntermediateDirectories: true)
        XCTAssertEqual(HealthExport.routesDirectory(in: root).standardizedFileURL, routes.standardizedFileURL)
    }

    func testRoutesDirectoryFallsBackToTheFolderItself() {
        XCTAssertEqual(HealthExport.routesDirectory(in: root).standardizedFileURL, root.standardizedFileURL)
    }

    // MARK: - Merging

    func testMergeKeepsExistingItemsAndAddsNewOnes() throws {
        let existing = AtlasData(
            walks: [WalkRouteSummary(id: UUID(), startDate: .distantPast, endDate: .distantPast, hasGPSRoute: true, title: "Old", activity: "walking")],
            places: [Place(id: UUID(), name: "Kept place", coordinate: .init(latitude: 1, longitude: 1), note: "", createdAt: .distantPast)],
            stations: []
        )
        let fresh = AtlasData(
            walks: [WalkRouteSummary(id: UUID(), startDate: .now, endDate: .now, hasGPSRoute: true, title: "New", activity: "walking")],
            flights: [Flight(id: UUID(), number: "BA1", origin: "LHR", destination: "JFK",
                             departure: .now, arrival: .now,
                             originCoordinate: .init(latitude: 51.47, longitude: -0.45),
                             destinationCoordinate: .init(latitude: 40.64, longitude: -73.78))]
        )

        let merged = existing.merged(with: fresh)
        XCTAssertEqual(merged.walks.count, 2)
        XCTAssertEqual(merged.places.count, 1, "a route-only import must not drop the places archive")
        XCTAssertEqual(merged.flights.count, 1, "a route-only import must not drop flights")
    }

    func testMergeReplacesTheSameIdWithTheFreshCopy() throws {
        let id = UUID()
        let old = AtlasData(walks: [WalkRouteSummary(id: id, startDate: .distantPast, endDate: .distantPast,
                                                     hasGPSRoute: true, title: "Old", activity: "walking")])
        let new = AtlasData(walks: [WalkRouteSummary(id: id, startDate: .now, endDate: .now,
                                                     hasGPSRoute: true, title: "Updated", activity: "walking")])

        let merged = old.merged(with: new)
        XCTAssertEqual(merged.walks.count, 1)
        XCTAssertEqual(merged.walks[0].title, "Updated")
    }
}
