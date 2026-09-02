import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// Dialog-level coverage of `SpendIntent.perform` — every refusal, the
// background-only day-turn sweep, the deliberate restated-over-extend, an
// intent write seen at wait-landing, and the grant-leg stamp race.
//
// `WaitIntentTests` owns the wait-gating shape (not priced, finished when
// it returns, idempotent). This file owns what Siri *says*, and what the
// ledger looks like after it has spoken.
//
// Performed the way Shortcuts performs it: off the main actor, in a process
// with no scene. The dialog is surfaced through `SpendIntent.lastDialog`,
// which `answer(_:)` sets from the same string that goes into the
// `IntentResult` — so a test that pins the sentence is pinning what Siri
// would speak, not a parallel reconstruction.

private func performSpend(door: String, minutes: Int) async throws -> String {
    let intent = SpendIntent()
    intent.doorName = door
    intent.minutes = minutes
    _ = try await intent.perform()
    return SpendIntent.lastDialog
}

private func nightWellClearOfNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay + 6 * 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 7 * 60))
}

private func nightContainingNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay - 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 60))
}

@MainActor
private func freshPolicy(budget: Int = 40,
                         downHours: DownHours? = nil,
                         doors: [Door]? = nil,
                         caps: [UUID: Int] = [:]) -> Door {
    SharedStore.wipeAll()
    SpendIntent.lastDialog = ""
    SpendIntent.beforeGrantSave = nil
    SpendIntent.testForceWallUp = nil
    WallController.testForceArmed = nil
    let door = doors?.first ?? Door(name: "Instagram")
    let roster = doors ?? [door]
    SharedStore.save(policy: PolicyState(budgetMinutes: budget,
                                         downHours: downHours ?? nightWellClearOfNow(),
                                         doors: roster,
                                         doorCaps: caps))
    return door
}

@MainActor
private func freshModel(budget: Int = 40, doors: [Door]) -> AppModel {
    SharedStore.wipeAll()
    SpendIntent.lastDialog = ""
    SpendIntent.beforeGrantSave = nil
    SpendIntent.testForceWallUp = nil
    WallController.testForceArmed = nil
    let model = AppModel()
    model.completeSetup(doors: doors,
                        doorSelections: [:],
                        wallSelection: .init(),
                        budget: budget,
                        downHours: nightWellClearOfNow())
    #expect(UIApplication.shared.applicationState != .background,
            "the host app is not foreground — a wait below will be born parked")
    return model
}

