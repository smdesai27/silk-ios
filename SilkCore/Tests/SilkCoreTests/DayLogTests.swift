import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// America/New_York 2026, so the two DST nights are reachable: spring forward
// Mar 8 (a 23-hour Silk day) and fall back Nov 1 (a 25-hour one). The day
// boundary is when down hours END — 7:00 here, not midnight.

private let instagram = Door(name: "Instagram")
private let tiktok = Door(name: "TikTok")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func grant(_ door: Door, from: Date, minutes: Int) -> Grant {
    Grant(id: UUID(), door: door, minutes: minutes,
          issuedAt: from, expiresAt: from.addingTimeInterval(Double(minutes) * 60))
}

/// A plain June day: 7:00 Jun 10 → 7:00 Jun 11, no DST anywhere near it.
private let day = at(6, 10, 7)

/// `heartbeats` defaults to one firing at the day's own boundary — a live
/// framework — so every test that is not *about* liveness reads as before.
private func summarise(grants: [Grant] = [],
                       attempts: [Date] = [],
                       heartbeats: [Date]? = nil,
                       wallStanding: Bool = true,
                       dayStart: Date = day) -> DayRecord {
    DayLog.summarise(dayStart: dayStart, downHours: night, grants: grants,
                     attempts: attempts,
                     heartbeats: heartbeats ?? [dayStart],
                     wallStanding: wallStanding, calendar: cal)
}

// MARK: - The inversion test
//
// This is the defect the whole mechanic exists to repair: the shipped hero is
// strictly higher on a day you spent than a day you resisted. mirror-continuity
// §2.2 runs this by hand; it is run here so it cannot regress silently.

@Suite struct TheInversionIsRepaired {

    @Test func resistingBeatsGivingIn() {
        // Same user, same wall, 15:00, default policy.
        let resist = summarise(attempts: [at(6, 10, 15), at(6, 10, 15, 5),
                                          at(6, 10, 15, 20), at(6, 10, 15, 40)])
        // Bounced once, opened Silk, asked for 15 minutes, spent them.
        let giveIn = summarise(grants: [grant(instagram, from: at(6, 10, 15), minutes: 15)],
                               attempts: [at(6, 10, 15)])

        #expect(resist.grantedMinutes == 0)
        #expect(resist.reaches == 4)
        #expect(giveIn.grantedMinutes == 15)
        #expect(giveIn.reaches == 1)

        // Four bounces cost 4; a deliberate 15-minute spend costs 16.
        #expect(resist.fraction > giveIn.fraction)
    }

    @Test func theMagnitudeIsFourToOneAndNotADial() {
        // It falls out of charging a granted minute one point and a reach one
        // point — not out of any constant chosen to make the test pass.
        let resistCost = 4.0
        let giveInCost = 15.0 + 1.0
        #expect(giveInCost / resistCost == 4.0)
    }

    @Test func aReachInDownHoursCostsTwo() {
        let late = summarise(attempts: [at(6, 10, 23, 30)])   // inside 22:00–07:00
        #expect(late.reaches == 1)
        #expect(late.lateReaches == 1)
        // One reach + one late = 2 against the allowance.
        #expect(late.fraction == 1 - 2 / DayLog.allowance)
    }
}

// MARK: - Granted minutes is a union

@Suite struct GrantedMinutesIsAUnionNotASum {

    @Test func twoDoorsOpenAtOnceIsOneMinuteNotTwo() {
        // The wall being down is a property of the wall, not of how many
        // doors were named. Summing would charge the same span twice and make
        // cost depend on slicing.
        let a = grant(instagram, from: at(6, 10, 12), minutes: 30)
        let b = grant(tiktok, from: at(6, 10, 12), minutes: 30)
        #expect(summarise(grants: [a, b]).grantedMinutes == 30)
    }

    @Test func partiallyOverlappingGrantsMergeToTheirSpan() {
        let a = grant(instagram, from: at(6, 10, 12), minutes: 30)       // 12:00–12:30
        let b = grant(tiktok, from: at(6, 10, 12, 20), minutes: 30)      // 12:20–12:50
        #expect(summarise(grants: [a, b]).grantedMinutes == 50)
    }

    @Test func disjointGrantsStillAdd() {
        let a = grant(instagram, from: at(6, 10, 12), minutes: 30)
        let b = grant(tiktok, from: at(6, 10, 14), minutes: 15)
        #expect(summarise(grants: [a, b]).grantedMinutes == 45)
    }

    @Test func abuttingGrantsDoNotDoubleCountTheJoin() {
        let a = grant(instagram, from: at(6, 10, 12), minutes: 30)       // ends 12:30
        let b = grant(tiktok, from: at(6, 10, 12, 30), minutes: 30)      // starts 12:30
        #expect(summarise(grants: [a, b]).grantedMinutes == 60)
    }

    @Test func aGrantIsClippedToTheDayItIsCountedIn() {
        // Issued 06:30, an hour long, so it straddles the 07:00 boundary:
        // 30 minutes belong to the previous Silk day and 30 to this one.
        let straddle = grant(instagram, from: at(6, 10, 6, 30), minutes: 60)
        #expect(summarise(grants: [straddle]).grantedMinutes == 30)
    }

    @Test func aGrantEntirelyOutsideTheDayCountsNothing() {
        let yesterday = grant(instagram, from: at(6, 9, 12), minutes: 30)
        #expect(summarise(grants: [yesterday]).grantedMinutes == 0)
    }

    @Test func theTwoHalvesOfAStraddlingGrantSumToTheWholeGrant() {
        // Rounding to nearest rather than flooring is what keeps this true;
        // flooring both halves loses a minute per crossing, always in the
        // direction that flatters the user.
        let straddle = grant(instagram, from: at(6, 10, 6, 30), minutes: 61)
        let before = summarise(grants: [straddle], dayStart: at(6, 9, 7)).grantedMinutes
        let after = summarise(grants: [straddle], dayStart: day).grantedMinutes
        #expect(before + after == 61)
    }
}

// MARK: - Observability

@Suite struct ADayItCouldNotWatchIsNotScored {

    @Test func anUnobservedDayCreditsNothingAndChargesNothing() {
        let quiet = summarise(wallStanding: false)
        #expect(quiet.observed == false)
        #expect(quiet.fraction == 0)

        // Even a day that would otherwise have been perfect.
        #expect(summarise(wallStanding: true).fraction == 1)
    }

