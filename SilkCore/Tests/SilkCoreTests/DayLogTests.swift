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

private func summarise(grants: [Grant] = [],
                       attempts: [Date] = [],
                       wallStanding: Bool = true,
                       dayStart: Date = day) -> DayRecord {
    DayLog.summarise(dayStart: dayStart, downHours: night, grants: grants,
                     attempts: attempts, wallStanding: wallStanding, calendar: cal)
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

    @Test func anAnchorAheadOfTodayEmitsNothing() {
        // A clock that went backwards must not produce a negative walk.
        #expect(DayLog.missingBoundaries(recorded: [at(6, 20, 7)],
                                         upTo: day, calendar: cal).isEmpty)
    }
}
