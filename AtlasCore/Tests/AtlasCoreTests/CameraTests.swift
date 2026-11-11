import XCTest
@testable import AtlasCore

final class CameraTests: XCTestCase {
    private let sample = """
    [
      {
        "id": "JamCams_00001.00001",
        "commonName": "Test Camera",
        "lat": 51.5000,
        "lon": -0.1200,
        "additionalProperties": [
          { "key": "available", "value": "true" },
          { "key": "view", "value": "North" },
          { "key": "imageUrl", "value": "https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/00001.00001.jpg" },
          { "key": "videoUrl", "value": "https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/00001.00001.mp4" }
        ]
      },
      {
        "id": "JamCams_00002.00002",
        "commonName": "Offline Camera",
        "lat": 51.6000,
        "lon": -0.2000,
        "additionalProperties": [
          { "key": "available", "value": "false" },
          { "key": "view", "value": "South" }
        ]
      },
      {
        "id": "JamCams_00003.00003",
        "commonName": "Bad Coordinate",
        "lat": 999,
        "lon": 0,
        "additionalProperties": []
      }
    ]
    """

    func testJamCamParserFiltersBadCoordinatesAndReadsProperties() throws {
        let cameras = try TFLJamCamClient.parse(Data(sample.utf8))
        XCTAssertEqual(cameras.count, 2)
        XCTAssertEqual(cameras.map(\.name), ["Offline Camera", "Test Camera"])

        let offline = try XCTUnwrap(cameras.first { $0.name == "Offline Camera" })
        XCTAssertFalse(offline.isAvailable)
        XCTAssertEqual(offline.view, "South")
        XCTAssertEqual(offline.imageURL?.lastPathComponent, "00002.00002.jpg", "missing imageUrl should use the S3 fallback")

        let live = try XCTUnwrap(cameras.first { $0.name == "Test Camera" })
        XCTAssertTrue(live.isAvailable)
        XCTAssertEqual(live.view, "North")
        XCTAssertEqual(live.videoURL?.lastPathComponent, "00001.00001.mp4")
        XCTAssertEqual(live.coordinate.latitude, 51.5, accuracy: 0.00001)
    }

    @MainActor
    func testCamerasViewModelRefreshAndSelection() async throws {
        let cameras = try TFLJamCamClient.parse(Data(sample.utf8))
        let viewModel = CamerasViewModel(provider: StubProvider(result: .success(cameras)))

        await viewModel.refresh(force: true)
        XCTAssertEqual(viewModel.cameras.count, 2)
        XCTAssertEqual(viewModel.onlineCount, 1)
        XCTAssertNotNil(viewModel.lastUpdated)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.selectFirstAvailable()
        XCTAssertEqual(viewModel.selectedCamera?.name, "Test Camera")

        viewModel.select(nil)
        XCTAssertNil(viewModel.selectedCamera)
    }

    @MainActor
    func testCamerasViewModelKeepsOldDataOnFailure() async throws {
        let cameras = try TFLJamCamClient.parse(Data(sample.utf8))
        let provider = StubProvider(result: .success(cameras))
        let viewModel = CamerasViewModel(provider: provider)
        await viewModel.refresh(force: true)

        provider.result = .failure(JamCamError.badStatus(503))
        await viewModel.refresh(force: true)

        XCTAssertEqual(viewModel.cameras.count, 2)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Adaptive dot layer

    @MainActor
    func testDotLayerIsEmptyAtOverviewZoom() async throws {
        let viewModel = CamerasViewModel(provider: StubProvider(result: .success(try TFLJamCamClient.parse(Data(sample.utf8)))))
        await viewModel.refresh(force: true)

        let overview = GeoRegion(
            center: GeoCoordinate(latitude: 51.5074, longitude: -0.1278),
            latitudeDelta: 0.14,
            longitudeDelta: 0.20
        )
        XCTAssertTrue(viewModel.dots(in: overview).isEmpty, "the coverage grid owns the overview")
    }

    @MainActor
    func testDotLayerReturnsNearbyCamerasNearestFirst() async throws {
        let viewModel = CamerasViewModel(provider: StubProvider(result: .success(try TFLJamCamClient.parse(Data(sample.utf8)))))
        await viewModel.refresh(force: true)

        let street = GeoRegion(
            center: GeoCoordinate(latitude: 51.5005, longitude: -0.1205),
            latitudeDelta: 0.01,
            longitudeDelta: 0.0135
        )
        // The offline camera is 11 km north and the bad one was dropped entirely.
        XCTAssertEqual(viewModel.dots(in: street).map(\.name), ["Test Camera"])
    }

    @MainActor
    func testDotLayerIsCappedAndOrderedByDistance() async throws {
        let many = (0..<500).map { index in
            JamCam(
                id: "cam-\(index)",
                name: "Camera \(index)",
                coordinate: GeoCoordinate(
                    latitude: 51.5 + Double(index) * 0.000008,
                    longitude: -0.12
                )
            )
        }
        let viewModel = CamerasViewModel(provider: StubProvider(result: .success(many)))
        await viewModel.refresh(force: true)

        let region = GeoRegion(
            center: GeoCoordinate(latitude: 51.5, longitude: -0.12),
            latitudeDelta: 0.01,
            longitudeDelta: 0.0135
        )
        let dots = viewModel.dots(in: region)
        XCTAssertEqual(dots.count, CamerasViewModel.dotLayerLimit)
        XCTAssertEqual(dots.first?.id, "cam-0")
        XCTAssertEqual(dots.last?.id, "cam-\(CamerasViewModel.dotLayerLimit - 1)")
    }
}

private final class StubProvider: JamCamProviding {
    var result: Result<[JamCam], Error>

    init(result: Result<[JamCam], Error>) {
        self.result = result
    }

    func fetchCameras() async throws -> [JamCam] {
        try result.get()
    }
}