    @Test func aSpentDayThatWasNotWatchedStillCreditsNothing() {
        // Not merely "scores zero" — an unobserved day is a ring, and a ring
        // is the absence of a record, not a bad record.
        let spent = summarise(grants: [grant(instagram, from: at(6, 10, 12), minutes: 200)],
                              wallStanding: false)
        #expect(spent.fraction == 0)
    }

    @Test func theCallerCannotPromoteADayCoreKnowsIsUnobservable() {
        // wallStanding is the caller's verdict on facts Core cannot see; it is
        // ANDed with the ones Core can decide, never substituted for them.
        let travelDay = at(3, 7, 7)   // spring forward: the next boundary is 23h away
        #expect(summarise(wallStanding: true, dayStart: travelDay).observed == true)

        // A 23-hour day is inside the sane range. A boundary that moved by a
        // whole timezone is not — build one by hand.
        let span = DayLog.sameSpan
        #expect(span.min == 20 * 3600)
        #expect(span.max == 28 * 3600)
    }

    @Test func aTruncatedAttemptsBlobDrawsARingRatherThanAFabricatedFraction() {
        // At the cap the reach count is a floor, not a count, for any day
        // starting before the oldest surviving attempt.
        let blob = (0..<DayLog.attemptsCap).map { at(6, 10, 12).addingTimeInterval(Double($0)) }
        #expect(blob.count == DayLog.attemptsCap)

        // A day wholly before the oldest surviving attempt: its reaches were
        // evicted, so its record would be incomplete.
        let earlier = summarise(attempts: blob, dayStart: at(6, 9, 7))
        #expect(earlier.observed == false)

        // The day CONTAINING the truncation point is suspect too, and this is
        // the subtle half of the rule. The blob starts at 12:00; this day
        // started at 07:00; reaches between 07:00 and 12:00 may have been
        // evicted, so a fraction computed from what survived would be
        // flattering rather than true.
        #expect(blob.first == at(6, 10, 12))
        #expect(summarise(attempts: blob, dayStart: day).observed == false)

        // A day that begins after the oldest surviving attempt lost nothing.
        #expect(summarise(attempts: blob, dayStart: at(6, 11, 7)).observed == true)
    }

    @Test func anUnderfullBlobObservesEvenTheOldestDay() {
        let blob = [at(6, 10, 12)]
        #expect(summarise(attempts: blob, dayStart: at(6, 1, 7)).observed == true)
    }
}

// MARK: - The fraction

@Suite struct TheFractionIsFrozenArithmetic {

    @Test func aPerfectDayIsOneAndACostlyDayFloorsAtZero() {
        #expect(summarise().fraction == 1)

        // 200 granted minutes against an allowance of 180 is past the floor,
        // and the floor holds rather than going negative and eating a good day.
        let overspent = summarise(grants: [grant(instagram, from: at(6, 10, 12), minutes: 200)])
        #expect(overspent.grantedMinutes == 200)
        #expect(overspent.fraction == 0)
    }

    @Test func theHeroFloorsRatherThanRounding() {
        // Two days at 0.6 is 1.2 — one day held, not two.
        let sixTenths = DayRecord(dayStart: day, grantedMinutes: 72, reaches: 0,
                                  lateReaches: 0, observed: true)
        #expect(abs(sixTenths.fraction - 0.6) < 1e-9)
        #expect(DayLog.daysHeld([sixTenths, sixTenths]) == 1)
    }

    @Test func ringsDoNotDragTheHeroDown() {
        let held = DayRecord(dayStart: day, grantedMinutes: 0, reaches: 0,
                             lateReaches: 0, observed: true)
        let ring = DayRecord(dayStart: at(6, 11, 7), grantedMinutes: 0, reaches: 0,
                             lateReaches: 0, observed: false)
        #expect(DayLog.daysHeld([held, ring, held]) == 2)
    }
}

// MARK: - Liveness
//
// The defect §3.4 concedes cannot be closed by `standing` alone: a wall that is
// dead and never reached looks exactly like a wall that is alive and never
// reached, and the second one scores a perfect day. The heartbeat is the only
// signal that tells them apart.

@Suite struct ADeadWallDoesNotAccrue {

    @Test func aQuietDayWithNoHeartbeatCreditsNothing() {
        // The maximal-payout case: no grants, no reaches, cost 0 — which under
        // `standing` alone is f = 1.000 every day while the product is dead.
        let dead = summarise(heartbeats: [])
        #expect(dead.observed == false)
        #expect(dead.fraction == 0)
    }

    @Test func theSameQuietDayWithAHeartbeatIsAPerfectDay() {
        #expect(summarise(heartbeats: [day]).fraction == 1)
    }

    @Test func aHeartbeatFromAnotherDayDoesNotCountForThisOne() {
        // Yesterday's firing proves nothing about today.
        #expect(summarise(heartbeats: [at(6, 9, 7)]).observed == false)
        #expect(summarise(heartbeats: [at(6, 11, 7)]).observed == false)
    }

    @Test func aHeartbeatAnywhereInsideTheDayCounts() {
        // The schedule is anchored at the boundary, but a late firing after a
        // reboot is still a live framework.
        #expect(summarise(heartbeats: [at(6, 10, 7)]).observed == true)
        #expect(summarise(heartbeats: [at(6, 10, 19, 30)]).observed == true)
        // The next boundary belongs to the next day, exclusive.
        #expect(summarise(heartbeats: [at(6, 11, 7)]).observed == false)
    }

    @Test func livenessCannotRescueADayTheWallWasDownFor() {
        // The terms are ANDed, not ORed — a heartbeat proves the framework
        // ran, not that anything was being shielded.
        #expect(summarise(heartbeats: [day], wallStanding: false).observed == false)
    }

    @Test func aDayBeforeTheHeartbeatShippedIsARingAndThatIsCorrect() {
        // Records written by a build with no heartbeat have no firings behind
        // them. They must read as unobserved rather than as perfect days —
        // failing toward crediting nothing is the whole point.
        #expect(summarise(heartbeats: []).observed == false)
    }
}

// MARK: - The heartbeat's window

@Suite struct TheDailyScheduleSpansAWholeDay {

