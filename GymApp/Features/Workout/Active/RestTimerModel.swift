import Foundation
import Observation
import AudioToolbox

// MARK: - Rest timer

/// The rest countdown between sets.
///
/// **Everything is derived from a stored end date, never from a tick counter.** A workout timer has
/// to survive the screen locking, a phone call, the app being suspended for ten minutes and the
/// system throttling background work — and a counter that decrements on a tick is wrong the instant
/// any of that happens. The ticker here exists only to nudge SwiftUI into redrawing; the number the
/// user reads is always `endsAt − now`, so a timer that was invisible for four minutes comes back
/// with the correct remaining time (or already finished) rather than four minutes of drift.
@MainActor
@Observable
final class RestTimerModel {
    /// When the current rest period ends. `nil` means no rest is running.
    private(set) var endsAt: Date?
    /// The length the period was started with, kept so the progress ring has a denominator.
    private(set) var totalSeconds: Int = 0
    /// Refreshed by the ticker purely to invalidate the views that read `remainingSeconds`.
    private(set) var lastTick: Date = Date()

    /// Called once, on the main actor, when the countdown reaches zero.
    @ObservationIgnored var onFinished: (() -> Void)?

    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Guards against firing twice when a refresh and a tick land on the same instant.
    @ObservationIgnored private var hasFired = false

    /// Cadence of the redraw nudge. Four times a second is enough that the seconds digit never
    /// appears to skip, and cheap enough that a forty-minute session costs nothing measurable.
    private static let tickInterval: Duration = .milliseconds(250)

    /// A rest period longer than this is a mistake, not a preference.
    private static let maximumSeconds = 3600

    var isRunning: Bool { endsAt != nil }

    var remainingSeconds: Int {
        guard let endsAt else { return 0 }
        return max(0, Int(endsAt.timeIntervalSince(lastTick).rounded(.up)))
    }

    /// 0…1 of the period already served. Drives the ring, never the countdown itself.
    var elapsedFraction: Double {
        guard totalSeconds > 0, isRunning else { return 0 }
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(totalSeconds)))
    }

    // MARK: Control

    func start(seconds: Int, now: Date = Date()) {
        let clamped = max(1, min(seconds, Self.maximumSeconds))
        totalSeconds = clamped
        endsAt = now.addingTimeInterval(TimeInterval(clamped))
        lastTick = now
        hasFired = false
        startTicking()
    }

    /// Adds or removes time. The end date moves, so the change survives backgrounding like the
    /// original period does.
    func adjust(by delta: Int, now: Date = Date()) {
        guard let current = endsAt else { return }
        // A "−15 s" that lands in the past would fire the alarm under the user's thumb. One second
        // of headroom keeps the gesture meaning "less rest" rather than "rest over, now".
        let moved = max(current.addingTimeInterval(TimeInterval(delta)), now.addingTimeInterval(1))
        endsAt = moved
        let newRemaining = Int(moved.timeIntervalSince(now).rounded(.up))
        totalSeconds = max(1, max(totalSeconds + delta, newRemaining))
        refresh(now: now)
    }

    /// Ends the period without announcing it — the user chose to go early.
    func skip() {
        stop()
    }

    func stop() {
        endsAt = nil
        totalSeconds = 0
        hasFired = true
        ticker?.cancel()
        ticker = nil
    }

    /// Recomputes against the wall clock. Called on every tick and whenever the app returns to the
    /// foreground, which is what makes a suspended timer correct the moment it is visible again.
    func refresh(now: Date = Date()) {
        lastTick = now
        guard let endsAt else { return }
        if now >= endsAt { fire() }
    }

    // MARK: Private

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.refresh()
                if !self.isRunning { return }
            }
        }
    }

    private func fire() {
        guard !hasFired else { return }
        hasFired = true
        endsAt = nil
        ticker?.cancel()
        ticker = nil
        onFinished?()
    }
}

// MARK: - Hold timer

/// A count-up timer for movements measured in seconds — planks, hollow holds, loaded carries.
///
/// Same rule as the rest timer: the elapsed value is `now − startedAt`, so a hold that spans a
/// notification banner or a rotation is still timed correctly.
@MainActor
@Observable
final class HoldTimerModel {
    private(set) var startedAt: Date?
    /// Seconds banked by previous runs, so pausing and resuming accumulates instead of resetting.
    private(set) var bankedSeconds: Int = 0
    private(set) var lastTick: Date = Date()
    /// The set the timer is attached to. Only one hold can be running at a time.
    private(set) var setID: UUID?

    @ObservationIgnored private var ticker: Task<Void, Never>?

    var isRunning: Bool { startedAt != nil }

    var elapsedSeconds: Int {
        guard let startedAt else { return bankedSeconds }
        return bankedSeconds + max(0, Int(lastTick.timeIntervalSince(startedAt)))
    }

    func start(setID: UUID, from seconds: Int = 0, now: Date = Date()) {
        if self.setID != setID { bankedSeconds = seconds }
        self.setID = setID
        startedAt = now
        lastTick = now
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isRunning else { return }
                self.lastTick = Date()
            }
        }
    }

    /// Stops and returns the seconds held, for the caller to write into the set.
    @discardableResult
    func stop(now: Date = Date()) -> Int {
        guard let startedAt else { return bankedSeconds }
        lastTick = now
        bankedSeconds += max(0, Int(now.timeIntervalSince(startedAt)))
        self.startedAt = nil
        ticker?.cancel()
        ticker = nil
        return bankedSeconds
    }

    func reset() {
        startedAt = nil
        bankedSeconds = 0
        setID = nil
        ticker?.cancel()
        ticker = nil
    }

    func isRunning(for setID: UUID) -> Bool { isRunning && self.setID == setID }
}

// MARK: - Audible alert

/// The optional end-of-rest sound.
///
/// A system sound rather than a bundled asset: it plays through the ringer path, so it behaves the
/// way the user's silent switch and volume already tell it to, and it costs no audio session
/// management that could interrupt whatever they are listening to while training.
enum RestAlertSound {
    /// `1005` is the short, dry "alarm" tone — audible over a gym without being musical.
    private static let systemSoundID: SystemSoundID = 1005

    static func play() {
        AudioServicesPlaySystemSound(systemSoundID)
    }
}
