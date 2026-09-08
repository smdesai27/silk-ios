import Foundation
import SilkCore
import FamilyControls
import ManagedSettings
// Unconditional since `Wall.reconcile` gained a shipping log line: the
// calibration logger below is still DEBUG-only, but the reconcile's refusal to
// write is a Release fact and has to be visible on a shipped build.
import os

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

    // MARK: - The calibration instrument

    /// The device day's only instrument, and **DEBUG-only on purpose**.
    ///
    /// `growth-decision` verdict 6 makes a real day of use a pre-beta gate:
    /// near-zero reaches on an ordinary day, or many on an untouched one, and
    /// the `reaches` term is noise. Nothing could answer that. Mirror draws the
    /// score, which is four terms collapsed into one number and cannot be
    /// inverted; the footnote shows today's unlocks and that is the only term
    /// on any screen. The shield records every reach and logged none of them —
    /// `SilkShield` had no `Logger` at all — so the term the gate exists to
    /// judge was the one term nothing could see.
    ///
    /// **Why DEBUG and not `.private`.** `c49bc17` settled the doctrine for the
    /// shipping log: keep the event, redact the payload, speak plainly only to
    /// a watching debugger. These lines are payload — when someone reached, how
    /// often, and what a day cost — so under that doctrine they would all be
    /// `.private`, which is unreadable in Console without a logging profile.
    /// Compiling them out of Release instead keeps the shipped privacy surface
    /// exactly where `c49bc17` left it while leaving the numbers plainly
    /// readable on the dev build the device protocols already install.
    /// `scripts/ci.sh release` is what proves the Release side still compiles
    /// with every one of these gone.
    ///
    /// Calibration is the whole reason it exists, so it is not `wall`'s or
    /// `monitor`'s category: `docs/qa/calibration-day.md` filters on this one
    /// and gets the day and nothing else.
    @inline(__always)
    static func calibrationLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Evaluated into a local first: `Logger`'s interpolation escapes, and
        // a non-escaping autoclosure cannot be handed to it directly.
        let text = message()
        calibration.notice("\(text, privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let calibration = Logger(subsystem: logSubsystem, category: "calibration")
    #endif

    /// Sortable and unambiguous, which a localized date is not — these lines
    /// get bucketed into Silk days by hand, and a Silk day does not start at
    /// midnight.
    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.timeZone(separator: .omitted))
    }

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

    /// The suite, opened once per process.
    ///
    /// This was computed, and every one of the hundred-odd reads and writes
    /// below paid `UserDefaults(suiteName:)` for it — a container lookup and a
    /// fresh object each time. `recordAttempt` alone touches it four times on
    /// one shield render, inside a 6 MB extension. A suite is a handle onto a
    /// shared store rather than a copy of it, so a held instance sees every
    /// write any process makes: nothing here wants a *fresh* one, only a
    /// working one.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` — which
    /// is the same reason `Wall.store` and `Wall.storeName` stay computed, and
    /// the reason those two may not follow this one: a `ManagedSettingsStore`
    /// with the same name really is the same wall, so a fresh instance there
    /// costs a string copy and nothing else, while `UserDefaults` is documented
    /// thread-safe and is the one Foundation type it is safe to hold. The
    /// unsafety is the annotation's, not the class's.
    nonisolated(unsafe) static let defaults: UserDefaults =
        UserDefaults(suiteName: appGroup) ?? .standard

    private enum Key {
        static let policy = "silk.policy"
        static let ledger = "silk.ledger"
        static let ledgerStamp = "silk.ledger.stamp"           // moves on every ledger write, any process
        static let attemptsLast = "silk.attempts.last"         // newest attempt; dedupe without the decode
        static let attemptsRevision = "silk.attempts.rev"      // bumped per appended attempt
        static let wallSelection = "silk.wall.selection"       // FamilyActivitySelection (the extras)
        static let doorSelections = "silk.door.selections"     // [UUID: FamilyActivitySelection]
        static let attempts = "silk.attempts"                  // [Date] shield renders
        static let attemptsTail = "silk.attempts.tail"         // [Date] the render path's append buffer
        static let pendingLoosening = "silk.pending"           // PolicyState applying tomorrow
        static let pendingProposedAt = "silk.pending.at"       // when it was asked for
        static let pendingBaseline = "silk.pending.base"       // the policy it was measured against
        static let firstRunAt = "silk.firstrun"                // days before it have no score
        static let undoSeconds = "silk.undo.seconds"           // the take-it-back window
        static let migratedCategories = "silk.migrated.categories"  // the one-shot category clear ran
        static let days = "silk.days"                          // [DayRecord] — closed days, append-only
        static let daysRevision = "silk.days.rev"              // bumped per append
        static let daysStamp = "silk.days.stamp"               // proof-of-read, as the ledger has
        static let heartbeats = "silk.heartbeat"               // [Date] — the daily schedule fired
    }

    /// Debug/QA only: wipe everything so onboarding runs again.
    public static func wipeAll() {
        // silk.key.code / silk.key.placement / silk.key.journal / silk.proposal
        // are dead keys from the retired key step, the retired key journal and
        // the proposal card; wiped so upgraded QA installs carry nothing
        // forward.
        //
        // `silk.migrated.categories` goes with them and must: it is the
        // one-shot flag that says the legacy category shields were already
        // cleared, and a wipe that left it standing would hand the next
        // reconcile a store it believes it has already migrated.
        for key in ["silk.policy", "silk.ledger", "silk.ledger.stamp",
                    "silk.wall.selection", "silk.door.selections",
                    "silk.attempts", "silk.attempts.tail",
                    "silk.attempts.last", "silk.attempts.rev",
                    "silk.days", "silk.days.rev", "silk.days.stamp",
                    "silk.heartbeat",
                    "silk.pending", "silk.pending.at", "silk.pending.base",
                    "silk.proposal", "silk.firstrun",
                    "silk.key.code", "silk.key.placement", "silk.key.journal",
                    "silk.undo.seconds", "silk.migrated.categories"] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - The key
    //
    // The key journal — `silk.key.journal`, a capped `[Date]` of every
    // exception spent — is **gone**, and this note is what stands where it did
    // so the next reader does not reinvent it by accident.
    //
    // It had no reader. Mirror's footnote was the last one: it printed the
    // lifetime count and last date ("⚿ 1 · Jul 12") and now counts today's
    // grants off the ledger instead, which is both a narrower window and a
    // different subject. The writes were kept anyway, on the argument that the
    // record was cheap and unrecoverable once dropped — but "cheap" was a
    // decode and a whole-array re-encode of up to 2000 `Date`s on every grant
    // landing, and the record was of a question nothing has ever asked. The
    // ledger holds every grant with its own timestamp, so exceptions-over-time
    // is answerable from it whenever something actually wants to ask; what the
    // journal alone carried was the "Tap your key." loosening, which opens no
    // door and is not an exception in any sense a reader would want counted.
    //
    // `silk.key.journal` stays in `wipeAll`'s dead-key list so an upgraded
    // install stops carrying the blob around.

    // MARK: - The category migration's one-shot flag

    /// Whether this install has already had its legacy category shields
    /// cleared. `Wall.reconcile` owns the meaning; the key lives here with
    /// every other key, and the two accessors exist because `Key` is private
    /// to this type and `Wall` is a different one.
    ///
    /// Absent reads as `false` (`UserDefaults.bool` on a missing key), so a
    /// fresh install and an install whose flag was lost both clear the
    /// categories once more — which is idempotent, and the safe direction.
    static var categoryShieldsMigrated: Bool {
        defaults.bool(forKey: Key.migratedCategories)
    }

    static func markCategoryShieldsMigrated() {
        defaults.set(true, forKey: Key.migratedCategories)
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
        #if DEBUG
        let before = Set(dayRecords().map(\.dayStart))
        #endif
        let sealed = DayLog.recordClosedDays(upTo: currentDayStart, downHours: downHours,
                                             ledger: ledger, wallStanding: wallStanding,
                                             calendar: calendar, store: LiveDayRecordStore())
        // A record is written once and never revised, so this line is the only
        // moment the day's four terms exist together anywhere outside storage.
        // Mirror draws the score they produce; nothing on any screen shows the
        // terms, and the calibration day is a question about the TERMS —
        // whether `reaches` is signal and whether 180 is the right allowance.
        // growth-decision verdict 6.
        #if DEBUG
        for r in dayRecords() where !before.contains(r.dayStart) {
            calibrationLog("""
                day sealed \(iso(r.dayStart)) — granted \(r.grantedMinutes)m, \
                reaches \(r.reaches), late \(r.lateReaches), unlocks \(r.unlocks), \
                observed \(r.observed), score \(r.score)
                """)
        }
        #endif
        return sealed
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
        //
        // Merged with the render path's tail, and that is not an approximation
        // of the cap reading but the exact one: `DayLog.foldedAttempts` trims
        // to the same cap the fold writes, so a day's `observed` verdict — and
        // the corroboration horizon this same array anchors — cannot turn on
        // whether the app happened to fold before the walk ran.
        func attemptsBlob() -> [Date] { SharedStore.attemptsMerged() }
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

    /// Debug/QA only: move the stamp back, so a store that was wiped a second
    /// ago can stand in for one that has been kept for a week.
    ///
    /// The one thing `firstRun()` cannot do is be re-stamped — it is written
    /// once and then only ever read, which is exactly the property the week
    /// band and the hedgerow rely on. So the back-date is a separate door, it
    /// is `#if DEBUG`, and its only caller is `AppModel`'s `-silkSeedDays`
    /// seam, which is itself reachable only from inside the `-silkReset` wipe.
    #if DEBUG
    static func seedFirstRun(_ date: Date) {
        defaults.set(date, forKey: Key.firstRunAt)
    }
    #endif

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

    /// The same two reads, with the corrupt case kept apart from the absent
    /// one — the distinction `loadPolicyDecoded` exists for, for the same
    /// reason and on the same one code path.
    ///
    /// The loaders above end in `?? FamilyActivitySelection()` and `?? [:]`,
    /// which is right for every caller that is *editing* a selection (an
    /// unreadable blob is about to be overwritten by the picker anyway) and
    /// wrong for the one caller that is *enforcing* it: there, an empty set is
    /// not "nothing to block", it is a torn-down wall.
    static func loadWallSelectionDecoded() -> Decoded<FamilyActivitySelection> {
        decoded(FamilyActivitySelection.self, key: Key.wallSelection)
    }

    static func loadDoorSelectionsDecoded() -> Decoded<[UUID: FamilyActivitySelection]> {
        decoded([UUID: FamilyActivitySelection].self, key: Key.doorSelections)
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
    ///
    /// Takes the token sets and not the selections they came out of: its one
    /// caller is `WallPlan.plan`'s `openDoors` closure, whose door map is
    /// already `[UUID: Set<ApplicationToken>]` — Core cannot name
    /// `FamilyActivitySelection`, and this only ever read `applicationTokens`
    /// off it anyway.
    ///
    /// Takes the ledger too, for the same reason it takes the token sets: its
    /// one caller now keeps what it read, so the shield's subtitle can ask the
    /// same ledger about the same door without decoding it a second time on
    /// the same render.
    static func openDoorTokens(at now: Date, ledger: GrantLedger, policy: PolicyState,
                               selections: [UUID: Set<ApplicationToken>]) -> Set<ApplicationToken> {
        // The ESTABLISHED day, not the live boundary: a hand close must keep
        // binding the wall itself across a mid-day down-hours move, exactly
        // as it keeps binding the bar (`GrantLedger.effectiveDayStart`).
        let dayStart = ledger.effectiveDayStart(now: now, downHours: policy.downHours,
                                                calendar: .current)
        let openIDs = ledger.openDoors(at: now, dayStart: dayStart)
        var tokens = Set<ApplicationToken>()
        for id in openIDs {
            if let doorTokens = selections[id] {
                tokens.formUnion(doorTokens)
            }
        }
        return tokens
    }

    // MARK: - Attempts (shield renders; Mirror's chart)

    /// Records a shield render. Renders within 60s of the last one count as
    /// the same attempt (docs/market/gaps.md #9) — otherwise the Sunday
    /// equation inflates into a scold.
    ///
    /// **The append goes to the tail, not to the blob.** This is called from
    /// the shield extension on the path that draws the wall, and it used to
    /// decode a 2000-entry `[Date]` and re-encode all of it to add one
    /// timestamp — a whole-array JSON round trip per reach, inside a 6 MB
    /// extension, in front of the frame the user is waiting for. The tail is a
    /// separate key holding at most `DayLog.attemptsTailCap` entries, so the
    /// encode the render pays is bounded by 64 dates and not by the install's
    /// whole history. The app folds it back (`foldAttemptsTail`), and until it
    /// does, every reader below merges the two — see `attemptsMerged`.
    ///
    /// The overflow fold is the one path that still pays the full encode, and
    /// it is why the tail cannot silently lose reaches when the app is not
    /// opened for a long stretch: at the cap the render folds the tail itself
    /// rather than evicting its oldest entry. That is one whole-array encode
    /// per 64 reaches instead of one per reach, and nothing is dropped.
    public static func recordAttempt(at now: Date = Date()) {
        // The dedupe answer usually lives in one Date, not in an array at all:
        // renders arrive in bursts, so the refusal is the hot path and must
        // not pay a decode to say no.
        if let last = defaults.object(forKey: Key.attemptsLast) as? Date,
           now.timeIntervalSince(last) < 60 { return }
        var tail = decode([Date].self, key: Key.attemptsTail) ?? []
        // Kept behind the cheap check, and asked of the tail before the blob:
        // an install that predates the timestamp key still dedupes off the
        // stored attempts themselves, and the newest of those is the tail's
        // last entry whenever the tail holds anything at all. The blob is only
        // decoded when the tail cannot answer — which after a fold is once,
        // and never again until the next fold.
        let newest = tail.last ?? attemptsBlob().last
        if let newest, now.timeIntervalSince(newest) < 60 { return }
        tail.append(now)
        encode(tail, key: Key.attemptsTail)
        // The tail is full. Fold here rather than evict: an evicted entry is a
        // reach that never happened as far as the Sunday equation is
        // concerned, and the whole point of the tail is that it costs the
        // render less, not that it costs the record anything. Written first,
        // so the fold folds this reach too and a kill between the two lines
        // loses nothing.
        if tail.count >= DayLog.attemptsTailCap { foldAttemptsTail() }
        defaults.set(now, forKey: Key.attemptsLast)
        defaults.set(attemptsRevision() &+ 1, forKey: Key.attemptsRevision)
        // After the dedupe, never before it: `reaches` counts what was
        // APPENDED, and a burst of renders that collapses into one attempt
        // must read as one line here or the calibration day counts renders
        // and calls them reaches. docs/qa/calibration-day.md.
        //
        // The count is the tail's, and the line says so: a merged count would
        // cost the very decode this function exists to stop paying.
        calibrationLog("reach recorded at \(iso(now)) — attempts tail now \(tail.count)")
    }

    /// The stored blob, exactly as it sits — no tail merged in. Private, and
    /// the only callers are the merge and the fold: everything that reads
    /// "the attempts" reads `attemptsMerged`, or it will report a number that
    /// depends on when the app was last opened.
    private static func attemptsBlob() -> [Date] {
        decode([Date].self, key: Key.attempts) ?? []
    }

    /// The attempts as they stand: the blob with the render path's tail folded
    /// in, cap applied, in order. Identical to what the store holds after
    /// `foldAttemptsTail` — that is `DayLog.foldedAttempts`' whole job, and it
    /// is why the observability rule's "at cap" reading cannot move simply
    /// because a fold has or has not run yet.
    static func attemptsMerged() -> [Date] {
        DayLog.foldedAttempts(blob: attemptsBlob(),
                              tail: decode([Date].self, key: Key.attemptsTail) ?? [])
    }

    /// Fold the render path's tail buffer into the attempts blob.
    ///
    /// Called by the app — on a foreground and on the clock tick — because the
    /// app is the process that may spend a whole-array encode. The shield
    /// calls it only when its tail overflows.
    ///
    /// No reader depends on this having run (`attemptsMerged` is the same
    /// answer either way) and no revision is bumped: nothing observable
    /// changes, so a cache keyed on `attemptsRevision` must not fall for a
    /// fold. What it buys is a bounded tail and one decode instead of two on
    /// the reads that follow.
    ///
    /// **The tail is truncated by length, not cleared.** A shield render
    /// appending between the blob write and this line would otherwise have its
    /// reach dropped, and `UserDefaults` has no compare-and-swap to close that
    /// window properly. Dropping exactly what was folded leaves anything newer
    /// standing. The other side of the same race — two processes folding the
    /// same entries — is closed in `DayLog.foldedAttempts`, which is
    /// idempotent.
    public static func foldAttemptsTail() {
        let tail = decode([Date].self, key: Key.attemptsTail) ?? []
        guard !tail.isEmpty else { return }
        encode(DayLog.foldedAttempts(blob: attemptsBlob(), tail: tail), key: Key.attempts)
        let fresh = decode([Date].self, key: Key.attemptsTail) ?? []
        if fresh.count > tail.count {
            encode(Array(fresh.dropFirst(tail.count)), key: Key.attemptsTail)
        } else {
            defaults.removeObject(forKey: Key.attemptsTail)
        }
    }

    /// Moves exactly when an attempt is appended, so a reader can hold its
    /// decoded buckets until this integer says otherwise — the app's minute
    /// tick asks this instead of re-decoding the blob, and iPad Split View
    /// (a shield render while Silk stays .active) is why the tick must ask
    /// something rather than trust the cache blindly.
    public static func attemptsRevision() -> Int {
        defaults.integer(forKey: Key.attemptsRevision)
    }

    /// Merged, so a reach recorded by a shield render is on the week chart
    /// before the app has folded anything — the tail is a storage detail and
    /// no reader may be able to see it.
    public static func attempts(since: Date) -> [Date] {
        attemptsMerged().filter { $0 >= since }
    }

    // MARK: - Codable plumbing

    /// One coder each for the process. A `JSONDecoder` was built for every
    /// store access — a dozen on the launch path, eight per shield render —
    /// and each is a small object graph nobody kept. Neither has a strategy
    /// set, so there is nothing per-call about them, and both are `Sendable`
    /// once configured.
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// Three outcomes and not two: `try?` collapses "never configured" and
    /// "configured, and the blob would not decode" into the same nil, and a
    /// wall that reads that nil as "nothing to enforce" fails open. `Decoded`
    /// lives in Core (`WallPlan.swift`) beside the decision written against
    /// it, and carries the full argument.
    static func decoded<T: Decodable>(_ type: T.Type, key: String) -> Decoded<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let value = try? decoder.decode(type, from: data) else { return .corrupt }
        return .value(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard case .value(let v) = decoded(type, key: key) else { return nil }
        return v
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? encoder.encode(value) {
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

    /// The reconcile's own log, under the subsystem all four processes share
    /// and the category `WallController` already writes the app-side wall
    /// events to — a refusal to write from a shield extension and the app's
    /// own arming read as one story under a single Console filter. Payload
    /// never goes in a line here; see `calibrationLog`'s note on the c49bc17
    /// doctrine for why.
    private static let log = Logger(subsystem: SharedStore.logSubsystem, category: "wall")

    /// What a reconcile read on its way to a verdict, handed back so the one
    /// caller that needs the same blobs does not decode them a second time.
    ///
    /// The shield's subtitle path wants exactly this: the policy (for the
    /// night face and the door list), the door selections (to find which door
    /// this app belongs to) and the ledger (for the askable minutes). Every
    /// render was decoding all three twice — once inside `reconcile`, once
    /// again in the lines below it — inside a 6 MB extension, in front of the
    /// frame the user is waiting on.
    ///
    /// Every other caller ignores the value, which is why `reconcile` stays
    /// `@discardableResult` and why nothing here is a parameter: the reconcile
    /// decides what it needs, and this is a receipt for what it happened to
    /// read, not a contract about what it will read.
    ///
    /// `ledger` is optional and honestly so. The refusing paths never load it
    /// — `WallPlan.plan` does not call `openDoors` when it will not write —
    /// and a receipt that pretended otherwise would either be a lie or a read
    /// those paths do not owe. A caller that needs it anyway loads it itself.
    ///
    /// `policy` and `doors` collapse `Decoded`'s corrupt case into the same
    /// nil/empty the plain loaders return, because that is exactly what the
    /// shield's own reads did: the distinction is the enforcement path's, and
    /// this receipt is read by the rendering one.
    public struct Reconciled {
        public let policy: PolicyState?
        public let doors: [UUID: FamilyActivitySelection]
        public let ledger: GrantLedger?
    }

    /// Reconcile the wall against the ledger. Idempotent, callable from any
    /// process — the app on foreground, the monitor on intervalDidEnd, the
    /// shield extensions on every render/tap. Fail-closed: if state can't be
    /// read, the wall goes up whole.
    @discardableResult
    public static func reconcile(now: Date = Date()) -> Reconciled {
        // Three reads in, one write out. Everything between them — which of
        // the three states each blob is in, and what the wall should therefore
        // be — is `WallPlan.plan`, in Core, where it can be run against every
        // combination of them without a device, a Screen Time authorization or
        // a shield extension to render the answer. What stays here is the half
        // that cannot be: the `ManagedSettingsStore`.
        //
        // All three are decoded up front, including on the two paths that do
        // not consult the selections at all (no policy yet, and a wall the
        // user switched off). Those pay two decodes they used to skip; both
        // end in an immediate return or a `clearAllSettings`, neither is the
        // shield-render hot path, and a pure function cannot be handed a blob
        // it might not need without becoming a pair of closures and ceasing to
        // be one function anybody can read.
        let policy = SharedStore.loadPolicyDecoded()
        let extras = SharedStore.loadWallSelectionDecoded()
        let doors = SharedStore.loadDoorSelectionsDecoded()
        let store = Self.store

        // Read once and held, for two jobs that used to be two reads: the
        // stand-in the plan takes, and the value the write below is compared
        // against. Nothing can move it in between — this is one synchronous
        // paragraph in one process, and the only writer of this store is this
        // function.
        let standing = store.shield.applications

        // The ledger `openDoorTokens` loads, kept for the receipt. Assigned
        // from a non-escaping closure called synchronously inside the `plan`
        // call below, so there is no concurrency here to reason about — and
        // it stays nil on every path that never asks, which is every path
        // that refuses to write.
        var ledgerRead: GrantLedger?

        // `mapValues`, not a second decode: the token sets are already built
        // inside the selections, and this runs on every shield render inside
        // the extension's 6 MB budget.
        let plan = WallPlan.plan(
            policy: policy,
            extras: extras.map(\.applicationTokens),
            doors: doors.map { $0.mapValues(\.applicationTokens) },
            // What the store holds now: the stand-in for an extras blob
            // that will not decode, so nothing shielded is ever dropped
            // for a key this process could not read. Nil is passed as
            // nil — a stand-in that cannot be read is no stand-in, and
            // the plan refuses rather than write the doors alone.
            standing: standing,
            openDoors: { policyValue, doorTokens in
                // The ledger read the plan cannot do — and does not ask for on
                // any path that refuses to write.
                let ledger = SharedStore.loadLedger()
                ledgerRead = ledger
                return SharedStore.openDoorTokens(at: now, ledger: ledger,
                                                  policy: policyValue, selections: doorTokens)
            })

        // The receipt, returned from every exit below. Corrupt collapses to
        // nil and to empty — the same answers `loadPolicy()` and
        // `loadDoorSelections()` give, which are the calls this replaces.
        func receipt() -> Reconciled {
            var readPolicy: PolicyState?
            if case .value(let p) = policy { readPolicy = p }
            return Reconciled(policy: readPolicy,
                              doors: doors.orEmpty([:]) ?? [:],
                              ledger: ledgerRead)
        }

        switch plan {
        case .leaveUntouched:
            // A selection blob that would not decode is the one refusal
            // nothing else records: the wall stands exactly as it stood, which
            // from outside is indistinguishable from a reconcile that had
            // nothing to do. Which key, and what was in it, is exactly what
            // the shipping log does not say (the c49bc17 doctrine: keep the
            // event, redact the payload).
            if doors.isCorrupt {
                log.error("reconcile: the door selections would not decode; wall left as it stands")
            }
            return receipt()
        case .clearAll:
            store.clearAllSettings()
            return receipt()
        case .shield(let blocked):
            if extras.isCorrupt {
                log.error("reconcile: the wall selection would not decode; the standing shield stood in for it")
            }
            // **Written only when it differs, and this is the one place in the
            // file where an equality guard is allowed to stand in front of a
            // fail-closed write.** It is safe here for one reason: the guard
            // is over the value the daemon already holds, so a skipped write
            // and a performed write leave the store in the same state. Every
            // way the comparison can be wrong falls toward writing —
            // `standing` is `nil` when the read failed or the store was never
            // written, and `nil != blocked` for every `blocked` there is,
            // including the empty set.
            //
            // Why bother. A `ManagedSettingsStore` write is a cross-process
            // call into the Screen Time daemon that re-evaluates enforcement,
            // and this paragraph made four of them — applications, two
            // categories, web domains — on EVERY shield render, tap, monitor
            // callback and foreground. At ~40 wall hits a day that is ~160
            // daemon writes to say what the daemon already knew, and they sit
            // on the critical path of the wall appearing. The steady state is
            // that nothing has changed: a render reconciles because the wake
            // is the point, not because the answer has moved.
            if standing != blocked {
                store.shield.applications = blocked
            }
        }

        // Categories are gone from the model. Nil-ing them here clears stale
        // category shields on upgraded installs — and retires the documented
        // device-verify risk that a category shield overrides per-app
        // unshielding: there is no category layer left to override anything.
        //
        // Only here, after the app layer was written. The refusing paths above
        // return first on purpose: a legacy category shield may be the whole
        // wall an unreadable install still has, and clearing one layer without
        // writing the other is the fail-open this file exists to forbid. The
        // migration waits for the next readable reconcile, which is a stuck
        // restriction, not an open door.
        //
        // **Once per install, behind a flag, and never again.** This is a
        // migration, not an invariant: there is no category layer in the model
        // any more, so nothing in Silk can ever put a category shield back.
        // Two unconditional daemon writes on every shield render to re-clear
        // something already cleared is the whole cost of a one-line upgrade
        // path, paid forever, on the frame the wall appears in.
        //
        // The flag is set only after the writes, and only on this path — the
        // one that just wrote the app layer. A process that returned above has
        // not migrated anything and must not be able to claim it did: that is
        // the same ordering the paragraph's second sentence already turns on.
        // A flag that fails to persist costs a repeated clear, which is
        // idempotent; the fail-closed direction is "clear again", and that is
        // the direction every failure here takes.
        if !SharedStore.categoryShieldsMigrated {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
            SharedStore.markCategoryShieldsMigrated()
        }

        // Web domains never open with a grant (docs/market/gaps.md #2), which
        // is why they are no part of the plan: that decision is app tokens and
        // exceptions, and no door has ever opened a domain. The domains live
        // in the extras blob, and a corrupt one has no stand-in here (the
        // standing shield covers apps, not domains) — so on that path the
        // domain shield is left exactly as it stands, never cleared for a
        // key this process could not read.
        //
        // Guarded like the app layer, and for the same reason: this was the
        // fourth unconditional daemon write per render, and the domains in a
        // wall selection change when the user edits them, which is roughly
        // never. The read this costs is one read to save one write, and a read
        // that fails comes back `nil` — which differs from any non-empty set,
        // so the write still happens. Only "the store already holds exactly
        // this" is skipped.
        if let extraSelection = extras.orEmpty(FamilyActivitySelection()) {
            let webDomains = extraSelection.webDomainTokens
            if webDomains.isEmpty {
                if store.shield.webDomains != nil { store.shield.webDomains = nil }
            } else if store.shield.webDomains != webDomains {
                store.shield.webDomains = webDomains
            }
        }

        return receipt()
    }
}
