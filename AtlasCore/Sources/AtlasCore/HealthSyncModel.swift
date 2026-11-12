import Foundation
import Combine

/// How far a sync has got: workouts read out of the total Health will give.
public struct HealthSyncProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int = 0, total: Int = 0) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var isComplete: Bool { total > 0 && completed >= total }

    public var summary: String {
        guard total > 0 else { return "Reading your workouts…" }
        return "Syncing \(completed) of \(total)"
    }
}

/// What the UI needs to know about the Health connection. Lives in the core so
/// the sidebar can show it without importing HealthKit, and so the iOS sync can
/// be driven from a test double.
@MainActor
public final class HealthSyncModel: ObservableObject {
    public enum State: Equatable {
        case unavailable
        case needsPermission
        case syncing
        case synced(Int)
        case failed(String)

        public var summary: String {
            switch self {
            case .unavailable: return "Health is not available here"
            case .needsPermission: return "Connect Apple Health"
            case .syncing: return "Syncing walks…"
            case .synced(let count): return "\(count) walks synced"
            case .failed(let message): return message
            }
        }

        public var isBusy: Bool {
            if case .syncing = self { return true }
            return false
        }

        public var needsAction: Bool {
            switch self {
            case .needsPermission, .failed: return true
            default: return false
            }
        }
    }

    @Published public private(set) var state: State = .unavailable
    @Published public private(set) var lastSyncedAt: Date?
    /// Filled while a sync runs, so the row can show "12 of 92" and a bar.
    @Published public private(set) var progress: HealthSyncProgress?

    private var runner: (() async -> Void)?

    public init() {}

    /// The platform installs the work here; the view only calls `activate()`.
    public func attach(runner: @escaping () async -> Void) {
        self.runner = runner
    }

    /// What the button does: ask for permission the first time, then sync.
    public func activate() async {
        guard let runner else { return }
        await runner()
    }

    public func report(_ state: State) {
        self.state = state
        if case .syncing = state {} else { progress = nil }
    }

    /// Called by the platform sync as each workout is read, so the count on
    /// screen is the number already saved, not a guess.
    public func reportProgress(completed: Int, total: Int) {
        progress = HealthSyncProgress(completed: completed, total: total)
        if case .syncing = state {} else { state = .syncing }
    }

    public func reportSynced(count: Int, at date: Date) {
        lastSyncedAt = date
        progress = nil
        state = .synced(count)
    }
}
