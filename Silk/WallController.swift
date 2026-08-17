import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings
import SilkCore
import os

/// The app-side face of the wall: authorization, the picker selections, and the
/// re-lock scheduling (defence in depth, docs/market/gaps.md #1).
@MainActor
final class WallController {
    private let center = DeviceActivityCenter()

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            return true
        } catch {
            return false
        }
    }

    /// Re-check on every foreground: revoking Silk in Settings sends NO
    /// callback, and an ensō drawn over a downed wall is the one lie Silk
    /// could accidentally tell. (docs/market/gaps.md #5)
    var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// Whether the wall can actually stand, and if not, what raising it takes.
    /// `.notDetermined` on an onboarded install is the new-phone signature —
    /// authorization does not restore from backup — so raising re-runs the
    /// picker too: restored tokens are device-bound and a selection that
    /// decodes is not a selection that shields. (docs/market/gaps.md #5)
    enum Standing: Equatable {
        case up
        case needsAuthorization(freshDevice: Bool)
        case needsSelection
    }

    var standing: Standing {
        #if targetEnvironment(simulator)
        // The simulator has no real wall; onboarding already treats
        // authorization there as fire-and-forget.
        return .up
        #else
        let status = AuthorizationCenter.shared.authorizationStatus
        guard status == .approved else {
            return .needsAuthorization(freshDevice: status == .notDetermined)
        }
        // What the wall covers: every door's tokens plus the extras. Empty
        // union means nothing shields, whatever decoded.
        let extras = SharedStore.loadWallSelection()?.applicationTokens ?? []
        guard !SharedStore.doorApplicationTokens().union(extras).isEmpty else {
            return .needsSelection
        }
        return .up
        #endif
    }

    // MARK: - First-run hygiene

    /// A previous install's shield survives deletion; left standing it is how
    /// the "I had to factory reset my iPhone" review happens. Called once, on
    /// a launch that finds no local state. (docs/market/gaps.md #5)
    func clearOrphans() {
        Wall.store.clearAllSettings()
        center.stopMonitoring()
    }

    // MARK: - Reconcile (fail-closed; callable from anywhere)

    func reconcile() {
        Wall.reconcile()
    }

    // MARK: - Granting

    /// Opens a door until `relockAt`, then arms the re-lock layers:
    ///   1. a one-shot DeviceActivity schedule ending on the first minute mark
    ///      at or after expiry — or after the 15-minute schedule floor (+30 s
    ///      margin) when expiry is closer, because a sub-minimum interval fails
    ///      to arm at all; clamped it fires late, and the ledger makes late
    ///      harmless
    ///   2. a staggered backup 2 minutes after the primary
    ///   3. a usage-threshold event at the true granted minutes, on the
    ///      door's own tokens — its failure mode is independent of the
    ///      schedules', which is the point
    ///   4. every app foreground / shield render / shield tap reconciles
    /// If every layer fails, the door closes at the next wake: late, never never.
    func open(door: Door, until relockAt: Date) {
        Wall.reconcile()   // ledger already contains the grant; this opens the door
        arm(door: door, until: relockAt)
    }

    /// The scheduling half of `open`, without the unshielding, reporting
    /// whether BOTH schedules took. The Spend intent gates a grant on the
    /// answer, because nothing wakes that path: Shortcuts performs the intent
    /// in a background launch with no scene, so `foregrounded()` never runs,
    /// the process is suspended the moment `perform` returns, and the granted
    /// door is unshielded — so its own shield never renders either. A door
    /// opened there with nothing scheduled behind it stays open until Silk is
    /// next opened by hand, which is invariant 4 read backwards.
    ///
    /// Both schedules, and not either: a schedule end carries hours and
    /// minutes only, and the daemon that reads them can die. `RelockWindow`
    /// states both ends ON the minute mark the schedule will fire on, so the
    /// primary is the one that closes the door and the stagger is what covers a
    /// wake that never came — which is only a backstop while BOTH are armed.
    ///
    /// In the app the answer is discarded, and not because a wake is
    /// guaranteed there — `apply(.grant)` hands the phone straight to the
    /// granted app, which suspends Silk's own clock. Refusing a spend she
    /// asked for out loud is a product decision and waits for its own change.
    @discardableResult
    func arm(door: Door, until relockAt: Date) -> Bool {
        // One clock read for both ends and the threshold. The ledger keeps the
        // true expiry; every move RelockWindow makes is late, never early.
        let now = Date.now
        let window = RelockWindow(now: now, relockAt: relockAt)

        // Both ends arrive on a minute mark, so dropping the seconds here is a
        // no-op rather than a move — which is the only reason the schedule can
        // be trusted to fire on the far side of the expiry the ledger holds.
        // `start` is the one that truly truncates, and downward is right for
        // it: an interval that began a moment ago is already running.
        let cal = Calendar.current
        let start = cal.dateComponents([.hour, .minute], from: now)
        let end = cal.dateComponents([.hour, .minute], from: window.primaryEnd)
        let endStagger = cal.dateComponents([.hour, .minute], from: window.backupEnd)

        // Layer 3 rides the primary schedule: N minutes actually spent inside
        // the door fires eventDidReachThreshold, which reconciles. The
        // threshold keeps the TRUE granted minutes even when the schedule is
        // clamped — thresholds may not share the schedule's 15-minute minimum,
        // and the device test will say.
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        let sel = SharedStore.loadDoorSelections()[door.id]
        if let sel, !(sel.applicationTokens.isEmpty && sel.categoryTokens.isEmpty) {
            events[DeviceActivityEvent.Name("used.\(door.id.uuidString)")] =
                DeviceActivityEvent(applications: sel.applicationTokens,
                                    categories: sel.categoryTokens,
                                    threshold: DateComponents(minute: window.thresholdMinutes))
        }

        // Failures here are still logged for the device test, and now they are
        // also what the intent reads before it lets a grant stand.
        let primary = DeviceActivityName("relock.\(door.id.uuidString)")
        let backup = DeviceActivityName("relock2.\(door.id.uuidString)")
        if window.clamped {
            Self.log.notice("schedule floor clamp engaged: relock \(relockAt, privacy: .public) → schedules end \(window.primaryEnd, privacy: .public); ledger holds true expiry")
        }

        // Disarm before arming, so arming is a restatement rather than a
        // second registration. An ended non-repeating activity is not
        // documented to drop out of the daemon's list, and a spend now fails
        // when `startMonitoring` throws — without this, one stale name could
        // make a door permanently unspendable through the intent. Disarming
        // cannot throw, so it can only help.
        center.stopMonitoring([primary, backup])

        var armed = true
        do {
            try center.startMonitoring(
                primary,
                during: DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false),
                events: events
            )
            Self.log.notice("armed \(primary.rawValue, privacy: .public) until \(window.primaryEnd, privacy: .public), threshold \(events.isEmpty ? "none" : "set", privacy: .public)")
        } catch {
            armed = false
            Self.log.error("primary re-lock failed to arm: \(String(describing: error), privacy: .public)")
        }
        do {
            try center.startMonitoring(
                backup,
                during: DeviceActivitySchedule(intervalStart: start, intervalEnd: endStagger, repeats: false)
            )
        } catch {
            armed = false
            Self.log.error("backup re-lock failed to arm: \(String(describing: error), privacy: .public)")
        }
        if !armed {
            // A half-armed door is worse than an unarmed one: the caller is
            // about to put the grant back, and a surviving schedule would wake
            // the monitor to reconcile a grant that no longer exists while
            // leaving a name registered that nothing in Silk ever clears.
            center.stopMonitoring([primary, backup])
        }
        return armed
    }

    private static let log = Logger(subsystem: SharedStore.logSubsystem, category: "wall")

    func stopMonitoring(door: Door) {
        center.stopMonitoring([
            DeviceActivityName("relock.\(door.id.uuidString)"),
            DeviceActivityName("relock2.\(door.id.uuidString)"),
        ])
    }
}