@MainActor
private func settle(within seconds: Double = 3.0,
                    until reached: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !reached() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@Suite(.serialized) @MainActor struct SpendIntentDialogs {

    @Test func unknownDoorAnswersSilenceAndWritesNothing() async throws {
        let _ = freshPolicy()
        // **A sentinel, because silence is the empty string.** `freshPolicy`
        // resets `lastDialog` to "" and `SpendDialog.silence` IS "", so an
        // intent that never spoke at all — a `perform` that returned before it
        // reached `answer(_:)`, or one that crashed past it — left the fixture's
        // own reset standing and the assertions below read it as a deliberate
        // silence. Every other test in this file is safe from that by accident,
        // because its expected dialog is a non-empty sentence; this one is the
        // test where the tautology lives, so the seam is armed with a value no
        // code path can produce.
        SpendIntent.lastDialog = "⟨nothing was spoken⟩"
        let before = SharedStore.loadLedger()
        let stamp = SharedStore.ledgerStamp()

        let spoken = try await performSpend(door: "NotAnApp", minutes: 15)

        #expect(spoken == SpendDialog.silence,
                "Siri answered \"\(spoken)\" for a door that does not exist")
        #expect(spoken.isEmpty)
        #expect(SharedStore.loadLedger() == before)
        #expect(SharedStore.ledgerStamp() == stamp)
    }

    @Test func budgetExhaustedRefusesWithZeroLeftToday() async throws {
        let door = freshPolicy()
        let other = Door(name: "TikTok")
        let policy = SharedStore.loadPolicy()!

        let now = Date.now
        let dayStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)
        var ledger = GrantLedger()
        ledger.record(Grant(door: other, minutes: 40, issuedAt: max(dayStart, now.addingTimeInterval(-30 * 60)),
                            expiresAt: now.addingTimeInterval(10 * 60)))
        SharedStore.save(ledger: ledger)

        let spoken = try await performSpend(door: door.name, minutes: 15)

        #expect(spoken == SpendDialog.nothingLeft)
        #expect(spoken == "0 \(SilkStrings.leftToday)")
        #expect(SharedStore.loadLedger().grants.contains { $0.doorID == door.id } == false)
    }

    @Test func downHoursRefusalStatesTheOpeningHour() async throws {
        let now = Date.now
        let window = nightContainingNow(now)
        let door = freshPolicy(downHours: window)

        let spoken = try await performSpend(door: door.name, minutes: 15)

        #expect(spoken == SpendDialog.downHours(until: window.end))
        #expect(spoken.contains(window.end.displayWithMeridiem))
        #expect(spoken != "\(SilkStrings.till) \(window.end.display).")
        #expect(SharedStore.loadLedger().grants.isEmpty)
    }

    @Test func cappedOutDoorRefusesByNameWithTheBoundary() async throws {
        let door = Door(name: "TikTok")
        let now = Date.now
        let window = nightWellClearOfNow(now)
        let _ = freshPolicy(downHours: window, doors: [door], caps: [door.id: 10])

        let dayStart = DayBoundary.dayStart(now: now, downHours: window)
        var ledger = GrantLedger()
        ledger.record(Grant(door: door, minutes: 10,
                            issuedAt: max(dayStart, now.addingTimeInterval(-20 * 60)),
                            expiresAt: now.addingTimeInterval(-5 * 60)))
        SharedStore.save(ledger: ledger)

        let spoken = try await performSpend(door: door.name, minutes: 15)

        let lift = DayBoundary.nextDayStart(after: dayStart)
        let time = Validator.timeOfDay(lift, calendar: .current)
        #expect(spoken == SpendDialog.doorClosed(door: door.name, until: time))
        #expect(spoken == "\(door.name) \(SilkStrings.closedUntil) \(time.display).")
    }

    @Test func handClosedDoorRefusesWithItsLiftHour() async throws {
        let door = freshPolicy()
        let now = Date.now
        let lift = now.addingTimeInterval(3 * 60 * 60)
        var ledger = GrantLedger()
        ledger.closeDoor(door, at: now, until: lift)
        SharedStore.save(ledger: ledger)

        let spoken = try await performSpend(door: door.name, minutes: 15)

        let time = Validator.timeOfDay(lift, calendar: .current)
        #expect(spoken == SpendDialog.doorClosed(door: door.name, until: time))
        #expect(SharedStore.loadLedger().isClosed(
            door.id, at: now,
            dayStart: DayBoundary.dayStart(now: now, downHours: SharedStore.loadPolicy()!.downHours)))
    }

    @Test func aBackgroundOnlyDayTurnIsSweptByTheIntent() async throws {
        let door = freshPolicy()
        let other = Door(name: "YouTube")
        let now = Date.now
        let policy = SharedStore.loadPolicy()!
        let dayStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)

        var ledger = GrantLedger()
        let yesterday = dayStart.addingTimeInterval(-12 * 60 * 60)
        ledger.record(Grant(door: other, minutes: 20, issuedAt: yesterday,
                            expiresAt: yesterday.addingTimeInterval(20 * 60)))
        let todaySpent = Grant(door: other, minutes: 5,
                               issuedAt: dayStart.addingTimeInterval(60),
                               expiresAt: dayStart.addingTimeInterval(6 * 60))
        ledger.record(todaySpent)
        SharedStore.save(ledger: ledger)
        let stampBefore = SharedStore.ledgerStamp()
        #expect(SharedStore.loadLedger().grants.count == 2)

        WallController.testForceArmed = true
        SpendIntent.testForceWallUp = true
        defer {
            WallController.testForceArmed = nil
            SpendIntent.testForceWallUp = nil
        }

        _ = try await performSpend(door: door.name, minutes: 15)

        let after = SharedStore.loadLedger()
        #expect(after.grants.contains { $0.expiresAt < dayStart } == false,
                "yesterday's grant rode through the intent")
        #expect(after.grants.contains { $0.id == todaySpent.id },
                "today's grant was swept with yesterday")
        #expect(SharedStore.ledgerStamp() != stampBefore,
                "the sweep re-encoded nothing")
    }

    @Test func theSweepRecordsAnUnshieldingWallAsUnobserved() async throws {
        // The sweep's `wallStanding` is the full conjunction —
        // `policy.wallEnabled && WallController.standing == .up` — exactly as
        // `AppModel.compactLedgerIfDayTurned` passes it. It used to pass
        // `wallEnabled` alone, on the theory that arm cannot succeed over a
        // downed wall; but arm succeeds over an EMPTY wall selection
        // (`.needsSelection` — startMonitoring checks authorization and
        // nothing else), so a Siri spend sweeping before the app's next
        // launch would permanently record observed:true for a day the app's
        // own sweep would have recorded observed:false. First write wins and
        // is never revised: the day's verdict must come from the state, not
        // from which process swept first.
        let door = freshPolicy()
        let policy = SharedStore.loadPolicy()!
        let now = Date.now
        let dayStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)
        // The boundary the bootstrap walk emits when no records exist yet.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!

        // Yesterday must be a day only `wallStanding` can sink: sane span,
        // attempts blob nowhere near its cap, and a heartbeat inside it so
        // the liveness term holds.
        var ledger = GrantLedger()
        ledger.record(Grant(door: door, minutes: 20,
                            issuedAt: yesterday.addingTimeInterval(60),
                            expiresAt: yesterday.addingTimeInterval(21 * 60)))
        SharedStore.save(ledger: ledger)
        SharedStore.recordHeartbeat(at: yesterday.addingTimeInterval(120))

        WallController.testForceArmed = true
        SpendIntent.testForceWallUp = false   // authorized, nothing selected
        defer {
            WallController.testForceArmed = nil
            SpendIntent.testForceWallUp = nil
        }

        _ = try await performSpend(door: door.name, minutes: 15)

        let record = SharedStore.dayRecords().first { $0.dayStart == yesterday }
        #expect(record != nil, "the sweep did not record the owed day at all")
        #expect(record?.observed == false,
                "the intent credited a day the wall shielded nothing — the sweep is passing half the wallStanding contract")
    }

    @Test func aBiggerAskOverALiveGrantRestatesViaTheIntent() async throws {
        // Finding 5, pinned. The bar would mint a fresh grant for a bigger
        // ask; the intent restates any live grant, even one shorter than
        // the ask. The header of SpendIntent is the product decision.
        let door = freshPolicy()
        let now = Date.now
        var ledger = GrantLedger()
        let live = Grant(door: door, minutes: 10, issuedAt: now,
                         expiresAt: now.addingTimeInterval(10 * 60))
        ledger.record(live)
        SharedStore.save(ledger: ledger)
        let before = SharedStore.loadLedger()

        let spoken = try await performSpend(door: door.name, minutes: 30)

        let time = Validator.timeOfDay(live.expiresAt, calendar: .current)
        #expect(spoken == SpendDialog.restated(door: door.name, until: time))
        #expect(SharedStore.loadLedger() == before)
        #expect(SharedStore.loadLedger().grants.count == 1)
    }

    @Test func theIntentNeverLaunchesTheGrantedApp() async throws {
        // Finding 4, pinned. The bar path calls LaunchCatalog.open; the
        // intent only unshields. Forced-arm so the success dialog is
        // reachable on the simulator — without it this would pin the
        // rollback, which also does not launch, for the wrong reason.
        let door = freshPolicy()
        WallController.testForceArmed = true
        defer { WallController.testForceArmed = nil }
        LaunchCatalog.testOpenCount = 0

        let spoken = try await performSpend(door: door.name, minutes: 15)

        #expect(LaunchCatalog.testOpenCount == 0,
                "Siri launched the granted app — the intent must only unshield")
        #expect(spoken.contains(SilkStrings.till.lowercased()),
                "the success dialog is the deadline, not the bar's opening")
        #expect(spoken.contains(SilkStrings.isOpenFor) == false)
        #expect(SharedStore.loadLedger().grants.contains { $0.doorID == door.id })
    }
}