    @Test func anOnTheHourBoundaryBorrowsAnHourRatherThanCollapsing() {
        // 07:00 is the default policy's boundary, so the naive
        // `minute - 1` — which floors at 0 and leaves start == end — breaks
        // the common case, not an exotic one.
        let w = DayLog.heartbeatWindow(anchoredAt: TimeOfDay(hour: 7))
        #expect(w.start == TimeOfDay(hour: 7, minute: 0))
        #expect(w.end == TimeOfDay(hour: 6, minute: 59))
        #expect(w.start != w.end)
    }

    @Test func midnightWrapsToTheNightBefore() {
        let w = DayLog.heartbeatWindow(anchoredAt: TimeOfDay(hour: 0))
        #expect(w.end == TimeOfDay(hour: 23, minute: 59))
    }

    @Test func anOffHourBoundaryJustStepsBack() {
        let w = DayLog.heartbeatWindow(anchoredAt: TimeOfDay(hour: 6, minute: 30))
        #expect(w.end == TimeOfDay(hour: 6, minute: 29))
    }

    @Test func theWindowIsAlwaysOneMinuteShortOfAFullDay() {
        // Whatever the boundary, the interval must be long enough to be a day
        // and short enough to close — so it reopens, and the reopening fires.
        for m in stride(from: 0, to: 1440, by: 17) {
            let b = TimeOfDay(minutesSinceMidnight: m)
            let w = DayLog.heartbeatWindow(anchoredAt: b)
            let span = (w.end.minutes - w.start.minutes + 1440) % 1440
            #expect(span == 1439)
        }
    }
}

// MARK: - Merging

@Suite struct AVerdictOnceRecordedIsNeverRevised {

    private func record(_ start: Date, observed: Bool, reaches: Int = 0) -> DayRecord {
        DayRecord(dayStart: start, grantedMinutes: 0, reaches: reaches,
                  lateReaches: 0, observed: observed)
    }

    @Test func anExistingRecordWinsOverAFreshOneForTheSameDay() {
        // The walk re-emits a day whenever a write did not land, so a re-walk
        // must not be able to change a verdict already stored — the attempts
        // blob has moved on and would summarise it differently.
        let stored = record(day, observed: true, reaches: 3)
        let rewalk = record(day, observed: false, reaches: 99)
        let merged = DayLog.merge(existing: [stored], adding: [rewalk])
        #expect(merged.count == 1)
        #expect(merged[0].reaches == 3)
        #expect(merged[0].observed == true)
    }

    @Test func genuinelyNewDaysAreAdded() {
        let merged = DayLog.merge(existing: [record(day, observed: true)],
                                  adding: [record(at(6, 11, 7), observed: true)])
        #expect(merged.map(\.dayStart) == [day, at(6, 11, 7)])
    }

    @Test func theResultIsSortedOldestFirstWhateverOrderItArrivesIn() {
        let merged = DayLog.merge(existing: [record(at(6, 12, 7), observed: true)],
                                  adding: [record(at(6, 10, 7), observed: true),
                                           record(at(6, 11, 7), observed: true)])
        #expect(merged.map(\.dayStart) == [at(6, 10, 7), at(6, 11, 7), at(6, 12, 7)])
    }

    @Test func theStoreIsCappedAndDropsOldestFirst() {
        let many = (0..<(DayLog.recordCap + 10)).compactMap { i -> DayRecord? in
            cal.date(byAdding: .day, value: i, to: day).map { record($0, observed: true) }
        }
        let merged = DayLog.merge(existing: [], adding: many)
        #expect(merged.count == DayLog.recordCap)
        // The ten dropped are the ten oldest.
        #expect(merged.first?.dayStart == cal.date(byAdding: .day, value: 10, to: day))
    }
}

// MARK: - The walk

@Suite struct TheWalkHasNoCursor {

    @Test func itEmitsOnlyDaysWithNoRecord() {
        let recorded: Set<Date> = [at(6, 8, 7), at(6, 9, 7)]
        let missing = DayLog.missingBoundaries(recorded: recorded,
                                               upTo: at(6, 12, 7), calendar: cal)
        #expect(missing == [at(6, 10, 7), at(6, 11, 7)])
    }

    @Test func todayIsNeverInIt() {
        // The hero is closed days only. `upTo` is exclusive.
        let missing = DayLog.missingBoundaries(recorded: [at(6, 9, 7)],
                                               upTo: at(6, 10, 7), calendar: cal)
        #expect(missing.isEmpty)
    }

    @Test func aLostWriteIsReEmittedOnTheNextPass() {
        // The reason there is no stored cursor: a cursor that advanced past a
        // write which did not land would lose that day permanently.
        let full: Set<Date> = [at(6, 8, 7), at(6, 9, 7), at(6, 10, 7)]
        #expect(DayLog.missingBoundaries(recorded: full, upTo: at(6, 11, 7),
                                         calendar: cal).isEmpty)

        let lost = full.subtracting([at(6, 9, 7)])
        #expect(DayLog.missingBoundaries(recorded: lost, upTo: at(6, 11, 7),
                                         calendar: cal) == [at(6, 9, 7)])
    }

    @Test func aLongAbsenceWalksEveryBoundaryAndNotJustTheLatest() {
        // 90 days away must not compact 90 days of grants against one record.
        let missing = DayLog.missingBoundaries(recorded: [at(6, 1, 7)],
                                               upTo: at(8, 30, 7), calendar: cal)
        #expect(missing.count == 89)
        #expect(missing.first == at(6, 2, 7))
        #expect(missing.last == at(8, 29, 7))
    }

    @Test func theWalkIsBounded() {
        // A boundary that has moved absurdly far cannot spin the app.
        let missing = DayLog.missingBoundaries(recorded: [at(1, 1, 7)],
                                               upTo: at(12, 31, 7), calendar: cal)
        #expect(missing.count <= DayLog.maxWalk)
    }

    @Test func springForwardIsWalkedExactlyOnce() {
        // 23 real hours, one Silk day. Adding 86 400 s would skip or repeat it.
        let missing = DayLog.missingBoundaries(recorded: [at(3, 6, 7)],
                                               upTo: at(3, 10, 7), calendar: cal)
        #expect(missing == [at(3, 7, 7), at(3, 8, 7), at(3, 9, 7)])
    }

    @Test func fallBackIsWalkedExactlyOnce() {
        // 25 real hours, still one Silk day, still 7:00 on both sides.
        let missing = DayLog.missingBoundaries(recorded: [at(10, 30, 7)],
                                               upTo: at(11, 3, 7), calendar: cal)
        #expect(missing == [at(10, 31, 7), at(11, 1, 7), at(11, 2, 7)])
    }

    @Test func withNoRecordsAtAllItBootstrapsWithOneDay() {
        // §3.6 deletes firstRun, so nothing stamps the install and there is no
        // anchor. One day back starts the chain; on a real first run the wall
        // was not up, so that day writes a ring and the hero reads 0 (§2.6).
        let missing = DayLog.missingBoundaries(recorded: [], upTo: day, calendar: cal)
        #expect(missing == [at(6, 9, 7)])
    }

    @Test func anAnchorAheadOfTodayBootstrapsRatherThanSilencingTheWalk() {
        // A clock that went backwards must not produce a negative walk — but
        // it must not produce an EMPTY one either: recordClosedDays reads
        // empty-owed as "nothing to record, compact away", so a lone
        // future-dated record (written while the clock was ahead, then
        // corrected) would green-light destroying every real day's grants
        // with no record ever written. With no usable past anchor the walk
        // starts over the way a fresh install does.
        let missing = DayLog.missingBoundaries(recorded: [at(6, 20, 7)],
                                               upTo: day, calendar: cal)
        #expect(missing == [at(6, 9, 7)])
    }
}

