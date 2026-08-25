import Foundation
import SilkCore
import FamilyControls
import ManagedSettings

/// The App Group bridge between the app and its three extensions.
/// Everything the shield needs to render — and everything the monitor needs to
/// re-lock — must be readable from here, inside a 6 MB extension.
public enum SharedStore {
    /// Injected from project.yml (`SILK_APP_GROUP`) into every target's
    /// Info.plist, so the identifier lives in exactly one place and a rename
    /// can't leave one of the four bundles pointing at the old container.
    public static let appGroup: String = infoString("SilkAppGroup")

    /// One subsystem across all four processes, so Console shows the app and
    /// its extensions under a single filter.
    public static let logSubsystem: String = infoString("SilkLogSubsystem")

    /// Missing means the build is misconfigured, not that the user did
    /// something — there is no sane fallback for an App Group we'd silently
    /// get wrong, since a wrong container reads as "all state lost".
    private static func infoString(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            preconditionFailure("\(key) missing from Info.plist — see project.yml")
        }
        return value
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    private enum Key {
        static let policy = "silk.policy"
        static let ledger = "silk.ledger"
        static let ledgerStamp = "silk.ledger.stamp"           // moves on every ledger write, any process
        static let attemptsLast = "silk.attempts.last"         // newest attempt; dedupe without the decode
        static let attemptsRevision = "silk.attempts.rev"      // bumped per appended attempt
        static let wallSelection = "silk.wall.selection"       // FamilyActivitySelection (the extras)
        static let doorSelections = "silk.door.selections"     // [UUID: FamilyActivitySelection]
        static let attempts = "silk.attempts"                  // [Date] shield renders
        static let pendingLoosening = "silk.pending"           // PolicyState applying tomorrow
        static let pendingProposedAt = "silk.pending.at"       // when it was asked for
        static let pendingBaseline = "silk.pending.base"       // the policy it was measured against
        static let firstRunAt = "silk.firstrun"                // days before it have no score
        static let keyJournal = "silk.key.journal"             // [Date] — every exception spent
        static let undoSeconds = "silk.undo.seconds"           // the take-it-back window
        static let days = "silk.days"                          // [DayRecord] — closed days, append-only
        static let daysRevision = "silk.days.rev"              // bumped per append
        static let daysStamp = "silk.days.stamp"               // proof-of-read, as the ledger has
        static let heartbeats = "silk.heartbeat"               // [Date] — the daily schedule fired
    }