@Suite(.serialized) @MainActor struct SpendIntentConcurrency {

    @Test func anIntentWriteDuringAnInAppWaitIsSeenAtLanding() async throws {
        UserDefaults.standard.set("0.8", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let instagram = Door(name: "Instagram")
        let tiktok = Door(name: "TikTok")
        let model = freshModel(doors: [instagram, tiktok])

        await model.handle("give me twenty minutes of instagram")
        #expect(model.waiting != nil, "no wait was raised over a granted ask")
        #expect(model.remainingMinutes == 40, "the pool moved before the ink landed")

        // The intent is the other writer. Forced-arm so the grant stands —
        // on the simulator the honest path rolls it back, and a rolled-back
        // write is one landing never sees.
        WallController.testForceArmed = true
        defer { WallController.testForceArmed = nil }

        // **The wait is parked across the intent, and that is what makes this
        // test about ordering rather than about speed.** `performSpend` is an
        // await: on a loaded runner it can take longer than the 0.8 s price,
        // and the veil then lands BEFORE the intent's write exists — the
        // landing re-validates against the ledger it already had, answers with
        // the grant, and the failure reads as "the wait landed the verdict from
        // before the intent" when nothing was out of order at all. Parking
        // disarms the landing (`pauseWait` cancels the task) so the intent
        // cannot be raced, and the resume re-arms it over the ledger the intent
        // left behind. The property — a write that lands during the wait is
        // seen at landing — is unchanged; only the coin toss is gone.
        model.pauseWait()
        _ = try await performSpend(door: tiktok.name, minutes: 40)
        model.resumeWait()

        #expect(await settle { model.waiting == nil }, "the veil never came down")

        let reply = model.conversation.turns.last?.reply
        #expect(reply?.contains("0 \(SilkStrings.leftToday)") == true,
                "the wait landed the verdict from before the intent rather than the one that is true — read \"\(reply ?? "nil")\"")
        #expect(model.ledger.grants.contains { $0.doorID == instagram.id } == false,
                "a grant was recorded for a door with no minutes behind it")
    }

    @Test func aConcurrentMainActorLedgerWriteSurvivesTheGrantLeg() async throws {
        // Finding 7. The grant-record save used to put its in-memory ledger
        // wholesale, erasing a write that landed after the load. The hook
        // fires in that window so the race is the test, not a hope.
        let door = freshPolicy()
        let other = Door(name: "TikTok")
        let now = Date.now
        let interloper = Grant(door: other, minutes: 5, issuedAt: now,
                               expiresAt: now.addingTimeInterval(5 * 60))

        SpendIntent.beforeGrantSave = {
            var live = SharedStore.loadLedger()
            live.record(interloper)
            SharedStore.save(ledger: live)
        }
        defer { SpendIntent.beforeGrantSave = nil }

        _ = try await performSpend(door: door.name, minutes: 20)

        let after = SharedStore.loadLedger()
        #expect(after.grants.contains { $0.id == interloper.id },
                "the grant-record leg erased a write that landed after it loaded")
    }
}
