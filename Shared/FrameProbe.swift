#if os(iOS)
import UIKit
import QuartzCore
import AtlasCore

/// Records display-link cadence while the map is being driven. Gated by
/// `ATLAS_PERF=1` (via the Reflex `perf frames start` command) so normal runs
/// pay nothing. Results are reported as percentiles rather than an average,
/// because a hitch is what a person actually feels.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()

    private var link: CADisplayLink?
    private var intervalsMS: [Double] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var targetMS: Double = 0
    private var lastStats: FrameStats?

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        intervalsMS.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        startedAt = CACurrentMediaTime()
        targetMS = 0

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        isRunning = true
        AtlasPerformance.shared.increment("frames.probes")
    }

    @objc private func tick(_ link: CADisplayLink) {
        if targetMS == 0 {
            let nominal = (link.targetTimestamp - link.timestamp) * 1_000
            targetMS = nominal > 0 ? nominal : 16.67
        }
        if lastTimestamp > 0 {
            intervalsMS.append((link.timestamp - lastTimestamp) * 1_000)
        }
        lastTimestamp = link.timestamp
    }

    func stop() -> FrameStats {
        link?.invalidate()
        link = nil
        isRunning = false
        let durationMS = (CACurrentMediaTime() - startedAt) * 1_000
        let stats = FrameStats(
            intervalsMS: intervalsMS,
            durationMS: durationMS,
            targetMS: targetMS > 0 ? targetMS : 16.67
        )
        lastStats = stats
        AtlasPerformance.shared.recordFrames(stats)
        return stats
    }

    func statsJSON() -> String {
        (lastStats ?? FrameStats(intervalsMS: [], durationMS: 0, targetMS: 16.67)).jsonString()
    }
}

#elseif os(macOS)
import AppKit
import QuartzCore
import AtlasCore

/// macOS frame cadence on the main thread, via the window's CADisplayLink.
/// Unlike a background CVDisplayLink, this drops when the app cannot service
/// the frame, so the numbers reflect what a person actually sees.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()

    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var intervalsMS: [Double] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var targetMS: Double = 0
    private var lastStats: FrameStats?
    private(set) var isRunning = false

    func attach(window: NSWindow) {
        self.window = window
    }

    func start() {
        guard !isRunning else { return }
        if link == nil, let window {
            let link = window.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        guard let link else { return }

        intervalsMS.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        startedAt = CACurrentMediaTime()
        targetMS = 0
        link.isPaused = false
        isRunning = true
        AtlasPerformance.shared.increment("frames.probes")
    }

    @objc private func tick(_ link: CADisplayLink) {
        if targetMS == 0 {
            targetMS = link.duration > 0 ? link.duration * 1_000 : 1_000.0 / 60.0
        }
        if lastTimestamp > 0 {
            intervalsMS.append((link.timestamp - lastTimestamp) * 1_000)
        }
        lastTimestamp = link.timestamp
    }

    func stop() -> FrameStats {
        link?.isPaused = true
        isRunning = false
        let durationMS = (CACurrentMediaTime() - startedAt) * 1_000
        let stats = FrameStats(
            intervalsMS: intervalsMS,
            durationMS: durationMS,
            targetMS: targetMS > 0 ? targetMS : 1_000.0 / 60.0
        )
        lastStats = stats
        AtlasPerformance.shared.recordFrames(stats)
        return stats
    }

    func statsJSON() -> String {
        (lastStats ?? FrameStats(intervalsMS: [], durationMS: 0, targetMS: 16.67)).jsonString()
    }
}
#endif
