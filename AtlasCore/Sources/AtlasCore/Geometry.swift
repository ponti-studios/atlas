import Foundation
import CoreLocation

// MARK: - Route geometry (UI-free)

public struct GeoBounds: Codable, Hashable, Sendable {
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double

    public init?(points: [GeoCoordinate]) {
        guard let first = points.first(where: \.isValid) else { return nil }
        var bounds = GeoBounds(
            minLatitude: first.latitude,
            maxLatitude: first.latitude,
            minLongitude: first.longitude,
            maxLongitude: first.longitude
        )
        for point in points.dropFirst() where point.isValid {
            bounds.minLatitude = Swift.min(bounds.minLatitude, point.latitude)
            bounds.maxLatitude = Swift.max(bounds.maxLatitude, point.latitude)
            bounds.minLongitude = Swift.min(bounds.minLongitude, point.longitude)
            bounds.maxLongitude = Swift.max(bounds.maxLongitude, point.longitude)
        }
        self = bounds
    }

    private init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

}

public enum RouteGeometry {
    /// Douglas–Peucker in a local equirectangular projection, with an iterative
    /// stack so an 87,000-point track cannot blow the call stack. The tolerance
    /// is metres; the result is guaranteed to keep the first and last point.
    public static func simplify(
        _ points: [GeoCoordinate],
        toleranceMeters: Double = 8,
        maxPoints: Int = 480
    ) -> [GeoCoordinate] {
        guard points.count > 2 else { return points }
        var tolerance = Swift.max(0.5, toleranceMeters)
        var result = douglasPeucker(points, toleranceDegrees: tolerance / 111_320)

        // Very long tracks can still survive a small tolerance. Coarsen until
        // the overlay is bounded, which keeps MapKit's vertex count predictable.
        while result.count > maxPoints, tolerance < 4_000 {
            tolerance *= 2
            result = douglasPeucker(points, toleranceDegrees: tolerance / 111_320)
        }
        return result
    }

    private static func douglasPeucker(_ points: [GeoCoordinate], toleranceDegrees: Double) -> [GeoCoordinate] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        stack.reserveCapacity(points.count / 8)

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start]
            let b = points[end]
            let cosLatitude = cos(a.latitude * .pi / 180)
            let dx = (b.longitude - a.longitude) * cosLatitude
            let dy = b.latitude - a.latitude
            let lengthSquared = dx * dx + dy * dy
            var farthest = 0.0
            var farthestIndex = start

            for index in (start + 1)..<end {
                let point = points[index]
                let px = (point.longitude - a.longitude) * cosLatitude
                let py = point.latitude - a.latitude
                let distanceSquared: Double
                if lengthSquared <= 1e-18 {
                    distanceSquared = px * px + py * py
                } else {
                    let t = Swift.max(0, Swift.min(1, (px * dx + py * dy) / lengthSquared))
                    let ex = px - t * dx
                    let ey = py - t * dy
                    distanceSquared = ex * ex + ey * ey
                }
                if distanceSquared > farthest {
                    farthest = distanceSquared
                    farthestIndex = index
                }
            }

            if farthest > toleranceDegrees * toleranceDegrees {
                keep[farthestIndex] = true
                stack.append((start, farthestIndex))
                stack.append((farthestIndex, end))
            }
        }

        var simplified: [GeoCoordinate] = []
        simplified.reserveCapacity(points.count / 4)
        for index in points.indices where keep[index] {
            simplified.append(points[index])
        }
        return simplified
    }

    public static func length(_ points: [GeoCoordinate]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        var previous = points[0]
        for point in points.dropFirst() {
            total += previous.distance(to: point)
            previous = point
        }
        return total
    }
}


public extension GeoRegion {
    /// Whether a coordinate is inside the visible region, optionally padded by a
    /// fraction of the span.
    func contains(_ coordinate: GeoCoordinate, padding: Double = 0) -> Bool {
        let latitudePadding = latitudeDelta * padding
        let longitudePadding = longitudeDelta * padding
        return coordinate.latitude >= center.latitude - latitudeDelta / 2 - latitudePadding
            && coordinate.latitude <= center.latitude + latitudeDelta / 2 + latitudePadding
            && coordinate.longitude >= center.longitude - longitudeDelta / 2 - longitudePadding
            && coordinate.longitude <= center.longitude + longitudeDelta / 2 + longitudePadding
    }
}