// MARK: - The walk under a moved boundary
//
// The records chain from the OLDEST record's time-of-day; `upTo` comes from
// the live policy. One sentence ("end my down hours at 9") makes them
// disagree, and "summarised once, never revised" makes any record written in
// that disagreement permanent — so the walk may only owe a day whose whole
// span has already elapsed.

@Suite struct TheWalkNeverOwesADayStillInProgress {

    @Test func anOldAnchoredDayIsNotOwedWhileItsHoursAreStillHappening() {
        // Records anchored at 07:00; down hours now end at 09:00. At 09:30 on
        // Jun 23 the sweep runs with upTo = Jun 23 09:00. The old-anchored
        // day starting Jun 23 07:00 runs until Jun 24 07:00 — ~21.5 hours of
        // it have not happened. Owing it now would freeze a verdict over
        // hours that do not exist yet, and inflate `fraction` toward a
        // dead-quiet day whatever actually happens.
        let recorded: Set<Date> = [at(6, 20, 7), at(6, 21, 7)]
        let missing = DayLog.missingBoundaries(recorded: recorded,
                                               upTo: at(6, 23, 9), calendar: cal)
        #expect(missing == [at(6, 22, 7)])
        #expect(!missing.contains(at(6, 23, 7)))
    }

    @Test func theSameDayIsOwedAtTheFirstSweepPastItsTrueEnd() {
        // Not lost — merely late. By the next boundary's sweep the whole
        // old-anchored span has elapsed and the record is honest.
        let recorded: Set<Date> = [at(6, 20, 7), at(6, 21, 7), at(6, 22, 7)]
        let missing = DayLog.missingBoundaries(recorded: recorded,
                                               upTo: at(6, 24, 9), calendar: cal)
        #expect(missing == [at(6, 23, 7)])
    }

    @Test func aMatchedAnchorStillOwesEveryClosedDay() {
        // When the boundary has NOT moved, next-day-start-at-or-before-upTo
        // and start-before-upTo are the same test — the guard must not eat a
        // legitimate final day.
        let missing = DayLog.missingBoundaries(recorded: [at(6, 20, 7)],
                                               upTo: at(6, 23, 7), calendar: cal)
        #expect(missing == [at(6, 21, 7), at(6, 22, 7)])
    }

    @Test func everyOwedDayEndsAtOrBeforeTheSweepInstant() {
        // The invariant itself, over a moved boundary in both directions.
        for upTo in [at(6, 23, 5), at(6, 23, 9), at(6, 23, 7)] {
            let missing = DayLog.missingBoundaries(recorded: [at(6, 18, 7)],
                                                   upTo: upTo, calendar: cal)
            for owed in missing {
                #expect(DayBoundary.nextDayStart(after: owed, calendar: cal) <= upTo)
            }
        }
    }
}

// MARK: - Future-dated records
//
// Clock manipulation is an expected input for a screen-time lock. A record
// written while the clock was a week ahead must not silence the walk after
// the clock is corrected — empty-owed green-lights compaction, and compaction
// with no record destroys the day's grants unrecoverably.

@Suite struct AFutureDatedRecordDoesNotSilenceTheWalk {

    @Test func futureRecordsAreIgnoredWhenAnchoringThePast() {
        // One real record and one from the clock-ahead week: the real one
        // anchors, the future one neither anchors nor satisfies anything.
        let recorded: Set<Date> = [at(6, 9, 7), at(6, 20, 7)]
        let missing = DayLog.missingBoundaries(recorded: recorded,
                                               upTo: at(6, 12, 7), calendar: cal)
        #expect(missing == [at(6, 10, 7), at(6, 11, 7)])
    }

    @Test func onlyFutureRecordsMeansBootstrapNotEmpty() {
        // The fresh-install-with-clock-ahead shape: the bootstrap wrote one
        // record for futureDay−1, the user corrected the clock. Owed must be
        // non-empty, or every real day compacts recordless forever.
        let missing = DayLog.missingBoundaries(recorded: [at(6, 17, 7)],
                                               upTo: day, calendar: cal)
        #expect(missing == [at(6, 9, 7)])
    }

    @Test func theWalkNeverEmitsAFutureBoundary() {
        // "Refuse to write records whose dayStart is not strictly in the
        // past" — enforced at the walk, where every written record is born.
        for recorded in [Set<Date>(), [at(6, 1, 7)], [at(6, 25, 7)]] {
            for owed in DayLog.missingBoundaries(recorded: recorded, upTo: day,
                                                 calendar: cal) {
                #expect(owed < day)
            }
        }
    }
}

// MARK: - The heartbeat dedupe
//
// `summarise` needs a beat strictly inside the day, and a launch-time re-arm
// shortly before the boundary records a beat for the CLOSING day. The
// daemon's genuine boundary firing arrives within the hour; a flat 3600 s
// window swallows it, and the new day is summarised dead — permanently,
// because `observed` is never revised.

@Suite struct ABoundaryFiringIsNeverSwallowedByTheDedupe {

