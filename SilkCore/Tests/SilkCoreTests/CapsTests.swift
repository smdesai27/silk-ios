import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// The cap compositions used to live in `AppModel`, where the only test target
// that could reach them was the thirteen-minute simulator — and no walk selects
// the No-cap seat, parks a cap loosening, or reaches a receipt with a grant
// running. Everything below is the coverage that did not exist.

private func capsAt(_ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
}

private func dayStart(_ now: Date) -> Date {
    DayBoundary.dayStart(now: now, downHours: night, calendar: cal)
}

private func policy(_ doors: [Door] = [reddit, tiktok, instagram],
                    budget: Int = 40,
                    caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: night, doors: doors, doorCaps: caps)
}

private func spent(_ door: Door, _ minutes: Int, from: Date) -> GrantLedger {
    var l = GrantLedger()
    l.record(Grant(door: door, minutes: minutes, issuedAt: from,
                   expiresAt: from.addingTimeInterval(TimeInterval(minutes * 60))))
    return l
}

// MARK: - The wheel's seats
//
// The +1 No-cap offset is the whole of `pickerColumns`/`commitPicker`'s index
// math, and an off-by-one there writes a ceiling the user never chose.

@Suite struct CapWheelSeatTests {
    @Test func everySeatRoundTripsThroughItsValue() {
        for cap in Caps.wheelTable {
            #expect(Caps.wheelMinutes(atSeat: Caps.wheelSeat(for: cap)) == cap)
        }
    }

    @Test func theFirstSeatIsAbsenceAndNotANumber() {
        #expect(Caps.wheelSeat(for: nil) == 0)
        #expect(Caps.wheelMinutes(atSeat: 0) == nil)
        #expect(Caps.wheelValues.first == SilkStrings.noCap)
    }

    @Test func theSeatStringsAndTheSeatValuesCannotDisagree() {
        // Derived, not written twice: the string list is one seat longer than
        // the table, and every numbered seat reads back its own value.
        #expect(Caps.wheelValues.count == Caps.wheelTable.count + 1)
        for seat in 1..<Caps.wheelValues.count {
            let minutes = Caps.wheelMinutes(atSeat: seat)
            #expect(Caps.wheelValues[seat] == "\(minutes!) \(SilkStrings.minutes)")
        }
    }

    @Test func anOffGridCeilingOpensOnItsNearestSeat() {
        // The bar takes any integer once the grammar lands; the wheel has eight
        // seats. 25 sits between 20 and 30 and opens on 20 (the first minimum).
        #expect(Caps.wheelMinutes(atSeat: Caps.wheelSeat(for: 25)) == 20)
        #expect(Caps.wheelMinutes(atSeat: Caps.wheelSeat(for: 7)) == 5)
        #expect(Caps.wheelMinutes(atSeat: Caps.wheelSeat(for: 500)) == 60)
    }

    @Test func tenMinutesIsTheSeatTheReportedCaseOpensOn() {
        // The seat `testWheelsOpenRestingOnTheSeatTheyWereGiven` measures a
        // scroll offset against — held here so the walk is not the only place it
        // lives. A simulator assertion whose expected value is derived nowhere is
        // a constant waiting to be tuned until the walk goes green.
        #expect(Caps.wheelSeat(for: 10) == 2)
        #expect(Caps.wheelValues[2] == "10 \(SilkStrings.minutes)")
        // The down-hours pair in that same walk is the same arithmetic on the
        // picker's other two tables: 9:00 PM is the third half-hour from 8:00 PM,
        // and 8:00 AM the seventh from 5:00 AM. `AppModel` owns those tables and
        // is not in the spine, so they are restated as the expressions that
        // build them rather than as two bare numbers.
        #expect(Caps.nearestIndex(to: 21 * 60, in: (0..<8).map { 20 * 60 + $0 * 30 }) == 2)
        #expect(Caps.nearestIndex(to: 8 * 60, in: (0..<8).map { 5 * 60 + $0 * 30 }) == 6)
    }

