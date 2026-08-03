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
    ///   1. a one-shot DeviceActivity schedule ending at expiry — or at the
    ///      15-minute schedule floor (+30 s margin) when expiry is closer,
    ///      because a sub-minimum interval fails to arm at all; clamped it
    ///      fires late, and the ledger makes late harmless
    ///   2. a staggered backup ~2 minutes after the primary
    ///   3. a usage-threshold event at the true granted minutes, on the
    ///      door's own tokens — its failure mode is independent of the
    ///      schedules', which is the point
    ///   4. every app foreground / shield render / shield tap reconciles
    /// If every layer fails, the door closes at the next wake: late, never never.
    func open(door: Door, until relockAt: Date) {
        Wall.reconcile()   // ledger already contains the grant; this opens the door

        // DeviceActivitySchedule refuses intervals under 15 minutes; a grant
        // shorter than that must still arm SOMETHING. Clamp the schedule ends
        // to the floor (plus margin against clock skew) and let reconcile
        // close the door at true expiry the moment anything wakes.
        let scheduleFloor: TimeInterval = 15 * 60 + 30
        let clamped = relockAt.timeIntervalSinceNow < scheduleFloor
        let primaryEnd = clamped ? Date.now.addingTimeInterval(scheduleFloor) : relockAt

        let cal = Calendar.current
        let start = cal.dateComponents([.hour, .minute], from: .now)
        let end = cal.dateComponents([.hour, .minute], from: primaryEnd)
        let endStagger = cal.dateComponents([.hour, .minute],
                                            from: primaryEnd.addingTimeInterval(120))

        // Layer 3 rides the primary schedule: N minutes actually spent inside
        // the door fires eventDidReachThreshold, which reconciles. Ceil, so
        // the threshold never undercuts the grant it polices. The threshold
        // keeps the TRUE granted minutes even when the schedule is clamped —
        // thresholds may not share the schedule's 15-minute minimum, and the
        // device test will say.
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        let sel = SharedStore.loadDoorSelections()[door.id]
        if let sel, !(sel.applicationTokens.isEmpty && sel.categoryTokens.isEmpty) {
            let minutes = max(1, Int(ceil(relockAt.timeIntervalSinceNow / 60)))
            events[DeviceActivityEvent.Name("used.\(door.id.uuidString)")] =
                DeviceActivityEvent(applications: sel.applicationTokens,
                                    categories: sel.categoryTokens,
                                    threshold: DateComponents(minute: minutes))
        }

        // Failures here are not recoverable in code — layer 4 still holds —
        // but they must be *visible* on the device test.
        let primary = DeviceActivityName("relock.\(door.id.uuidString)")
        let backup = DeviceActivityName("relock2.\(door.id.uuidString)")
        if clamped {
            Self.log.notice("schedule floor clamp engaged: relock \(relockAt, privacy: .public) → schedules end \(primaryEnd, privacy: .public); ledger holds true expiry")
        }
        do {
            try center.startMonitoring(
                primary,
                during: DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false),
                events: events
            )
            Self.log.notice("armed \(primary.rawValue, privacy: .public) until \(primaryEnd, privacy: .public), threshold \(events.isEmpty ? "none" : "set", privacy: .public)")
        } catch {
            Self.log.error("primary re-lock failed to arm: \(String(describing: error), privacy: .public)")
        }
        do {
            try center.startMonitoring(
                backup,
                during: DeviceActivitySchedule(intervalStart: start, intervalEnd: endStagger, repeats: false)
            )
        } catch {
            Self.log.error("backup re-lock failed to arm: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.sanildesai.silk", category: "wall")

    func stopMonitoring(door: Door) {
        center.stopMonitoring([
            DeviceActivityName("relock.\(door.id.uuidString)"),
            DeviceActivityName("relock2.\(door.id.uuidString)"),
        ])
    }
}