    /// Debug/QA only: wipe everything so onboarding runs again.
    public static func wipeAll() {
        // silk.key.code / silk.key.placement / silk.proposal are dead keys
        // from the retired key step and proposal card; wiped so upgraded QA
        // installs carry nothing forward.
        for key in ["silk.policy", "silk.ledger", "silk.ledger.stamp",
                    "silk.wall.selection", "silk.door.selections",
                    "silk.attempts", "silk.attempts.last", "silk.attempts.rev",
                    "silk.days", "silk.days.rev", "silk.days.stamp",
                    "silk.heartbeat",
                    "silk.pending", "silk.pending.at", "silk.pending.base",
                    "silk.proposal", "silk.firstrun",
                    "silk.key.code", "silk.key.placement", "silk.key.journal",
                    "silk.undo.seconds"] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - The key

    /// The key journal: every exception spent, in order. Mirror's footnote
    /// reads the count and the last date ("⚿ 1 · Jul 12"); nothing else does.
    /// The physical key isn't built yet, so today the only writer is the
    /// in-app "Tap your key." path — when NFC lands it records here too, and
    /// the footnote needs no new wiring.
    public static func recordKeyUse(at now: Date = Date()) {
        var uses = decode([Date].self, key: Key.keyJournal) ?? []
        uses.append(now)
        // Capped like its sibling, the attempts array: past the cap the
        // footnote's count clamps, which is a smaller lie than a blob that
        // grows for the life of the install.
        if uses.count > 2000 { uses.removeFirst(uses.count - 2000) }
        encode(uses, key: Key.keyJournal)
    }

    public static func keyJournal() -> (count: Int, last: Date?) {
        let uses = decode([Date].self, key: Key.keyJournal) ?? []
        return (uses.count, uses.last)
    }

    // MARK: - The undo window

    /// How long a change can be taken back, in seconds. It is a setting now
    /// (the third row on Settings), so it lives beside the other persisted
    /// values — but not inside PolicyState: the polarity engine orders
    /// budgets, windows and doors by strictness, and the undo window is not
    /// a strictness, it is a courtesy.
    public static func loadUndoSeconds() -> Int {
        let stored = defaults.integer(forKey: Key.undoSeconds)
        return stored > 0 ? stored : 60
    }

    public static func save(undoSeconds: Int) {
        defaults.set(undoSeconds, forKey: Key.undoSeconds)
    }

    // MARK: - Policy

    public static func loadPolicy() -> PolicyState? {
        decode(PolicyState.self, key: Key.policy)
    }

    /// The same read, with the corrupt case kept apart from the absent one.
    /// Only `Wall.reconcile` needs the distinction, and it needs it badly — see
    /// `Decoded`.
    static func loadPolicyDecoded() -> Decoded<PolicyState> {
        decoded(PolicyState.self, key: Key.policy)
    }

    public static func save(policy: PolicyState) {
        encode(policy, key: Key.policy)
    }

    // MARK: - Ledger

    public static func loadLedger() -> GrantLedger {
        decode(GrantLedger.self, key: Key.ledger) ?? GrantLedger()
    }

    /// The stamp under the current ledger blob. Every writer in every process
    /// comes through `save(ledger:)`, so two equal stamps mean the blob has
    /// not moved between them — the app compares before trusting, or writing,
    /// its in-memory copy, because a stale copy persisted wholesale deletes a
    /// grant another process recorded: the door re-shields mid-grant and the
    /// debited minutes reappear. (UserDefaults has no compare-and-swap; the
    /// stamp is the proof-of-read the writers agree on instead.)
    public static func ledgerStamp() -> String? {
        defaults.string(forKey: Key.ledgerStamp)
    }

    /// Returns the stamp it wrote, so the writer can remember its own write
    /// as "read": the next equal comparison then means nobody else has been
    /// here since.
    @discardableResult
    public static func save(ledger: GrantLedger) -> String {
        encode(ledger, key: Key.ledger)
        let stamp = UUID().uuidString
        defaults.set(stamp, forKey: Key.ledgerStamp)
        return stamp
    }

    /// A mutation that must not clobber a write that landed since `knownStamp`
    /// was read. `base` is the ledger the caller has been working on. If the
    /// stamp still matches, that copy is mutated and saved. If it moved,
    /// `base` is stale and a wholesale save of it would erase the other
    /// writer's row — so the store is re-read and the mutation lands on top
    /// of what stands. The same protocol `AppModel.persist` honours; this is
    /// the form a one-shot writer (the Spend intent's grant-record leg) can
    /// call without holding an in-memory stamp of its own across a turn.
    @discardableResult
    public static func save(ledger base: GrantLedger,
                            knownStamp: String?,
                            applying mutation: (inout GrantLedger) -> Void) -> String {
        var ledger = (ledgerStamp() == knownStamp) ? base : loadLedger()
        mutation(&ledger)
        return save(ledger: ledger)
    }

    // MARK: - Day records (the hero's history)

    // MARK: - Heartbeat (the one liveness signal)

    /// Every instant the permanent daily schedule fired.
    ///
    /// Written from the monitor extension, read by the app when it summarises
    /// a day. This is the only evidence Silk has that the Screen Time
    /// framework was actually alive rather than silently dead — `standing`
    /// says the wall is configured, not that anything is running.
    public static func heartbeats() -> [Date] {
        decode([Date].self, key: Key.heartbeats) ?? []
    }

    /// Records a firing of the daily schedule.
    ///
    /// Deduped at an hour — UNLESS the Silk day turned between the last beat
    /// and this one. A launch-time re-arm shortly before the boundary records
    /// a beat belonging to the closing day; the daemon's genuine boundary
    /// firing arrives within the hour and must still land, or the new day is
    /// permanently summarised dead. The rule (and the cap, sized past the
    /// 2000-record day cap so a full walk can always be vouched for) lives in
    /// `DayLog.heartbeatLog`, where `swift test` reaches it. Runs inside a
    /// 6 MB extension, so it stays a decode, a small append and nothing more.
    public static func recordHeartbeat(at now: Date = Date()) {
        guard let beats = DayLog.heartbeatLog(heartbeats(), recording: now,
                                              downHours: loadPolicy()?.downHours)
        else { return }
        encode(beats, key: Key.heartbeats)
    }

    // MARK: - Day records (the hero's history)

    /// Every closed day Silk has summarised, oldest first.
    public static func dayRecords() -> [DayRecord] {
        (decode([DayRecord].self, key: Key.days) ?? []).sorted { $0.dayStart < $1.dayStart }
    }

    /// Moves exactly when a record is appended, so a reader can hold a
    /// derived number until this integer says otherwise — the same contract
    /// `attemptsRevision` offers the week chart.
    public static func daysRevision() -> Int {
        defaults.integer(forKey: Key.daysRevision)
    }

    /// The stamp under the current records blob. Required for the same reason
    /// the ledger has one, and for a sharper one: the compaction gate must
    /// read a record back before it destroys the grants that record
    /// summarises, and `SpendIntent` in another process can rewrite the array
    /// wholesale in between. `UserDefaults` has no compare-and-swap.
    public static func daysStamp() -> String? {
        defaults.string(forKey: Key.daysStamp)
    }

    @discardableResult
    static func save(dayRecords records: [DayRecord]) -> String {
        encode(records, key: Key.days)
        let stamp = UUID().uuidString
        defaults.set(stamp, forKey: Key.daysStamp)
        defaults.set(daysRevision() &+ 1, forKey: Key.daysRevision)
        return stamp
    }

    /// **The compaction gate.** Summarise every closed day that owes a record,
    /// persist them, read them back, and report whether compaction may
    /// proceed.
    ///
    /// > No compaction without a record.
    ///
    /// `GrantLedger.compact` is destructive — it drops every grant older than
    /// the current day start — and a day whose grants are gone can never be
    /// summarised again. So the caller must treat `false` as "do not compact":
    /// the ledger grows slightly and the next tick self-heals, which is the
    /// cheap side of the trade.
    ///
    /// Records are merged idempotently by `dayStart` and an existing record is
    /// never overwritten — `observed` is decided at write time and never
    /// revised, so a re-walk must not be able to change a day's verdict.
    ///
    /// Returns `true` when every owed boundary is present in the store after
    /// the write, including the case where nothing was owed.
    public static func recordClosedDays(upTo currentDayStart: Date,
                                        downHours: DownHours,
                                        ledger: GrantLedger,
                                        wallStanding: Bool,
                                        calendar: Calendar = .current) -> Bool {
        // The gate itself — including the stamp-before-data read order its
        // proof-of-read depends on — lives in `DayLog.recordClosedDays`,
        // where `swift test` can pin it against a scripted concurrent writer.
        // This is only the binding to the live container.
        DayLog.recordClosedDays(upTo: currentDayStart, downHours: downHours,
                                ledger: ledger, wallStanding: wallStanding,
                                calendar: calendar, store: LiveDayRecordStore())
    }

    /// `SharedStore`'s conformance for the compaction gate, kept as a value
    /// the gate takes rather than methods it reaches for, so the tests can
    /// substitute a scripted store.
    private struct LiveDayRecordStore: DayRecordStore {
        func dayRecords() -> [DayRecord] { SharedStore.dayRecords() }
        func daysStamp() -> String? { SharedStore.daysStamp() }
        // The whole blob, not `attempts(since:)` — DayLog decides
        // observability partly from whether the blob sits at its cap, and a
        // filtered slice cannot answer that.
        func attemptsBlob() -> [Date] { decode([Date].self, key: Key.attempts) ?? [] }
        func heartbeats() -> [Date] { SharedStore.heartbeats() }
        func save(dayRecords records: [DayRecord]) { SharedStore.save(dayRecords: records) }
    }

    // MARK: - Pending loosening (applies at next day start, or on key tap)

    public static func loadPendingLoosening() -> PolicyState? {
        decode(PolicyState.self, key: Key.pendingLoosening)
    }

    /// When the loosening was asked for. Without it there is nothing a day
    /// boundary can be compared against, and "applies tomorrow" becomes
    /// "applies on the next launch".
    public static func loadPendingProposedAt() -> Date? {
        defaults.object(forKey: Key.pendingProposedAt) as? Date
    }

    /// The policy the pending was measured against. A pending is a whole-policy
    /// snapshot but a sentence moves one field, and without the baseline there
    /// is no way to tell which — so maturity would have to assign the snapshot
    /// wholesale and revert whatever was tightened while it waited.
    public static func loadPendingBaseline() -> PolicyState? {
        decode(PolicyState.self, key: Key.pendingBaseline)
    }

    /// `baseline` has no default on purpose. A pending stored without one
    /// matures to nothing and is dropped at its boundary, so a call that
    /// forgets it silently throws the user's loosening away — and the shape
    /// that forgets, `save(pendingLoosening: x)`, is the one that reads most
    /// naturally. Requiring it makes the omission a compile error instead.
    public static func save(pendingLoosening: PolicyState?,
                            baseline: PolicyState?,
                            proposedAt: Date = .now) {
        if let p = pendingLoosening {
            encode(p, key: Key.pendingLoosening)
            defaults.set(proposedAt, forKey: Key.pendingProposedAt)
            if let baseline {
                encode(baseline, key: Key.pendingBaseline)
            } else {
                // Drop any stale baseline rather than leave it to be read
                // against a pending it never measured.
                defaults.removeObject(forKey: Key.pendingBaseline)
            }
        } else {
            defaults.removeObject(forKey: Key.pendingLoosening)
            defaults.removeObject(forKey: Key.pendingProposedAt)
            defaults.removeObject(forKey: Key.pendingBaseline)
        }
    }

    // MARK: - Mirror

    /// Stamped once. A day before it has no score — the week band draws it bare
    /// rather than inferring a perfect day from an absence of attempts.
    public static func firstRun() -> Date {
        if let d = defaults.object(forKey: Key.firstRunAt) as? Date { return d }
        let now = Date()
        defaults.set(now, forKey: Key.firstRunAt)
        return now
    }

    // MARK: - Screen Time selections

    public static func loadWallSelection() -> FamilyActivitySelection? {
        decode(FamilyActivitySelection.self, key: Key.wallSelection)
    }

    public static func save(wallSelection: FamilyActivitySelection) {
        encode(wallSelection, key: Key.wallSelection)
    }

    public static func loadDoorSelections() -> [UUID: FamilyActivitySelection] {
        decode([UUID: FamilyActivitySelection].self, key: Key.doorSelections) ?? [:]
    }

    public static func save(doorSelections: [UUID: FamilyActivitySelection]) {
        encode(doorSelections, key: Key.doorSelections)
    }

    /// Every application token any door names. What the wall covers is this
    /// union plus the extras in the wall selection.
    public static func doorApplicationTokens() -> Set<ApplicationToken> {
        loadDoorSelections().values.reduce(into: Set<ApplicationToken>()) {
            $0.formUnion($1.applicationTokens)
        }
    }

    /// All application tokens belonging to doors that should be open now,
    /// with the decodes already paid: `Wall.reconcile` — the one caller —
    /// holds both values by the time it needs the exceptions, and this runs
    /// on every shield render inside the extension's 6 MB budget — no room
    /// to decode either of them twice. (A public zero-argument overload that
    /// re-read both blobs lost its last caller when `reconcile` switched to
    /// this threaded form, and was deleted rather than left as a second,
    /// slower way to ask the same question.)
    static func openDoorTokens(at now: Date, policy: PolicyState,
                               selections: [UUID: FamilyActivitySelection]) -> Set<ApplicationToken> {
        let ledger = loadLedger()
        let dayStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)
        let openIDs = ledger.openDoors(at: now, dayStart: dayStart)
        var tokens = Set<ApplicationToken>()
        for id in openIDs {
            if let sel = selections[id] {
                tokens.formUnion(sel.applicationTokens)
            }
        }
        return tokens
    }

