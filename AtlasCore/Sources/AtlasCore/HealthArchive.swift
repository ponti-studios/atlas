import Foundation

public extension HealthWalkArchive {
    var snapshot: AtlasData {
        AtlasData(walks: walks, routes: routes)
    }
}