    @Test func aSeatBeyondTheTableClampsRatherThanTraps() {
        #expect(Caps.wheelMinutes(atSeat: 99) == Caps.wheelTable.last)
    }

    @Test func theSettingsRowReadsBackWhatTheWheelWouldShow() {
        #expect(Caps.settingsValue(cap: 20) == "20 \(SilkStrings.minutes)")
        #expect(Caps.settingsValue(cap: nil) == SilkStrings.noCap)
        // The row's value for a capped door is the wheel's own seat string.
        #expect(Caps.settingsValue(cap: 20) == Caps.wheelValues[Caps.wheelSeat(for: 20)])
    }
}

// MARK: - The receipt
//
// The only feedback a Settings cap commit produces.

@Suite struct CapReceiptTests {
    @Test func anOrdinaryTightenNamesTheDoorAndTheCeiling() {
        let now = capsAt(10)
        let before = policy()
        let after = policy(caps: [tiktok.id: 20])
        #expect(Caps.receipt(for: after, movedFrom: before, ledger: GrantLedger(),
                             now: now, dayStart: dayStart(now), calendar: cal)
                == "TikTok 20 \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay).")
    }

    @Test func aCeilingAlreadyBittenSaysWhenTheDoorLifts() {
        // 30 spent this morning, capped at 20 this afternoon, nothing running.
        let now = capsAt(15)
        let ledger = spent(reddit, 30, from: capsAt(10))
        let after = policy(caps: [reddit.id: 20])
        #expect(Caps.receipt(for: after, movedFrom: policy(), ledger: ledger,
                             now: now, dayStart: dayStart(now), calendar: cal)
                == "Reddit \(SilkStrings.closedUntil) 7:00.")
    }

    /// REGRESSION PIN. Budget 40, Reddit uncapped. At 10:00 a 30-minute grant
    /// lands, running to 10:30. At 10:05 she caps Reddit at 20 from the wheel.
    ///
    /// Before the fix this said "Reddit closed until 7:00." while, in the same
    /// second, `state(of:)` returned `.open(until: 10:30)`, the Now row drew
    /// `· till 10:30`, `Wall.reconcile` still excepted the token, and the
    /// Validator answered `.restated`. Four surfaces, one door, one second, and
    /// the only one she is shown was the false one.
    @Test func aRunningGrantOutranksTheCeilingTheReceiptJustSet() {
        let now = capsAt(10, 5)
        let ledger = spent(reddit, 30, from: capsAt(10))          // expires 10:30
        let after = policy(caps: [reddit.id: 20])

        // The premise: the door really is open, and really is out of ceiling.
        #expect(ledger.activeGrant(for: reddit, at: now)?.expiresAt == capsAt(10, 30))
        #expect(ledger.remainingMinutes(cap: 20, doorID: reddit.id,
                                        dayStart: dayStart(now)) == 0)
        #expect(ledger.state(of: reddit, at: now, dayStart: dayStart(now),
                             cap: 20, calendar: cal) == .open(until: capsAt(10, 30)))

        // So the receipt names the ceiling, and does not claim a shut door.
        #expect(Caps.receipt(for: after, movedFrom: policy(), ledger: ledger,
                             now: now, dayStart: dayStart(now), calendar: cal)
                == "Reddit 20 \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay).")
    }

    @Test func theShutSentenceReturnsTheMomentTheGrantExpires() {
        // Same state, five minutes after the grant ran out. Nothing else moved.
        let now = capsAt(10, 31)
        let ledger = spent(reddit, 30, from: capsAt(10))
        #expect(Caps.receipt(for: policy(caps: [reddit.id: 20]), movedFrom: policy(),
                             ledger: ledger, now: now, dayStart: dayStart(now), calendar: cal)
                == "Reddit \(SilkStrings.closedUntil) 7:00.")
    }

    @Test func aClearedCeilingHasNoReceiptOfItsOwn() {
        // A clear is a loosening: it parks, and "Applies tomorrow." is the reply.
        let now = capsAt(10)
        #expect(Caps.receipt(for: policy(), movedFrom: policy(caps: [tiktok.id: 20]),
                             ledger: GrantLedger(), now: now, dayStart: dayStart(now),
                             calendar: cal) == nil)
    }

    @Test func aRemovedDoorTakesItsCapWithoutClaimingACapChange() {
        let now = capsAt(10)
        let before = policy(caps: [tiktok.id: 20])
        let after = policy([reddit, instagram])       // TikTok and its cap gone
        #expect(Caps.receipt(for: after, movedFrom: before, ledger: GrantLedger(),
                             now: now, dayStart: dayStart(now), calendar: cal) == nil)
    }

    /// A budget change is not a ceiling change, so `receipt` — which composes
    /// the CAP sentence and nothing else — has nothing to say about it and
    /// returns nil. The old name, "leaves the pool sentence standing", claimed
    /// a fact about a sentence this function neither writes nor knows of; what
    /// the body asserts is the silence.
    @Test func aBudgetChangeComposesNoCapReceipt() {
        let now = capsAt(10)
        var after = policy()
        after.budgetMinutes = 30
        #expect(Caps.receipt(for: after, movedFrom: policy(), ledger: GrantLedger(),
                             now: now, dayStart: dayStart(now), calendar: cal) == nil)
    }

    @Test func twoMovedCeilingsNameTheFirstInDoorOrderEveryTime() {
        let now = capsAt(10)
        let before = policy()
        let after = policy(caps: [tiktok.id: 20, reddit.id: 30])
        // Doors are [Reddit, TikTok, Instagram]; the dictionary's order is not.
        // ONE call, not twenty. `receipt` is pure and its argument is one
        // dictionary instance, whose iteration order is fixed for the life of
        // that instance — so twenty calls in a row could only ever agree with
        // each other, and the seed that WOULD vary the order varies per process
        // and is therefore already varied by every run of the suite. A door
        // list walked in dictionary order picks TikTok about half the time; a
        // door list walked in `doors` order picks Reddit every time, on every
        // seed, and this is that assertion.
        #expect(Caps.receipt(for: after, movedFrom: before, ledger: GrantLedger(),
                             now: now, dayStart: dayStart(now), calendar: cal)
                == "Reddit 30 \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay).")
    }
}