    // MARK: - Attempts (shield renders; Mirror's chart)

    /// Records a shield render. Renders within 60s of the last one count as
    /// the same attempt (docs/market/gaps.md #9) — otherwise the Sunday
    /// equation inflates into a scold.
    public static func recordAttempt(at now: Date = Date()) {
        // The dedupe answer usually lives in one Date, not in the 2000-entry
        // blob: renders arrive in bursts, so the refusal is the hot path and
        // must not pay a whole-array decode to say no.
        if let last = defaults.object(forKey: Key.attemptsLast) as? Date,
           now.timeIntervalSince(last) < 60 { return }
        var attempts = decode([Date].self, key: Key.attempts) ?? []
        // Kept behind the cheap check: an install that predates the
        // timestamp key still dedupes off the blob itself.
        if let last = attempts.last, now.timeIntervalSince(last) < 60 { return }
        attempts.append(now)
        if attempts.count > 2000 { attempts.removeFirst(attempts.count - 2000) }
        encode(attempts, key: Key.attempts)
        defaults.set(now, forKey: Key.attemptsLast)
        defaults.set(attemptsRevision() &+ 1, forKey: Key.attemptsRevision)
    }

    /// Moves exactly when an attempt is appended, so a reader can hold its
    /// decoded buckets until this integer says otherwise — the app's minute
    /// tick asks this instead of re-decoding the blob, and iPad Split View
    /// (a shield render while Silk stays .active) is why the tick must ask
    /// something rather than trust the cache blindly.
    public static func attemptsRevision() -> Int {
        defaults.integer(forKey: Key.attemptsRevision)
    }