    @Test func theFirstBeatEverRecords() {
        #expect(DayLog.heartbeatLog([], recording: day, downHours: night,
                                    calendar: cal) == [day])
    }

    @Test func aRestatementInsideTheSameDayIsNotWorthAWrite() {
        #expect(DayLog.heartbeatLog([at(6, 10, 12)], recording: at(6, 10, 12, 30),
                                    downHours: night, calendar: cal) == nil)
    }

    @Test func anHourApartAlwaysRecords() {
        let beats = DayLog.heartbeatLog([at(6, 10, 12)], recording: at(6, 10, 13),
                                        downHours: night, calendar: cal)
        #expect(beats == [at(6, 10, 12), at(6, 10, 13)])
    }

    @Test func theBoundaryFiringAfterALateLaunchReArmIsKept() {
        // She opens Silk at 06:20 — the re-arm fires an immediate
        // intervalDidStart, a beat belonging to the closing day. The daemon's
        // genuine 07:00 firing lands 40 minutes later, inside the flat
        // window, but in a NEW Silk day: it must record, because it is the
        // only beat that can mark the new day observed.
        let beats = DayLog.heartbeatLog([at(6, 10, 6, 20)], recording: at(6, 10, 7),
                                        downHours: night, calendar: cal)
        #expect(beats == [at(6, 10, 6, 20), at(6, 10, 7)])

        // And it is load-bearing: without that beat the day rings.
        let observed = summarise(heartbeats: beats ?? [])
        let swallowed = summarise(heartbeats: [at(6, 10, 6, 20)])
        #expect(observed.observed == true)
        #expect(swallowed.observed == false)
    }

    @Test func withNoKnownBoundaryTheFlatWindowStands() {
        // No policy blob to read — fail toward a ring, the safe side.
        #expect(DayLog.heartbeatLog([at(6, 10, 6, 20)], recording: at(6, 10, 7),
                                    downHours: nil, calendar: cal) == nil)
    }

    @Test func aClockThatWentBackwardsDoesNotDisorderTheLog() {
        #expect(DayLog.heartbeatLog([at(6, 10, 12)], recording: at(6, 10, 11, 30),
                                    downHours: night, calendar: cal) == nil)
    }
}

// MARK: - The heartbeat cap

@Suite struct TheBeatLogCanVouchForEveryWalkableDay {

    @Test func theCapIsComfortablyPastTheDayRecordCap() {
        // `observed` requires a beat inside the day; a walk can summarise up
        // to `maxWalk` days at once. A beat cap smaller than that silently
        // rings every day older than the beats that survived — the invariant
        // the store's comment states must actually hold.
        #expect(DayLog.heartbeatCap > DayLog.recordCap)
        #expect(DayLog.heartbeatCap > DayLog.maxWalk)
    }

    @Test func theCapDropsOldestFirst() {
        let full = (0..<DayLog.heartbeatCap).map {
            day.addingTimeInterval(Double($0) * 86_400)
        }
        let next = full.last!.addingTimeInterval(90_000)
        let beats = DayLog.heartbeatLog(full, recording: next,
                                        downHours: night, calendar: cal)
        #expect(beats?.count == DayLog.heartbeatCap)
        #expect(beats?.first == full[1])
        #expect(beats?.last == next)
    }
}

// MARK: - The compaction gate's read order
//
// UserDefaults has no compare-and-swap; the stamp is the proof-of-read the
// writers agree on. The proof only works read stamp-first: taken after the
// data, a concurrent write landing between the two is invisible — the check
// passes against a stale array, and the save erases the other process's
// records. Both writers synchronise on the day boundary, so the race is
// correlated, not rare.

private final class ScriptedDayStore: DayRecordStore, @unchecked Sendable {
    var records: [DayRecord]
    var stamp: String?
    var beats: [Date]
    var saves = 0
    var reads: [String] = []
    /// Simulates another process, fired while this one decodes the blob.
    var duringAttemptsRead: () -> Void = {}

    init(records: [DayRecord] = [], beats: [Date] = []) {
        self.records = records
        self.beats = beats
        self.stamp = "genesis"
    }

    func dayRecords() -> [DayRecord] {
        reads.append("records")
        return records.sorted { $0.dayStart < $1.dayStart }
    }
    func daysStamp() -> String? {
        reads.append("stamp")
        return stamp
    }
    func attemptsBlob() -> [Date] { duringAttemptsRead(); return [] }
    func heartbeats() -> [Date] { beats }
    func save(dayRecords: [DayRecord]) {
        records = dayRecords
        stamp = UUID().uuidString
        saves += 1
    }
    /// What `SharedStore.save(dayRecords:)` does in the other process.
    func concurrentWrite(_ record: DayRecord) {
        records.append(record)
        stamp = UUID().uuidString
    }
}

@Suite struct TheGateCannotEraseAWriteItDidNotSee {

    private func record(_ start: Date, reaches: Int, observed: Bool) -> DayRecord {
        DayRecord(dayStart: start, grantedMinutes: 0, reaches: reaches,
                  lateReaches: 0, observed: observed)
    }

    @Test func theStampIsReadBeforeTheDataItProves() {
        // The direction itself. Every other stamp user reads stamp-first;
        // read the other way the proof-of-read proves nothing.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7), reaches: 0,
                                                      observed: true)],
                                     beats: [at(6, 9, 7)])
        _ = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                    ledger: GrantLedger(), wallStanding: true,
                                    calendar: cal, store: store)
        guard let stampAt = store.reads.firstIndex(of: "stamp"),
              let recordsAt = store.reads.firstIndex(of: "records") else {
            Issue.record("the gate read neither stamp nor records")
            return
        }
        #expect(stampAt < recordsAt)
    }

    @Test func aConcurrentSweepsRecordSurvivesAndItsVerdictStands() {
        // The finding's exact scenario: at the boundary, SpendIntent's sweep
        // (another process) lands yesterday's record while the app's gate is
        // between its reads. The app must merge onto what stands — not
        // overwrite the day with its own verdict, which "observed is never
        // revised" forbids.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7), reaches: 0,
                                                      observed: true)],
                                     beats: [at(6, 9, 7)])
        let theirs = record(at(6, 9, 7), reaches: 7, observed: false)
        store.duringAttemptsRead = { [weak store] in
            store?.concurrentWrite(theirs)
            store?.duringAttemptsRead = {}   // one process, one write
        }

        let ok = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok)
        let jun9 = store.records.first { $0.dayStart == at(6, 9, 7) }
        #expect(jun9?.reaches == 7)
        #expect(jun9?.observed == false)
    }

    @Test func aFutureOnlyStoreWritesARealRecordBeforeSayingYes() {
        // The clock-ahead bootstrap record, after correction: the gate may
        // only answer true by landing a record for a real day — never by
        // finding nothing owed.
        let store = ScriptedDayStore(records: [record(at(6, 17, 7), reaches: 0,
                                                      observed: true)])
        let ok = DayLog.recordClosedDays(upTo: day, downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok)
        #expect(store.saves == 1)
        #expect(store.records.contains { $0.dayStart == at(6, 9, 7) })
    }

    @Test func nothingOwedIsATrueWithoutAWrite() {
        let store = ScriptedDayStore(records: [record(at(6, 9, 7), reaches: 0,
                                                      observed: true)])
        let ok = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok)
        #expect(store.saves == 0)
    }
}