// MARK: - The pending row
//
// The whole cap-CLEAR round trip: seat 0 → a loosening that parks → the one row
// on Now that can see it and the one button that can spend the key on it.

@Suite struct CapPendingSummaryTests {
    @Test func aParkedRaiseNamesTheDoorAndTheNewCeiling() {
        let live = policy(caps: [tiktok.id: 20])
        let next = policy(caps: [tiktok.id: 45])
        #expect(Caps.pendingSummary(next: next, live: live) == "TikTok 45")
    }

    @Test func aParkedClearingSaysNoCapInTheRowsOwnVoice() {
        let live = policy(caps: [tiktok.id: 20])
        #expect(Caps.pendingSummary(next: policy(), live: live) == "TikTok no cap")
    }

    @Test func aCeilingLoweredBackToTheBaselineLeavesNoRow() {
        // Park a raise 20 → 45, then tighten to 20 again: the merge delivers
        // nothing, so the row and its "Apply now." button both go.
        let live = policy(caps: [tiktok.id: 20])
        #expect(Caps.pendingSummary(next: live, live: live) == nil)
    }

    @Test func aRemovedDoorTakesItsPendingRowWithIt() {
        let live = policy([reddit, instagram])                 // TikTok removed
        let next = policy([reddit, instagram], caps: [tiktok.id: 45])
        #expect(Caps.pendingSummary(next: next, live: live) == nil)
    }

    /// ONE call, for the reason `twoMovedCeilingsNameTheFirstInDoorOrderEveryTime`
    /// states at length: `pendingSummary` is pure, the dictionary it is handed
    /// is one instance whose iteration order does not change inside a process,
    /// and the hashing seed that would change it is already re-rolled on every
    /// run of the suite. Twenty identical calls agreed with each other and with
    /// nothing else. Doors are [Reddit, TikTok, Instagram], so `doors` order
    /// says TikTok and a dictionary walk says either.
    @Test func theRowNamesTheFirstDoorInDoorOrderEveryTime() {
        let live = policy()
        let next = policy(caps: [tiktok.id: 45, instagram.id: 30])
        #expect(Caps.pendingSummary(next: next, live: live) == "TikTok 45")
    }

