import Foundation
import HealthKit
import AtlasCore

/// Reads workouts and their routes from Health, writes them to the sidecar and
/// keeps the app in sync in the background.
///
/// iOS decides when a background delivery actually runs; `HKObserverQuery`
/// plus `enableBackgroundDelivery` is the only sanctioned way to wake the app
/// when a new workout lands, and it needs the HealthKit background-delivery
/// entitlement.
@MainActor
final class HealthKitSync {
    private let store = HKHealthStore()
    private let archiveURL: URL
    private let model: HealthSyncModel
    private let onChange: () -> Void
    private var observer: HKObserverQuery?
    private var isSyncing = false

    /// The walks the Walks tab shows. Everything else is noise in this app.
    private static let accepted: Set<HKWorkoutActivityType> = [.walking, .running, .hiking, .cycling]

    init(archiveURL: URL, model: HealthSyncModel, onChange: @escaping () -> Void) {
        self.archiveURL = archiveURL
        self.model = model
        self.onChange = onChange
    }

    // MARK: - Lifecycle

    func start() {
        guard HKHealthStore.isHealthDataAvailable() else {
            model.report(.unavailable)
            return
        }
        let archive = HealthWalkArchive.load(from: archiveURL)
        model.report(archive.walks.isEmpty ? .needsPermission : .synced(archive.walks.count))
        if let last = archive.lastSyncedAt { model.reportSynced(count: archive.walks.count, at: last) }
        installObserver()
        model.attach { [weak self] in await self?.connectAndSync() }
    }

    /// First run asks for permission; every later run just syncs.
    func connectAndSync() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            let granted = try await requestAuthorization()
            guard granted else {
                model.report(.failed("Health access is off. Turn it on in Settings › Health › Data Access."))
                return
            }
        } catch {
            model.report(.failed("Health permission failed: \(error.localizedDescription)"))
            return
        }
        await sync()
    }

    private func requestAuthorization() async throws -> Bool {
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        try await store.requestAuthorization(toShare: [], read: types)
        // Read permission is deliberately opaque: Health never says whether the
        // person said yes. Ask for the most recent workout and see if one comes
        // back — a "denied" answer is indistinguishable from "no workouts", so
        // the UI keeps the button and says so.
        return true
    }

    // MARK: - Sync

    func sync() async {
        guard !isSyncing, HKHealthStore.isHealthDataAvailable() else { return }
        isSyncing = true
        model.report(.syncing)
        defer { isSyncing = false }

        let existing = HealthWalkArchive.load(from: archiveURL)
        let since = existing.lastSyncedAt?.addingTimeInterval(-7 * 86_400)
            ?? Date().addingTimeInterval(-2 * 365 * 86_400)

        do {
            let workouts = try await recentWorkouts(since: since)
            var converted: [HealthWorkout] = []
            for workout in workouts {
                guard Self.accepted.contains(workout.workoutActivityType) else { continue }
                let points = await routeLocations(for: workout)
                converted.append(HealthWorkout(
                    id: workout.uuid,
                    start: workout.startDate,
                    end: workout.endDate,
                    activity: Self.activityName(workout.workoutActivityType),
                    locations: points
                ))
            }
            let merged = HealthWalkArchive.merging(converted, into: existing)
            try merged.write(to: archiveURL)
            model.reportSynced(count: merged.walks.count, at: merged.lastSyncedAt ?? Date())
            onChange()
        } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
            // The background observer can fire before anyone has granted
            // access. That is not a failure, it is "ask first".
            model.report(.needsPermission)
        } catch {
            model.report(.failed("Health sync failed: \(error.localizedDescription)"))
        }
    }

    private func recentWorkouts(since: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// The route for a workout, in route order. Health keeps it as a separate
    /// series sample, so it takes a second query to read.
    private func routeLocations(for workout: HKWorkout) async -> [RouteLocation] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return [] }

        return await withCheckedContinuation { continuation in
            var points: [RouteLocation] = []
            var finished = false
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let locations {
                    points.append(contentsOf: locations.map {
                        RouteLocation(
                            latitude: $0.coordinate.latitude,
                            longitude: $0.coordinate.longitude,
                            elevation: $0.altitude,
                            timestamp: $0.timestamp
                        )
                    })
                }
                if (done || error != nil), !finished {
                    finished = true
                    continuation.resume(returning: points)
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Background delivery

    private func installObserver() {
        // Health hands the callback a completion block that is not Sendable;
        // wrap it so the main-actor sync can call it when it finishes.
        struct Completion: @unchecked Sendable { let call: () -> Void }

        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { [weak self] _, completion, _ in
            let finish = Completion(call: completion)
            Task { @MainActor in
                await self?.sync()
                finish.call()
            }
        }
        observer = query
        store.execute(query)
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { success, error in
            if !success {
                NSLog("Atlas: Health background delivery unavailable: %@", String(describing: error))
            }
        }
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "walking"
        case .running: return "running"
        case .hiking: return "hiking"
        case .cycling: return "cycling"
        default: return "workout"
        }
    }
}
