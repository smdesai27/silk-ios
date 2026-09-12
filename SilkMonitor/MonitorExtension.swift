import DeviceActivity
import Foundation
import SilkCore
import os

/// The re-lock layer 1+2 target. This extension does ONE thing: reconcile the
/// wall from the ledger. It runs under a 6 MB high-watermark limit and can be
/// killed at any time — which is safe, because the ledger is the truth and
/// every other wake also reconciles. If this never fires, doors close late,
/// never never.
final class MonitorExtension: DeviceActivityMonitor {

    /// Every callback logs before it reconciles: the March 2026 forum failure
    /// mode is "no logs or notifications appear from the extension", and the
    /// device test needs to tell a callback that never came from a reconcile
    /// that failed. Filter Console on the subsystem — it's the app's bundle ID,
    /// shared by all four processes (SILK_LOG_SUBSYSTEM in project.yml).
    private static let log = Logger(subsystem: SharedStore.logSubsystem, category: "monitor")

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // The event is the liveness record; the name carries a door UUID, so
        // the payload is private — redacted in the persisted log, visible live
        // under a debugger or logging profile when the device test needs it.
        Self.log.notice("intervalDidStart \(activity.rawValue, privacy: .private)")
        // The permanent daily schedule. Its firing IS the record: it proves
        // the framework was alive for this Silk day, which nothing else in
        // this extension can establish — a quiet day produces no per-grant
        // callback even when everything is working. Written before the
        // reconcile, because the reconcile is the part that can fail and the
        // liveness fact is true either way.
        if activity.rawValue == Wall.heartbeatActivity {
            SharedStore.recordHeartbeat()
        }
        Wall.reconcile(restating: true)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        // A grant expired (or its staggered backup fired). Re-lock.
        Self.log.notice("intervalDidEnd \(activity.rawValue, privacy: .private) — re-locking")
        Wall.reconcile(restating: true)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        // Layer 3: the usage-threshold backstop on a granted door.
        Self.log.notice("eventDidReachThreshold \(event.rawValue, privacy: .private) — re-locking")
        Wall.reconcile(restating: true)
    }
}