    // The card's half of the same fact: the value alone, because the card is
    // already titled with the door's name.

    @Test func theCardSaysTheValueAloneBecauseItHasNamedTheDoor() {
        let live = policy(caps: [tiktok.id: 20])
        #expect(Caps.pendingValue(next: policy(caps: [tiktok.id: 45]), live: live,
                                  door: tiktok) == "45")
        #expect(Caps.pendingValue(next: policy(), live: live, door: tiktok) == "no cap")
    }

    @Test func aDoorWithNothingWaitingOnItSaysNothingOnItsCard() {
        let live = policy(caps: [tiktok.id: 20])
        // The ask is on TikTok; Instagram's card must not draw a pending row.
        #expect(Caps.pendingValue(next: policy(), live: live, door: instagram) == nil)
        #expect(Caps.pendingValue(next: live, live: live, door: tiktok) == nil)
    }

    /// The card and the row are two renderings of one waiting fact, and they are
    /// composed from one call so they cannot drift. If `pendingSummary` ever
    /// stops being "name, space, value", this is what says so.
    @Test func theRowIsTheCardsLineWithTheDoorNamedInFrontOfIt() {
        let live = policy(caps: [tiktok.id: 20])
        for next in [policy(), policy(caps: [tiktok.id: 45])] {
            let value = Caps.pendingValue(next: next, live: live, door: tiktok)!
            #expect(Caps.pendingSummary(next: next, live: live) == "\(tiktok.name) \(value)")
        }
    }
}

// MARK: - The receipt a parked loosening leaves
//
// The reply that made clearing a cap read as broken. "Applies tomorrow." is
// seventeen characters carrying no user data, byte-identical after a budget
// raise, a shortened night and a cleared ceiling — and every loosening, by rule
// 3, is a gesture that visibly changes nothing. A constant answer over an
// unchanged screen is indistinguishable from a dropped command.

@Suite struct ParkedReceiptTests {
    @Test func theReplyNamesWhatIsWaiting() {
        #expect(SilkStrings.parked("Reddit no cap") == "Tomorrow: Reddit no cap")
        #expect(SilkStrings.parked("60") == "Tomorrow: 60")
    }

    /// It is composed from `tomorrow`, not from a second sentence about
    /// tomorrow: the row on Now already prefixes its line with that word, so the
    /// toast and the row read alike.
    @Test func itIsTheRowsOwnWordAndNotAThirdOne() {
        #expect(SilkStrings.parked("60").hasPrefix(SilkStrings.tomorrow))
    }

    /// A loosening no surface can summarise — turning the wall itself off has no
    /// pending row and no card — still gets an answer. "Tomorrow:" with nothing
    /// after it would be worse than the constant it replaces.
    ///
    /// Pinned to the SENTENCE and not to the constant. The constant is private
    /// now — `parked` is the only reader — and `parked(nil) == appliesTomorrow`
    /// was the same expression twice: it could not have failed while the
    /// fallback existed at all, whatever the fallback said.
    @Test func aLooseningNothingCanNameFallsBackToTheConstant() {
        #expect(SilkStrings.parked(nil) == "Applies tomorrow.")
    }