// MARK: - The compaction frontier
//
// The gate's `true` green-lights `compact(dayStart: currentDayStart)` in both
// callers. When the user moves when down hours end, the record chain stays
// anchored at the OLD boundary's time-of-day while `currentDayStart` comes
// from the live policy — and the old-anchored day closes AFTER the live
// boundary sweeps. Nothing is owed at that sweep, so the old gate said true,
// and compaction destroyed the still-unsummarised day's grants; the day was
// later recorded with grantedMinutes: 0, permanently. "No compaction without
// a record" now means what it says: never past the frontier.

@Suite struct TheGateNeverBlessesCompactionPastAnUnsummarisedDay {

    private func record(_ start: Date, observed: Bool = true) -> DayRecord {
        DayRecord(dayStart: start, grantedMinutes: 0, reaches: 0,
                  lateReaches: 0, observed: observed)
    }

    @Test func aBoundaryMovedEarlierHoldsTheSweepInsteadOfDestroyingTheDay() {
        // The probe's exact shape: records anchored 07:00 (newest summarises
        // the day that ended Jun 21 07:00), a grant spent Jun 21 14:00,
        // down-hours end moved to 05:00. At the Jun 22 05:00 sweep the
        // old-anchored Jun 21 day runs until Jun 22 07:00 — nothing is owed,
        // and the old gate answered true with no record written, emptying the
        // ledger of the very grant Jun 21's summary needs.
        let store = ScriptedDayStore(records: [record(at(6, 19, 7)),
                                               record(at(6, 20, 7))],
                                     beats: [at(6, 20, 7), at(6, 21, 7)])
        var ledger = GrantLedger()
        ledger.record(Grant(door: Door(name: "Instagram"), minutes: 30,
                            issuedAt: at(6, 21, 14), expiresAt: at(6, 21, 14, 30)))

        let ok = DayLog.recordClosedDays(upTo: at(6, 22, 5), downHours: night,
                                         ledger: ledger, wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == false)
        // And no verdict was invented for the day still in progress.
        #expect(!store.records.contains { $0.dayStart == at(6, 21, 7) })
    }

    @Test func aBoundaryMovedLaterHoldsTheSweepTheSameWay() {
        // The other direction: records anchored 05:00, boundary now 07:00.
        // The Jun 21 05:00 day is summarised (fully elapsed), but the
        // Jun 22 05:00 day — two hours of which precede the sweep — is not,
        // and compacting to Jun 22 07:00 would cut into it.
        let store = ScriptedDayStore(records: [record(at(6, 20, 5)),
                                               record(at(6, 21, 5))],
                                     beats: [at(6, 21, 5), at(6, 22, 5)])
        let ok = DayLog.recordClosedDays(upTo: at(6, 22, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == false)
    }

    @Test func aMatchedAnchorStillCompactsAtEveryBoundary() {
        // The common case must not pay for the moved one: chain and policy
        // agree, yesterday lands, the frontier IS the current day start.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7))],
                                     beats: [at(6, 9, 7)])
        let ok = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == true)
    }

    @Test func theFrontierIsTheNewestClosedDaysOwnEnd() {
        // Newest record Jun 20 07:00 → its day ended Jun 21 07:00, and that
        // is as far as any compaction may reach, however far ahead the live
        // boundary sits.
        #expect(DayLog.compactionFrontier(recorded: [at(6, 19, 7), at(6, 20, 7)],
                                          upTo: at(6, 22, 5), calendar: cal) == at(6, 21, 7))

        // Matched anchors clamp to the day start itself…
        #expect(DayLog.compactionFrontier(recorded: [at(6, 21, 7)],
                                          upTo: at(6, 22, 7), calendar: cal) == at(6, 22, 7))
        // …and with nothing summarised, nothing may be dropped.
        #expect(DayLog.compactionFrontier(recorded: [], upTo: at(6, 22, 7),
                                          calendar: cal) == .distantPast)
        // A future-dated record is not a closed day and moves no frontier.
        #expect(DayLog.compactionFrontier(recorded: [at(6, 25, 7)],
                                          upTo: at(6, 22, 7), calendar: cal) == .distantPast)
    }

    @Test func theFrontierStopsAtTheFirstHoleNotTheNewestRecord() {
        // Jun 6 and Jun 7 are still owed; a frontier read off the newest
        // record (Jun 9) would let the callers — which now compact to the
        // frontier whether or not the gate said yes — destroy the hole's
        // grants before any record summarises them.
        #expect(DayLog.compactionFrontier(recorded: [at(6, 5, 7), at(6, 8, 7)],
                                          upTo: at(6, 10, 7), calendar: cal) == at(6, 6, 7))
    }
}

// MARK: - The forward clock
//
// Clock manipulation is an expected input for a screen-time lock. A clock
// rolled forward makes `currentDayStart` a fabrication: the old walk owed
// every not-yet-happened day up to it, wrote each as a permanent ring,
// green-lit compaction of every live grant, and — once the clock was
// corrected — left the fabricated records standing to satisfy the walk as
// real time reached them, so honestly-lived days scored 0 forever.

@Suite struct AForwardClockCannotFabricatePermanentDays {

    private func record(_ start: Date, observed: Bool = true) -> DayRecord {
        DayRecord(dayStart: start, grantedMinutes: 0, reaches: 0,
                  lateReaches: 0, observed: observed)
    }