    public static func attempts(since: Date) -> [Date] {
        (decode([Date].self, key: Key.attempts) ?? []).filter { $0 >= since }
    }

    // MARK: - Codable plumbing

    /// Why `decode` has three outcomes and not two. `try?` collapses "never
    /// configured" and "configured, and the blob would not decode" into the same
    /// nil, and `Wall.reconcile` reads that nil as "nothing to enforce" and
    /// returns. Shield settings persist across processes, so returning does not
    /// RAISE the wall — it FREEZES it, with whatever grant exception was live
    /// still standing. That is fail-OPEN on the one code path README rule 4
    /// names, and it is why the corrupt case has to be tellable from the absent
    /// one at the call site.
    enum Decoded<T> {
        case absent          // no data at the key: never configured
        case value(T)
        case corrupt         // data present, decode threw
    }

    static func decoded<T: Decodable>(_ type: T.Type, key: String) -> Decoded<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let value = try? JSONDecoder().decode(type, from: data) else { return .corrupt }
        return .value(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard case .value(let v) = decoded(type, key: key) else { return nil }
        return v
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The single wall. One store, one policy — Apple's engineers are explicit
/// that multiple ManagedSettingsStore instances cannot relax each other.
public enum Wall {
    /// Computed, not stored, for the same reason `store` below is:
    /// `ManagedSettingsStore.Name` is not `Sendable`, so a `static let` of one
    /// is shared mutable state as far as Swift 6 is concerned. A fresh value
    /// per call is the same name and costs a string copy.
    public static var storeName: ManagedSettingsStore.Name { .init("silk.wall") }

    /// The permanent daily schedule's name, as a raw string so both the app
    /// (which arms it) and the monitor extension (which answers it) can name
    /// the same activity without this file importing DeviceActivity.
    ///
    /// Deliberately not `relock.*` or `relock2.*`: those are per-grant,
    /// `repeats: false`, and are stopped and restarted on every spend. This
    /// one is armed once and left alone, and the monitor must be able to tell
    /// them apart — a heartbeat firing is a liveness record, not a re-lock.
    public static let heartbeatActivity = "silk.heartbeat"

    /// Every store name Silk could be holding a shield in, including the one it
    /// never means to write. A store's settings outlive the process, the
    /// install, and the app, so the cleanup sweep has to reach further than the
    /// name this build happens to use: `.default` is where a bare
    /// `ManagedSettingsStore()` — a slip in Silk or in a future extension —
    /// would have put a shield, and nothing else would ever come back for it.
    public static var allStoreNames: Set<ManagedSettingsStore.Name> { [storeName, .default] }

    /// Stores with the same name share settings (documented), so a fresh
    /// instance per call is the same wall — and Sendable-clean under Swift 6.
    public static var store: ManagedSettingsStore {
        ManagedSettingsStore(named: storeName)
    }

    /// Reconcile the wall against the ledger. Idempotent, callable from any
    /// process — the app on foreground, the monitor on intervalDidEnd, the
    /// shield extensions on every render/tap. Fail-closed: if state can't be
    /// read, the wall goes up whole.
    public static func reconcile(now: Date = Date()) {
        // The wall is apps only: every door's tokens plus the extras (the
        // wall selection — apps blocked without a name or launch entry).
        // A nil selection is an empty one, not an unconfigured wall; the
        // doors alone can carry the whole policy.
        let extras = SharedStore.loadWallSelection() ?? FamilyActivitySelection()
        // Decoded once and threaded through: the exceptions below need the
        // same dictionary, and this runs on every shield render.
        let doorSelections = SharedStore.loadDoorSelections()
        let blocked = doorSelections.values.reduce(into: extras.applicationTokens) {
            $0.formUnion($1.applicationTokens)
        }
        let store = Self.store

        let exceptions: Set<ApplicationToken>
        switch SharedStore.loadPolicyDecoded() {
        case .absent:
            // No configuration yet: nothing to enforce.
            return
        case .corrupt:
            // A policy that will not decode is a policy this process cannot
            // reason about, and returning here would leave the shield frozen
            // exactly as the last reconcile left it — every live grant exception
            // still standing, for as long as the blob stays unreadable. Nor can
            // the grants be honoured: which of them are still running is
            // readable without the policy (`Grant.isActive` takes no `dayStart`
            // at all), but whether a hand-close has already RETRACTED one is
            // decided by `isClosed`, against a `dayStart` derived from
            // `policy.downHours` — the value that would not decode. Honouring
            // the grants without the closes would honour precisely the
            // exceptions the user revoked. So shield the full union with NO
            // exceptions and let the next good read hand the minutes back.
            //
            // `wallEnabled` is inside the blob too, so it cannot be consulted
            // either. Shielding a user who had turned the wall off is a visible,
            // recoverable wrong; leaving a door open is the one this rule
            // forbids.
            //
            // Which is also why an empty union is a refusal to write rather than
            // a wall of nothing. `blocked` comes from selections that swallow
            // their own decode failures (`loadDoorSelections` ends in `?? [:]`),
            // and FamilyControls tokens are opaque versioned blobs — the
            // realistic failure is BOTH keys unreadable at once, after an OS
            // upgrade. Assigning the empty union there would tear down the whole
            // standing shield: fail-open, on the path this branch exists to keep
            // closed. An empty union under an unreadable policy is not "nothing
            // to block", it is a second input this process cannot read.
            guard !blocked.isEmpty else { return }
            exceptions = []
        case .value(let policy):
            guard policy.wallEnabled else {
                // Off has to mean DOWN, and down means writing it. Returning
                // here left `shield.applications` holding exactly what the last
                // enabled reconcile put there, and nothing else in Silk clears
                // it — so the wall the user switched off stayed up for good,
                // every later reconcile taking this branch and returning again.
                //
                // The shape of the bug from outside: she turns the wall off,
                // the door stays shut anyway, she deletes Silk to be rid of it.
                // The shield settings survive the delete; the extension that
                // renders them does not. So iOS draws its own default over the
                // app — "TikTok is restricted." — with no Screen Time
                // restriction anywhere to explain it and no app left that could
                // take it down. That is the factory-reset review in
                // docs/market/gaps.md #5, reached from inside a working install.
                //
                // This is not the fail-closed rule bending. Rule 4 governs
                // state that cannot be READ — the `.corrupt` branch above. Here
                // the policy decoded and said off. Obeying it is the ledger
                // being the truth.
                store.clearAllSettings()
                return
            }
            exceptions = SharedStore.openDoorTokens(at: now, policy: policy,
                                                    selections: doorSelections)
        }

        store.shield.applications = blocked.subtracting(exceptions)
        // Categories are gone from the model. Nil-ing them here clears stale
        // category shields on upgraded installs — and retires the documented
        // device-verify risk that a category shield overrides per-app
        // unshielding: there is no category layer left to override anything.
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil

        // Web domains never open with a grant (docs/market/gaps.md #2).
        store.shield.webDomains = extras.webDomainTokens.isEmpty ? nil : extras.webDomainTokens
    }
}