    /// THE GEOMETRY PIN, and the reason it is a test rather than a comment.
    ///
    /// `Silk/Toast.swift` sets `.lineLimit(1)` and `.fixedSize(horizontal: true,
    /// …)`, so an over-long capsule grows past the glass and clips rather than
    /// folding. The worst case is the CLEARING form on the longest name in the
    /// launch catalogue — "Tomorrow: Instagram no cap", 26 characters, which
    /// measures 177pt at `Silk.sans(13, .medium)`; beside "Apply now." and the
    /// capsule's 36pt of padding that is 293pt of the 375 on the narrowest
    /// device Silk supports. It fits with 82pt to spare.
    ///
    /// Door names come from this catalogue and nowhere else — `addDoor` is
    /// reached only from the add overlay's chips and setup's, and the bar's
    /// `.addDoor` is refused with "Add it in Settings." — so the bound is real.
    /// A thirteenth name three characters longer than "Instagram" would take the
    /// capsule to roughly 350pt and start crowding the glass; this fails first.
    @Test func theWidestReceiptTheCatalogueCanProduceStillFitsOnTheGlass() {
        for entry in LaunchCatalog.entries {
            let door = Door(name: entry.display)
            let live = policy([door], caps: [door.id: 20])
            let summary = Caps.pendingSummary(next: policy([door]), live: live)
            #expect(SilkStrings.parked(summary).count <= 26,
                    "\(entry.display) makes a receipt too wide for the capsule")
        }
    }
}

// MARK: - The undo's cap half

@Suite struct CapRestoreTests {
    @Test func onlyTheCeilingsThisTurnMovedComeBack() {
        // The turn capped TikTok at 20. Reddit was capped at 30 in between, in
        // the five minutes the undo window can run, and must survive the undo.
        let previous = [instagram.id: 15]
        let proposed = [instagram.id: 15, tiktok.id: 20]
        let live = [instagram.id: 15, tiktok.id: 20, reddit.id: 30]
        let restored = Caps.restoring(previous, over: proposed, into: live)
        #expect(restored.caps[tiktok.id] == nil)
        #expect(restored.caps[reddit.id] == 30)
        #expect(restored.caps[instagram.id] == 15)
        #expect(restored.changed)
    }

    @Test func aCeilingTheProposalClearedIsPutBack() {
        let previous = [tiktok.id: 20]
        let proposed: [UUID: Int] = [:]
        let restored = Caps.restoring(previous, over: proposed, into: proposed)
        #expect(restored.caps[tiktok.id] == 20)
        #expect(restored.changed)
    }

    @Test func aTurnThatMovedNoCeilingRestoresNothing() {
        let caps = [tiktok.id: 20]
        let restored = Caps.restoring(caps, over: caps, into: caps)
        #expect(restored.caps == caps)
        #expect(restored.changed == false, "an offer with nothing to put back reported a restore")
    }

    /// **A LATER TURN ON THE SAME DOOR OWNS IT NOW.** Two ceilings said inside
    /// one undo window — "cap tiktok at 20", then "cap tiktok at 10" — and the
    /// older pill is tapped. It used to write 20 over the live 10: a LOOSENING
    /// applied instantly, which is the one thing canon forbids, from a control
    /// that promises to undo one turn. It also destroyed the second turn's
    /// tighten with no receipt, while that turn's own pill still stood offering
    /// to put back 20.
    @Test func aCeilingOverwrittenSinceIsNotPutBack() {
        let previous: [UUID: Int] = [:]
        let proposed = [tiktok.id: 20]     // what the first turn wrote
        let live = [tiktok.id: 10]         // what the second turn wrote over it
        let restored = Caps.restoring(previous, over: proposed, into: live)
        #expect(restored.caps[tiktok.id] == 10, "the older offer loosened a newer ceiling")
        #expect(restored.changed == false, "an expired offer reported a restore it did not make")
    }

    /// The same rule where the later hand CLEARED the ceiling instead of
    /// lowering it: the door has no cap now because someone asked for none, and
    /// an older offer may not put one back.
    @Test func aCeilingClearedSinceIsNotPutBack() {
        let previous: [UUID: Int] = [:]
        let proposed = [tiktok.id: 20]
        let live: [UUID: Int] = [:]
        let restored = Caps.restoring(previous, over: proposed, into: live)
        #expect(restored.caps[tiktok.id] == nil, "an older offer re-imposed a ceiling that was removed")
        #expect(restored.changed == false)
    }
}

// MARK: - The wall's subtitle
//
// "Open Silk · 30 left today" is a promise, and the only thing that can keep it
// is the arithmetic the bar itself uses.