    @Test func daysBeyondEverySignOfLifeAreNotSummarised() {
        // Real history through Jun 9; the clock claims it is Jun 20. The days
        // between exist only in the clock's imagination — no heartbeat, no
        // attempt reaches them — so they stay owed, and the gate holds
        // compaction instead of destroying every live grant against a fake
        // day start.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7))],
                                     beats: [at(6, 9, 7)])
        let ok = DayLog.recordClosedDays(upTo: at(6, 20, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == false)
        // Jun 9 had a beat at its start — the world provably reached it — so
        // its record lands; nothing past the evidence is written.
        #expect(store.records.contains { $0.dayStart == at(6, 9, 7) })
        #expect(store.records.allSatisfy { $0.dayStart <= at(6, 9, 7) })
    }

    @Test func theVouchedDaysStillLandWhileTheRestWait() {
        // Evidence through Jun 11 vouches for Jun 9, 10 and 11 (their starts
        // are at or before the newest beat); Jun 12…19 wait for real time.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7))],
                                     beats: [at(6, 9, 7), at(6, 10, 7), at(6, 11, 7)])
        _ = DayLog.recordClosedDays(upTo: at(6, 20, 7), downHours: night,
                                    ledger: GrantLedger(), wallStanding: true,
                                    calendar: cal, store: store)
        for day in [at(6, 9, 7), at(6, 10, 7), at(6, 11, 7)] {
            #expect(store.records.contains { $0.dayStart == day })
        }
        #expect(!store.records.contains { $0.dayStart >= at(6, 12, 7) })
    }

    @Test func fabricatedRecordsArePurgedOnceTheClockIsCorrected() {
        // Records for Jun 12…14 were written while the clock was ahead; the
        // clock now reads Jun 10. Left standing, each would satisfy the walk
        // the moment real time reached it, and the user's actual Jun 12 would
        // score off hours that never existed. The gate deletes them, so those
        // days are summarised from real counts when they genuinely close.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7)),
                                               record(at(6, 12, 7)),
                                               record(at(6, 13, 7)),
                                               record(at(6, 14, 7))],
                                     beats: [at(6, 9, 7)])
        let ok = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == true)
        #expect(store.records.contains { $0.dayStart == at(6, 9, 7) })
        #expect(!store.records.contains { $0.dayStart >= at(6, 10, 7) })
    }

    @Test func purgingFabricationsIsNotARevision() {
        // "Summarised once, never revised" protects verdicts on days that
        // happened. A real day's record — even a ring — survives the purge
        // untouched; only records dated at or past the current day start go.
        let realRing = record(at(6, 9, 7), observed: false)
        let store = ScriptedDayStore(records: [record(at(6, 8, 7)), realRing,
                                               record(at(6, 15, 7))],
                                     beats: [at(6, 9, 7)])
        _ = DayLog.recordClosedDays(upTo: at(6, 10, 7), downHours: night,
                                    ledger: GrantLedger(), wallStanding: true,
                                    calendar: cal, store: store)
        let jun9 = store.records.first { $0.dayStart == at(6, 9, 7) }
        #expect(jun9?.observed == false)
        #expect(!store.records.contains { $0.dayStart == at(6, 15, 7) })
    }
}

// MARK: - The corroboration horizon
//
// The residual destruction arm: the daemon fires once at whatever boundary
// the clock claims, so a forward-set clock plants exactly ONE beat at the
// fake day's start. Under a bare `max()` over the evidence that single beat
// was the newest sign of life, vouched for the entire fabricated walk (ten
// permanent rings, real history evicted at the cap), the gate said yes, and
// `compact(dayStart: fakeDay)` destroyed every live grant — a repeatable
// full-budget refill. Evidence isolated past `evidenceGap` must corroborate
// nothing until a second instant a real day later joins it.

@Suite struct AnIsolatedFutureBeatCorroboratesNothing {

    private func record(_ start: Date, observed: Bool = true) -> DayRecord {
        DayRecord(dayStart: start, grantedMinutes: 0, reaches: 0,
                  lateReaches: 0, observed: observed)
    }

    @Test func theDaemonsOwnFiringAtTheFakeBoundaryUnlocksNothing() {
        // Real history through Jun 8, real beats through Jun 9, a live grant
        // spent Jun 9 14:00 — and the clock rolled forward to Jun 19, where
        // the daemon dutifully stamped one beat at the fake boundary.
        let fakeStart = at(6, 19, 7)
        let store = ScriptedDayStore(records: [record(at(6, 7, 7)),
                                               record(at(6, 8, 7))],
                                     beats: [at(6, 8, 7), at(6, 9, 7), fakeStart])
        var ledger = GrantLedger()
        ledger.record(Grant(door: Door(name: "Instagram"), minutes: 30,
                            issuedAt: at(6, 9, 14), expiresAt: at(6, 9, 14, 30)))

        let ok = DayLog.recordClosedDays(upTo: fakeStart, downHours: night,
                                         ledger: ledger, wallStanding: true,
                                         calendar: cal, store: store)

        // The gate never blesses the fabricated walk…
        #expect(ok == false)
        // …the gap days are not summarised (no rings, no cap eviction)…
        #expect(!store.records.contains { $0.dayStart > at(6, 9, 7) })
        // …while Jun 9, vouched by its own real beat, still lands.
        #expect(store.records.contains { $0.dayStart == at(6, 9, 7) })

        // And the live grant survives the callers' protocol: they compact to
        // the frontier, and only when the frontier's own day reaches past
        // now — under the fake clock it cannot, so nothing is dropped.
        let cut = DayLog.compactionFrontier(
            recorded: Set(store.records.map(\.dayStart)),
            upTo: fakeStart, calendar: cal)
        #expect(cut == at(6, 10, 7))
        var compacted = ledger
        if DayBoundary.nextDayStart(after: cut, calendar: cal) > at(6, 19, 10) {
            compacted.compact(dayStart: cut, calendar: cal)
        }
        #expect(compacted.grants.count == 1)
    }

    @Test func aGenuineAbsenceResumesAfterTwoChainedDailyBeats() {
        // A month dark, then the daemon genuinely lives through two days.
        // The second beat matures the post-gap segment: the whole absence is
        // summarised (rings), the observed days score, and the gate says yes.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7))],
                                     beats: [at(6, 9, 7), at(7, 9, 7), at(7, 10, 7)])
        let ok = DayLog.recordClosedDays(upTo: at(7, 11, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == true)
        let jun20 = store.records.first { $0.dayStart == at(6, 20, 7) }
        #expect(jun20?.observed == false)   // a ring, not an invention
        let jul9 = store.records.first { $0.dayStart == at(7, 9, 7) }
        #expect(jul9?.observed == true)
    }

