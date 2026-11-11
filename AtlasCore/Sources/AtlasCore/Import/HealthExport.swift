import Foundation

/// Points at the workout routes inside an Apple Health export.
///
/// The Health app produces `export.zip` containing
/// `apple_health_export/export.xml` (the database) and
/// `apple_health_export/workout-routes/*.gpx` (one file per route-bearing
/// workout). Only workouts recorded with location have a route; everything
/// else exists only in the XML.
public enum HealthExport {
    /// The folder holding the route files: `workout-routes` when it exists,
    /// otherwise the folder that was handed in.
    public static func routesDirectory(in root: URL) -> URL {
        let candidates = [
            root.appendingPathComponent("apple_health_export/workout-routes", isDirectory: true),
            root.appendingPathComponent("workout-routes", isDirectory: true),
        ]
        for candidate in candidates where exists(candidate) {
            return candidate
        }
        return root
    }

    /// True when the folder looks like a Health export rather than a plain GPX
    /// folder: it holds `export.xml` or a `workout-routes` folder.
    public static func looksLikeExport(_ root: URL) -> Bool {
        exists(root.appendingPathComponent("export.xml"))
            || exists(root.appendingPathComponent("apple_health_export/export.xml"))
            || exists(root.appendingPathComponent("workout-routes", isDirectory: true))
            || exists(root.appendingPathComponent("apple_health_export/workout-routes", isDirectory: true))
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