@Suite struct AskableMinutesTests {
    private func askable(_ p: PolicyState, _ l: GrantLedger, _ now: Date,
                         _ door: Door = reddit) -> Int {
        Validator.askableMinutes(door: door, state: p, ledger: l, now: now,
                                 dayStart: dayStart(now), calendar: cal)
    }

    @Test func anUncappedDoorIsOfferedThePool() {
        #expect(askable(policy(), GrantLedger(), capsAt(15)) == 40)
    }

    @Test func aCeilingBindsBelowThePool() {
        #expect(askable(policy(caps: [reddit.id: 30]), GrantLedger(), capsAt(15)) == 30)
    }

    @Test func aSpentCeilingOffersNothing() {
        let l = spent(reddit, 30, from: capsAt(10))
        #expect(askable(policy(caps: [reddit.id: 30]), l, capsAt(15)) == 0)
        // …and the pool it does not touch is still there for another door.
        #expect(askable(policy(caps: [reddit.id: 30]), l, capsAt(15), tiktok) == 10)
    }

    @Test func aDoorClosedByHandOffersNothing() {
        var l = GrantLedger()
        l.closeDoor(reddit, at: capsAt(12), until: capsAt(21))
        #expect(askable(policy(), l, capsAt(15)) == 0)
    }

    /// REGRESSION PIN. Down hours 22:00, budget 40, nothing spent, no ceiling,
    /// clock 21:50. The shield used to render "Open Silk · 40 left today"; the
    /// bar mints ten, because a grant cannot cross the edge.
    @Test func theDownHoursEdgeBindsLikeEveryOtherClamp() {
        #expect(askable(policy(), GrantLedger(), capsAt(21, 50)) == 10)
        #expect(askable(policy(caps: [reddit.id: 30]), GrantLedger(), capsAt(21, 50)) == 10)
    }

    @Test func insideTheNightThereIsNothingToAskFor() {
        #expect(askable(policy(), GrantLedger(), capsAt(23)) == 0)
        #expect(askable(policy(), GrantLedger(), capsAt(22)) == 0)
    }

    /// The property the wall rests on: whatever this says she may have, asking
    /// for exactly that at the bar grants exactly that. If a clamp is ever added
    /// to the `.spend` arm and not here, this fails rather than shipping a wall
    /// that promises what Silk refuses.
    ///
    /// No fixture carries a LIVE grant, and the omission is the point rather
    /// than a gap: with one running the bar answers `.restated` and mints
    /// nothing, so the equality below would not hold — and it does not need to.
    /// A door with a live grant is excepted from the wall by `openDoors`, so the
    /// shield never renders for it and `askableMinutes` is never asked. Adding
    /// such a fixture would pin a number no surface reads. What this asserts is
    /// therefore the property for every state the SHIELD can actually be in.
    @Test func theWallPromisesOnlyWhatTheBarWillMint() {
        var closed = GrantLedger()
        closed.closeDoor(reddit, at: capsAt(12), until: capsAt(21))

        let fixtures: [(String, PolicyState, GrantLedger, Date)] = [
            ("plain", policy(), GrantLedger(), capsAt(15)),
            ("capped", policy(caps: [reddit.id: 30]), GrantLedger(), capsAt(15)),
            ("cap under pool", policy(caps: [reddit.id: 5]), GrantLedger(), capsAt(15)),
            ("pool under cap", policy(budget: 10, caps: [reddit.id: 60]), GrantLedger(), capsAt(15)),
            ("part spent", policy(caps: [reddit.id: 30]), spent(reddit, 10, from: capsAt(10)), capsAt(15)),
            ("cap spent", policy(caps: [reddit.id: 30]), spent(reddit, 30, from: capsAt(10)), capsAt(15)),
            ("pool spent", policy(), spent(tiktok, 40, from: capsAt(10)), capsAt(15)),
            ("closed by hand", policy(), closed, capsAt(15)),
            ("near the edge", policy(), GrantLedger(), capsAt(21, 50)),
            ("at the edge", policy(), GrantLedger(), capsAt(22)),
            ("inside the night", policy(), GrantLedger(), capsAt(23)),
        ]

        for (name, p, l, now) in fixtures {
            let a = Validator.askableMinutes(door: reddit, state: p, ledger: l, now: now,
                                             dayStart: dayStart(now), calendar: cal)
            let ask = max(a, 1)          // at zero, ask for something and be refused
            let verdict = Validator.validate(.command(.spend(door: reddit, minutes: ask)),
                                             utterance: "\(ask) minutes of reddit",
                                             state: p, ledger: l, now: now, calendar: cal)
            if a > 0 {
                guard case .grant(_, let minutes, _) = verdict else {
                    Issue.record("\(name): askable \(a) but the bar answered \(verdict)")
                    continue
                }
                #expect(minutes == a, "\(name): the wall promised \(a), the bar minted \(minutes)")
            } else {
                if case .grant = verdict {
                    Issue.record("\(name): askable 0 but the bar granted anyway")
                }
            }
        }
    }
}

