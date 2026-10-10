import CoreMedia
import Foundation

enum HostClock {
    /// Seconds on the host clock — the same clock ScreenCaptureKit and AVAudioEngine timestamps use.
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// Maps host-clock instants onto the recording timeline, skipping paused intervals.
/// Both tracks (microphone and system audio) use the same clock so they stay aligned.
final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: Double = 0
    private var pauses: [(start: Double, end: Double)] = []
    private var pauseStart: Double?

    func start(at t: Double = HostClock.now()) {
        lock.locked { startTime = t; pauses = []; pauseStart = nil }
    }

    func pause(at t: Double = HostClock.now()) {
        lock.locked { if pauseStart == nil { pauseStart = t } }
    }

    func resume(at t: Double = HostClock.now()) {
        lock.locked {
            if let p = pauseStart { pauses.append((p, t)); pauseStart = nil }
        }
    }

    var isPaused: Bool { lock.locked { pauseStart != nil } }

    /// Position on the recording timeline, or nil when `t` falls inside a pause.
    func position(forHostTime t: Double) -> Double? {
        lock.locked {
            if let p = pauseStart, t >= p { return nil }
            var paused = 0.0
            for r in pauses {
                if t >= r.end { paused += r.end - r.start } else if t >= r.start { return nil }
            }
            return max(0, t - startTime - paused)
        }
    }

    func elapsed(at now: Double = HostClock.now()) -> Double {
        lock.locked {
            let end = pauseStart ?? now
            let paused = pauses.reduce(0) { $0 + ($1.end - $1.start) }
            return max(0, end - startTime - paused)
        }
    }
}