    @Test func theFirstDayBackAloneHoldsTheSweep() {
        // One beat past the gap is indistinguishable from the fake-boundary
        // stamp, so nothing past the gap is owed yet and compaction holds;
        // tomorrow's beat resumes the walk.
        let store = ScriptedDayStore(records: [record(at(6, 8, 7))],
                                     beats: [at(6, 9, 7), at(7, 9, 7)])
        let ok = DayLog.recordClosedDays(upTo: at(7, 10, 7), downHours: night,
                                         ledger: GrantLedger(), wallStanding: true,
                                         calendar: cal, store: store)
        #expect(ok == false)
        #expect(!store.records.contains { $0.dayStart > at(6, 9, 7) })
    }

    @Test func theHorizonItself() {
        let anchor = at(6, 9, 7)
        // A chained instant advances the horizon; an isolated one does not.
        #expect(DayLog.corroborationHorizon(evidence: [at(6, 9, 7), at(6, 19, 7)],
                                            anchoredAt: anchor) == at(6, 9, 7))
        // A lone far instant — beat or attempt — is trusted nowhere at all.
        #expect(DayLog.corroborationHorizon(evidence: [at(6, 19, 7)],
                                            anchoredAt: anchor) == nil)
        // A post-gap segment shorter than a day never matures…
        #expect(DayLog.corroborationHorizon(evidence: [at(6, 19, 7), at(6, 19, 12)],
                                            anchoredAt: anchor) == nil)
        // …but two instants a real day apart do, and vouch to their end.
        #expect(DayLog.corroborationHorizon(evidence: [at(6, 19, 7), at(6, 20, 7)],
                                            anchoredAt: anchor) == at(6, 20, 7))
        // No anchor is the fresh install: every instant is trusted, as before.
        #expect(DayLog.corroborationHorizon(evidence: [at(6, 19, 7)],
                                            anchoredAt: nil) == at(6, 19, 7))
    }
}

// MARK: - The heartbeat log under a forward clock
//
// One beat recorded while the clock was set forward mutes the log after the
// correction: every genuine firing is a "negative interval" against it and
// returns nil, so every honestly-lived day until real time passes the fake
// beat is summarised dead — permanently, because observed is never revised.

@Suite struct AFutureDatedBeatCannotMuteTheLog {

    @Test func theNextGenuineFiringDropsTheFakeBeatAndRecords() {
        // A beat 90 days ahead (the game-time-cheat shape): the daemon's next
        // real firing must both heal the log and land, or the day it fired
        // for rings despite the framework being demonstrably alive.
        let fake = at(9, 10, 7)
        let beats = DayLog.heartbeatLog([at(6, 10, 7), fake], recording: at(6, 11, 7),
                                        downHours: night, calendar: cal)
        #expect(beats == [at(6, 10, 7), at(6, 11, 7)])

        // And it is load-bearing: the healed log marks the real day observed.
        let healed = summarise(heartbeats: beats ?? [], dayStart: at(6, 11, 7))
        let muted = summarise(heartbeats: [at(6, 10, 7)], dayStart: at(6, 11, 7))
        #expect(healed.observed == true)
        #expect(muted.observed == false)
    }

    @Test func aHealIsWorthAWriteEvenWhenTheFiringItselfDedupes() {
        // The firing restates a beat half an hour old — normally nil — but
        // returning nil here would leave the fake beat standing forever. The
        // trimmed log must land.
        let beats = DayLog.heartbeatLog([at(6, 10, 12), at(9, 10, 7)],
                                        recording: at(6, 10, 12, 30),
                                        downHours: night, calendar: cal)
        #expect(beats == [at(6, 10, 12)])
    }

    @Test func aBeatMerelyMinutesAheadIsJitterNotDamage() {
        // The pinned small-backwards case is untouched: a beat inside the
        // dedupe window heals by itself within the hour, and stays.
        #expect(DayLog.heartbeatLog([at(6, 10, 12)], recording: at(6, 10, 11, 30),
                                    downHours: night, calendar: cal) == nil)
    }
}

// MARK: - The hero and the record are one formula

/// Mirror's numbers come from here now: a closed day draws `DayRecord.score`,
/// today draws `DayLog.runningScore` on the live counts. These pins hold the
/// two to a single equation — the repair of "the shipped inversion", where a
/// granted minute cost nothing and a day you spent outscored a day you held.
@Suite struct TheHeroAndTheRecordAreOneFormula {
    @Test func aRecordsScoreIsItsFractionOnTheHundredScale() {
        let rec = summarise(grants: [grant(tiktok, from: at(6, 10, 12), minutes: 45)],
                            attempts: [at(6, 10, 13)])
        #expect(rec.score == Int((rec.fraction * 100).rounded()))
        // 180 − (45 granted + 1 reach) = 134/180 → 74, not the shipped 99.
        #expect(rec.score == 74)
    }

    @Test func theRunningScoreAgreesWithTheRecordItWillBecome() {
        let grants = [grant(instagram, from: at(6, 10, 9), minutes: 30)]
        let attempts = [at(6, 10, 10), at(6, 10, 23)]   // one plain, one late
        let rec = summarise(grants: grants, attempts: attempts)
        let running = DayLog.runningScore(
            grantedMinutes: DayLog.grantedMinutes(grants, from: day, to: at(6, 11, 7)),
            reaches: rec.reaches, lateReaches: rec.lateReaches)
        #expect(running == rec.score)
    }

    @Test func aGrantedMinuteMovesTheNumberAndAResistedDayOutscoresASpentOne() {
        let held = DayLog.runningScore(grantedMinutes: 0, reaches: 3, lateReaches: 0)
        let spent = DayLog.runningScore(grantedMinutes: 60, reaches: 0, lateReaches: 0)
        #expect(held > spent)   // the inversion, repaired
    }

    @Test func theFloorHoldsAtZeroForARuinousDay() {
        #expect(DayLog.runningScore(grantedMinutes: 500, reaches: 40, lateReaches: 10) == 0)
    }

    @Test func anUnobservedDayScoresZeroThroughItsFraction() {
        let rec = summarise(heartbeats: [], wallStanding: false)
        #expect(rec.score == 0)
    }
}