// MARK: - The status clause

@Suite struct RuleInForceTests {
    @Test func aDoorClosedByHandIsNamedOverACappedOutOne() {
        // TikTok sorts before Instagram and is capped out; Instagram was closed
        // by hand a second ago, and that is the fact the clause exists to state.
        let now = capsAt(15)
        var l = spent(tiktok, 20, from: capsAt(10))
        l.closeDoor(instagram, at: capsAt(14), until: nil)
        let p = policy([tiktok, instagram], caps: [tiktok.id: 20])
        let rule = l.ruleInForce(for: p, at: now, dayStart: dayStart(now), calendar: cal)
        #expect(rule?.door == instagram)
        #expect(rule?.lifts == nil)
    }

    @Test func aCappedOutDoorIsStillNamedWhenNothingWasClosedByHand() {
        let now = capsAt(15)
        let l = spent(tiktok, 20, from: capsAt(10))
        let p = policy([reddit, tiktok], caps: [tiktok.id: 20])
        #expect(l.ruleInForce(for: p, at: now, dayStart: dayStart(now), calendar: cal)?.door
                == tiktok)
    }

    @Test func aStatedHourRidesOutWithTheDoor() {
        let now = capsAt(15)
        var l = GrantLedger()
        l.closeDoor(reddit, at: capsAt(14), until: capsAt(21))
        #expect(l.ruleInForce(for: policy(), at: now, dayStart: dayStart(now),
                              calendar: cal)?.lifts == capsAt(21))
    }

    @Test func aDayWithNoRuleInForceNamesNothing() {
        let now = capsAt(15)
        #expect(GrantLedger().ruleInForce(for: policy(), at: now, dayStart: dayStart(now),
                                          calendar: cal) == nil)
    }

    /// A door that satisfies `isClosed` but is NOT at rest — a hand-close that a
    /// live grant outranks — must not swallow the clause. The preferred search
    /// and the fallback are one pass over the same `.rest` test, so the fallback
    /// cannot be stranded by a preference that does not hold.
    @Test func aPreferenceThatDoesNotHoldCannotStrandTheFallback() {
        let now = capsAt(15)
        // TikTok is capped out. Reddit is recorded closed today AND carries a
        // grant running past `now` — a state `closeDoor` cannot produce, because
        // it truncates live grants, but one the ledger's own initialiser can
        // hold, and the clause must not lose TikTok to it either way.
        let l = GrantLedger(
            grants: [Grant(door: tiktok, minutes: 20, issuedAt: capsAt(10), expiresAt: capsAt(10, 20)),
                     Grant(door: reddit, minutes: 30, issuedAt: capsAt(14, 50), expiresAt: capsAt(15, 20))],
            closedToday: [reddit.id: capsAt(14)])
        let p = policy([reddit, tiktok], caps: [tiktok.id: 20])

        #expect(l.isClosed(reddit.id, at: now, dayStart: dayStart(now)))
        #expect(l.state(of: reddit, at: now, dayStart: dayStart(now), cap: nil,
                        calendar: cal) == .open(until: capsAt(15, 20)))
        // The capped-out door is still named.
        #expect(l.ruleInForce(for: p, at: now, dayStart: dayStart(now), calendar: cal)?.door
                == tiktok)
    }
}

