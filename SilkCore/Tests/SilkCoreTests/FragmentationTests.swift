import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

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

private let day = at(6, 10, 7)
private let dayEnd = at(6, 11, 7)

// MARK: - What fragmentation costs

/// `switchCost`: the term that lets the score tell "fifteen minutes" from
/// "five more, five more, five more".
///
/// The coefficient is score-weighting §4.4's, and §4.4 is candid that it is a
/// calibration constant with no citation behind it. These tests pin the
/// *shape* — ordering, the cap, and the zero cases — rather than defending the
/// number, because the number is expected to move once `allowance` is
/// calibrated against a real device day (growth-decision verdict 6).
@Suite struct FragmentationTests {

    /// The headline. Same door, same fifteen minutes, same day — bought once
    /// or bought three times. Before this term the two days were one number.
    @Test func topUpsCostMoreThanTheSameMinutesBoughtOnce() {
        let chained = [grant(instagram, from: at(6, 10, 9), minutes: 5),
                       grant(instagram, from: at(6, 10, 9, 5), minutes: 5),
                       grant(instagram, from: at(6, 10, 9, 10), minutes: 5)]
        let single = [grant(instagram, from: at(6, 10, 9), minutes: 15)]

        // The minutes really are identical — the union sees one contiguous
        // quarter hour either way, which is what makes this a fair comparison
        // rather than an artefact of how the windows were sliced.
        #expect(DayLog.grantedMinutes(chained, from: day, to: dayEnd)
                == DayLog.grantedMinutes(single, from: day, to: dayEnd))

        #expect(DayLog.unlocks(chained, from: day, to: dayEnd) == 3)
        #expect(DayLog.unlocks(single, from: day, to: dayEnd) == 1)

        let chainedScore = DayLog.runningScore(grantedMinutes: 15, reaches: 0,
                                               lateReaches: 0, unlocks: 3)
        let singleScore = DayLog.runningScore(grantedMinutes: 15, reaches: 0,
                                              lateReaches: 0, unlocks: 1)
        #expect(chainedScore == 89)
        #expect(singleScore == 92)
        #expect(chainedScore < singleScore)
    }

    /// One grant is not fragmentation, and neither is none. The term starts at
    /// the *second* purchase — a day spent entirely inside one window pays
    /// only for its minutes.
    @Test func theFirstGrantIsFree() {
        #expect(DayLog.fragmentation(unlocks: 0, grantedMinutes: 0) == 0)
        #expect(DayLog.fragmentation(unlocks: 1, grantedMinutes: 60) == 0)
        #expect(DayLog.fragmentation(unlocks: 2, grantedMinutes: 60) == 2)
    }

    /// The cap, doing the job it exists for. Four two-minute grants buy eight
    /// minutes; uncapped the switch term would be six, close to what the
    /// minutes themselves cost. Half the minutes is the ceiling.
    @Test func theCapBindsOnAThinChoppyDay() {
        #expect(DayLog.fragmentation(unlocks: 4, grantedMinutes: 8) == 4)   // 0.5 × 8, not 2 × 3
        #expect(DayLog.runningScore(grantedMinutes: 8, reaches: 0,
                                    lateReaches: 0, unlocks: 4) == 93)
    }

    /// And staying out of the way on a day with real minutes in it, where the
    /// term should be flat in the session count.
    @Test func theCapIsSlackOnceThereAreMinutesToSpeakOf() {
        #expect(DayLog.fragmentation(unlocks: 4, grantedMinutes: 40) == 6)  // 2 × 3, uncapped
        #expect(DayLog.runningScore(grantedMinutes: 40, reaches: 0,
                                    lateReaches: 0, unlocks: 4) == 74)
    }

    /// §4.4 sets `c` so fragmentation's realistic range is about a third of
    /// the term it is ordered against. On the median day it names — 40 granted
    /// minutes, eight sessions — it lands there against the minutes term.
    /// This is the one assertion that would notice `c` being changed without
    /// the reasoning behind it being revisited.
    @Test func theCoefficientKeepsItsStatedOrdering() {
        let term = DayLog.fragmentation(unlocks: 8, grantedMinutes: 40)
        #expect(term == 14)
        #expect(term / 40.0 > 0.30)
        #expect(term / 40.0 < 0.40)
    }

    /// `summarise` writes the count into the record, so a closed day carries
    /// its own fragmentation and never has to recompute it from grants that
    /// `compact` has since dropped.
    @Test func summariseRecordsTheCount() {
        let grants = [grant(instagram, from: at(6, 10, 9), minutes: 5),
                      grant(tiktok, from: at(6, 10, 14), minutes: 10)]
        let record = DayLog.summarise(dayStart: day, downHours: night, grants: grants,
                                      attempts: [], heartbeats: [day],
                                      wallStanding: true, calendar: cal)
        #expect(record.unlocks == 2)
        #expect(record.grantedMinutes == 15)
        #expect(record.score == DayLog.runningScore(grantedMinutes: 15, reaches: 0,
                                                    lateReaches: 0, unlocks: 2))
    }

    /// The running hero and the record it becomes must be one formula. This is
    /// the invariant `runningScore`'s own comment claims; the switch term is a
    /// new way for the two to drift apart, so it gets pinned.
    @Test func todayAndTheRecordAgree() {
        let record = DayRecord(dayStart: day, grantedMinutes: 40, reaches: 6,
                               lateReaches: 2, unlocks: 4, observed: true)
        #expect(record.score == DayLog.runningScore(grantedMinutes: 40, reaches: 6,
                                                    lateReaches: 2, unlocks: 4))
    }

    /// An unobserved day charges nothing, fragmentation included. The ring
    /// outranks every term in the cost.
    @Test func anUnobservedDayIsStillARing() {
        let record = DayRecord(dayStart: day, grantedMinutes: 40, reaches: 6,
                               lateReaches: 2, unlocks: 9, observed: false)
        #expect(record.fraction == 0)
    }
}

// MARK: - Records written before the term existed

/// A record is written once and never revised, so one written before `unlocks`
/// existed has to keep decoding — and has to keep the number it already had.
@Suite struct LegacyRecordDecodingTests {

    /// The field is absent from the JSON, decodes to zero, and zero costs
    /// nothing: the day scores exactly what it scored before the term shipped.
    @Test func aRecordWithoutUnlocksKeepsItsNumber() throws {
        let json = Data("""
        {"dayStart":0,"grantedMinutes":72,"reaches":0,"lateReaches":0,"observed":true}
        """.utf8)
        let record = try JSONDecoder().decode(DayRecord.self, from: json)
        #expect(record.unlocks == 0)
        #expect(record.score == 60)          // 1 − 72/180, the value it had before
    }

    /// And a record written now round-trips the field, so the day after the
    /// change is not silently the day before it.
    @Test func theFieldSurvivesARoundTrip() throws {
        let written = DayRecord(dayStart: day, grantedMinutes: 40, reaches: 3,
                                lateReaches: 1, unlocks: 5, observed: true)
        let back = try JSONDecoder().decode(DayRecord.self,
                                            from: JSONEncoder().encode(written))
        #expect(back == written)
        #expect(back.unlocks == 5)
    }
}
