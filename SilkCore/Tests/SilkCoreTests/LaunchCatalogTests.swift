import Foundation
import Testing
@testable import SilkCore

// The catalogue's invariants, and the catalogue met against the grammar.
//
// None of this could be asserted while `LaunchCatalog` lived in the app target
// and imported UIKit: no headless suite could see it, so a malformed entry — a
// display whose lowercased form is missing from `names`, an entry with neither
// a scheme nor a link, one name claimed by two entries — compiled and shipped.
// The data is in the spine now, and these are the three seconds that catch it.

// MARK: - The shape of an entry

@Suite struct LaunchCatalogShape {

    /// **A DISPLAY MUST BE ONE OF ITS OWN NAMES.** Setup renders a chip per
    /// `display` and toggles it by `display.lowercased()`; `displayName(_:)`
    /// then looks that key back up in `names`. An entry that fails this puts a
    /// chip on screen that names a door nothing can open, and falls back to
    /// `key.capitalized`, so the failure reads as a spelling change.
    @Test func everyDisplayIsOneOfItsOwnNames() {
        for e in LaunchCatalog.entries {
            #expect(e.names.contains(e.display.lowercased()),
                    "\(e.display) does not answer to its own name")
        }
    }

    /// **AN ENTRY WITH NO SCHEME AND NO LINK OPENS NOTHING.** `open` tries the
    /// scheme, then the link; an entry carrying neither is a door that grants
    /// minutes and takes the wall down and then sits there. A nil link beside a
    /// real scheme is allowed and deliberate — Tinder and Hinge ship that way,
    /// because their domains' AASA files cannot match a root URL.
    @Test func everyEntryHasAWayIn() {
        for e in LaunchCatalog.entries {
            #expect(e.scheme != nil || e.universalLink != nil,
                    "\(e.display) has no way in")
        }
    }

    /// **ONE NAME, ONE APP.** A word claimed by two entries makes the lookup
    /// order the meaning, and `entry(named:)` takes the first — so the second
    /// app becomes unreachable by that word, silently.
    @Test func noNameIsSharedByTwoEntries() {
        var seen: [String: String] = [:]
        for e in LaunchCatalog.entries {
            #expect(Set(e.names).count == e.names.count, "\(e.display) repeats a name")
            for n in e.names {
                #expect(seen[n] == nil, "\"\(n)\" is claimed by both \(seen[n] ?? "") and \(e.display)")
                seen[n] = e.display
            }
        }
        let displays = LaunchCatalog.entries.map(\.display)
        #expect(Set(displays).count == displays.count, "two entries share a display name")
    }

    /// **NAMES ARE LOWERCASED SINGLE TOKENS.** Door matching is token-based, so
    /// a name the tokenizer would split ("focus friend") or a name carrying a
    /// capital is a name the parser can never match — `door(_:in:)` lowercases
    /// the utterance, never the catalogue.
    @Test func namesAreLowercasedSingleTokens() {
        for e in LaunchCatalog.entries {
            for n in e.names {
                #expect(!n.isEmpty, "\(e.display) has an empty name")
                #expect(n == n.lowercased(), "\"\(n)\" is not lowercased")
                #expect(NumberParser.tokenize(n) == [n], "\"\(n)\" is not one token")
            }
            #expect(!e.display.isEmpty)
        }
    }

    /// **EVERY SCHEME AND LINK PARSES.** `URL(string:)` returning nil is the one
    /// way `open` fails without reaching iOS at all. A dot is legal in a URI
    /// scheme, which is the only reason Amazon's
    /// `com.amazon.mobile.shopping://` works at all — this is the assertion
    /// that says so.
    @Test func everySchemeAndLinkParses() {
        for e in LaunchCatalog.entries {
            if let s = e.scheme {
                let url = URL(string: s)
                #expect(url != nil, "\(e.display): \(s) is not a URL")
                #expect(s.hasSuffix("://"), "\(e.display): \(s) is not a bare scheme")
                #expect(url?.scheme == String(s.dropLast(3)), "\(e.display): \(s) parses to another scheme")
            }
            if let l = e.universalLink {
                #expect(URL(string: l) != nil, "\(e.display): \(l) is not a URL")
                #expect(l.hasPrefix("https://"), "\(e.display): a fallback must be https")
            }
        }
    }

    /// **THE LOOKUP ANSWERS FOR EVERY SPELLING THE CATALOGUE CARRIES**, and
    /// case-insensitively, because setup hands it a display ("Instagram") and
    /// `open` hands it a door name the user may have typed in any casing.
    /// Asked as `entry(named:) != nil`, which is the whole of the question —
    /// a `knows(_:)` wrapper stood for it and nothing outside this test read it.
    @Test func theLookupAnswersForEverythingItCarriesAndNothingElse() {
        for e in LaunchCatalog.entries {
            for n in e.names {
                #expect(LaunchCatalog.entry(named: n) != nil, "entry(named: \(n))")
            }
            #expect(LaunchCatalog.entry(named: e.display) != nil, "entry(named: \(e.display))")
            #expect(LaunchCatalog.entry(named: e.display.uppercased()) != nil,
                    "entry(named: \(e.display.uppercased()))")
            #expect(LaunchCatalog.entry(named: e.display)?.display == e.display)
        }
        #expect(LaunchCatalog.entry(named: "mastodon") == nil)
        #expect(LaunchCatalog.entry(named: "") == nil)
    }

    /// The owner's five, pinned by name. The list is a product decision, and a
    /// silent deletion of one of them is exactly the kind of thing a diff hides.
    @Test func theFiveTheOwnerChoseAreInIt() {
        let displays = Set(LaunchCatalog.entries.map(\.display))
        for name in ["Discord", "Tinder", "Hinge", "Temu", "Amazon"] {
            #expect(displays.contains(name), "\(name) left the catalogue")
        }
        #expect(LaunchCatalog.entries.count == 17)
    }

    /// `DoorRoster` caps DOORS, never the catalogue: `maxDoors` is the six a
    /// person may name and `available` is a pure filter over whatever list it
    /// is handed. Seventeen entries do not touch either — asserted rather than
    /// assumed, because the two numbers sit one screen apart in setup.
    @Test func aBiggerCatalogueIsNotMoreDoors() {
        #expect(DoorRoster.maxDoors == 6)
        let catalog = LaunchCatalog.entries.map(\.display)
        #expect(DoorRoster.available(catalog: catalog, taken: []).count == catalog.count)
        #expect(DoorRoster.available(catalog: catalog, taken: ["hinge", "temu"]).count == catalog.count - 2)
        #expect(!DoorRoster.canAdd("Temu", taken: [], count: 6))
    }
}

// MARK: - The catalogue met against the grammar

/// Every name in the catalogue is a word the parser will have to read. These
/// are the collisions a new entry can cause, asked of the parser itself rather
/// than of a restated copy of its lexicon — a copy drifts, and then the
/// property proved is not the property that ships.
@Suite struct CatalogueNamesAgainstTheGrammar {

    private func state(for e: LaunchCatalog.Entry) -> PolicyState {
        PolicyState(
            budgetMinutes: 40,
            downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
            doors: [Door(name: e.display)]
        )
    }

    /// **NO NAME IS A NUMBER OR A CLOCK.** `allNumbers` reads idioms out of the
    /// raw string ("an hour", "half an hour"), so a name containing one would
    /// put a quantity in every sentence that says the app's name and break the
    /// single-number rule that the whole spend path rests on.
    @Test func noNameIsANumberOrAClock() {
        for e in LaunchCatalog.entries {
            for n in e.names + [e.display] {
                #expect(NumberParser.allNumbers(in: n).isEmpty, "\"\(n)\" carries a number")
                #expect(NumberParser.timeOfDay(in: n, assumeEvening: true) == nil, "\"\(n)\" reads as a clock")
                #expect(NumberParser.timeOfDay(in: n, assumeEvening: false) == nil, "\"\(n)\" reads as a clock")
            }
        }
    }

    /// **THE DOOR'S OWN NAME SPENDS ON ITS OWN DOOR.** One sentence, every
    /// spelling in the catalogue: the canonical ask. `Door.spokenForms` is the
    /// door's name and nothing else now, so only the spelling that IS the
    /// display name (case-folded) can find the door the state was built with —
    /// every other catalogue nickname names no door in a sentence, and reaches
    /// silence rather than a restated copy of the lexicon this test would
    /// otherwise have to track.
    ///
    /// NAMED FOR WHAT IT PROVES. It was `everyNameSpendsOnItsOwnDoor`, and half
    /// its rows assert the opposite: only the display name spends, and every
    /// other catalogue spelling must reach SILENCE. A name that says "every
    /// name" over a body that excludes most of them is a name a reader trusts
    /// instead of the body.
    @Test func onlyTheDisplayNameSpendsOnItsOwnDoor() {
        for e in LaunchCatalog.entries {
            let s = state(for: e)
            for n in e.names {
                let outcome = DeterministicParser.parse("give me 20 minutes of \(n)", state: s)
                if n == e.display.lowercased() {
                    guard case .command(.spend(let d, let m)) = outcome else {
                        Issue.record("\"\(n)\" did not spend")
                        continue
                    }
                    #expect(d.name == e.display, "\"\(n)\" spent on \(d.name)")
                    #expect(m == 20, "\"\(n)\" spent \(m)")
                } else {
                    #expect(outcome == .silence,
                            "\"\(n)\" is a catalogue nickname, not \(e.display)'s name, and must name no door")
                }
            }
        }
    }

    /// **AND THE DOOR'S OWN NAME STILL ASKS.** The elliptical ask is the other
    /// half of the hot path: a door named with an opening verb and no duration
    /// must reach "Write it out" rather than silence — but only when the
    /// sentence spelled the door's actual name. A nickname names no door, so
    /// the ask never opens on one.
    ///
    /// Renamed twice over: "every name" was false for the same reason as above,
    /// and "Eliptical" was a typo that had been in the suite long enough to be
    /// grepped for.
    @Test func onlyTheDisplayNameReachesTheEllipticalAsk() {
        for e in LaunchCatalog.entries {
            let s = state(for: e)
            for n in e.names {
                let outcome = DeterministicParser.parse("give me \(n)", state: s)
                if n == e.display.lowercased() {
                    guard case .writeItOut(let d, _) = outcome else {
                        Issue.record("\"\(n)\" did not reach the ask")
                        continue
                    }
                    #expect(d.name == e.display, "\"\(n)\" asked about \(d.name)")
                } else {
                    #expect(outcome == .silence,
                            "\"\(n)\" is a catalogue nickname, not \(e.display)'s name, and must name no door")
                }
            }
        }
    }
}

// MARK: - A door name that is also an English word

/// **"HINGES" IS A VERB.** The door deinflector strips a trailing "s" so that
/// "tiktoks daily limit" and "tiktok's daily limit" are one sentence; with a
/// Hinge door in state it also turned the ordinary English "hinges" into the
/// Hinge door. `firstDoor` takes the earliest match in the sentence, so rule 7
/// found door=Hinge and number=20 and FUNDED TWENTY MINUTES OF HINGE out of
/// "everything hinges on it, give me 20 minutes".
///
/// The clause guard could not catch it and it is worth saying why: the number
/// sits in a breath that names no door, which defers the question to the whole
/// sentence, and the whole sentence named exactly one door. The guard's answer
/// was right; the door was wrong before it was asked.
@Suite struct DoorNamesThatAreAlsoEnglish {

    private let hinge = Door(name: "Hinge")
    private let tiktok = Door(name: "TikTok")

    private func state() -> PolicyState {
        PolicyState(
            budgetMinutes: 40,
            downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
            doors: [hinge, tiktok]
        )
    }

    /// The sentence that bought the fix, and the shape it belongs to. Silence
    /// reaches the widener, which is the right home for a sentence asking for
    /// twenty minutes of nothing in particular.
    @Test func anOrdinaryVerbDoesNotFundADoor() {
        for text in ["everything hinges on it, give me 20 minutes",
                     "the whole day hinges on it, give me 20 minutes",
                     "it hinges on whether i get 20 minutes"] {
            #expect(DeterministicParser.parse(text, state: state()) == .silence, "\(text)")
        }
    }

    /// And the door the sentence DID name still gets its minutes. Before the
    /// fix this was silence too — `firstDoor` held Hinge, the funding clause
    /// named TikTok, and the identity test correctly refused a grant on a door
    /// no clause paid for. The refusal was right and the reading was wrong.
    @Test func theDoorTheSentenceNamedStillSpends() {
        guard case .command(.spend(let d, let m)) = DeterministicParser.parse(
            "everything hinges on it, give me 20 minutes of tiktok", state: state())
        else {
            Issue.record("did not spend")
            return
        }
        #expect(d.name == "TikTok")
        #expect(m == 20)
    }

    /// The name itself is untouched. A blanket refusal of the word would have
    /// been the easy fix and would have cost the door.
    @Test func theRealNameStillOpensTheRealDoor() {
        guard case .command(.spend(let d, let m)) =
                DeterministicParser.parse("give me 20 minutes of hinge", state: state())
        else {
            Issue.record("did not spend")
            return
        }
        #expect(d.name == "Hinge")
        #expect(m == 20)
        #expect(DeterministicParser.parse("give me hinge", state: state())
                == .writeItOut(door: hinge, minutes: nil))
    }

    /// **AND NOTHING HERE IS A SUBSTRING TEST.** "anything else" and "nothing
    /// else" both contain the letters of "hinge", and a fix written as
    /// `text.contains` would have named the door in both — which is the mistake
    /// this file's cap lexicon has paid for four times. Door matching is
    /// token-based and stays that way.
    @Test func aSubstringIsNotAName() {
        for text in ["anything else, give me 20 minutes",
                     "nothing else, give me 20 minutes",
                     "unhinged, give me 20 minutes",
                     "hinged on it, give me 20 minutes"] {
            #expect(DeterministicParser.parse(text, state: state()) == .silence, "\(text)")
        }
    }

    /// The deinflection this all exists for is unharmed: a brand's plural still
    /// names its door, and so does the possessive spelling the tokenizer splits.
    @Test func theBrandInflectionsStillMatch() {
        guard case .command(.spend(let d, let m)) =
                DeterministicParser.parse("unlock tiktoks for ten minutes", state: state())
        else {
            Issue.record("did not spend")
            return
        }
        #expect(d.name == "TikTok")
        #expect(m == 10)
        #expect(DeterministicParser.parse("cap tiktoks at 20", state: state())
                == .command(.setDoorCap(door: tiktok, minutes: 20)))
    }
}

// MARK: - The doors the APP actually builds

/// `CatalogueNamesAgainstTheGrammar` above builds its doors as
/// `Door(name: e.display)` and proves that every spelling in
/// the catalogue spends on its own door. It passed on every one of them while
/// "give me 10 minutes of ig" answered "Didn't get that." on a real phone —
/// because the app has never built a door that way. Both creation sites
/// (`AppModel.addDoor(named:)` and setup's `.limits` step) say
/// `Door(name: display)`, full stop, and nothing anywhere writes an alias.
///
/// So the suite above was asking the grammar a question about doors that do not
/// exist. This one asks it about the doors that do. It is the same property,
/// stated over the app's own initializer, and it is the test whose absence let
/// a shipped product and a green CI disagree for the whole life of the feature.
@Suite struct CatalogueNamesAgainstTheDoorsTheAppMakes {

    /// A door exactly as the app makes it: a display name and nothing else.
    private func appState(for e: LaunchCatalog.Entry) -> PolicyState {
        PolicyState(
            budgetMinutes: 240,
            downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
            doors: [Door(name: e.display)]
        )
    }

    /// Only the spelling that IS the door's own name (case-folded) spends on
    /// a door built from `Door(name: display)` alone. `notDoorTriggers` used to
    /// carve three nicknames out of the grammar's vocabulary; the grammar no
    /// longer reads that list at all, because `Door.spokenForms` never carried
    /// a catalogue nickname to begin with now — so every nickname is excluded,
    /// not merely the three the old list named.
    ///
    /// "Every catalogue name" was the claim; the body asserts silence for all
    /// of them but one.
    @Test func onlyTheDisplayNameSpendsOnADoorBuiltFromItAlone() {
        for e in LaunchCatalog.entries {
            let s = appState(for: e)
            for n in e.names {
                let outcome = DeterministicParser.parse("give me 20 minutes of \(n)", state: s)
                if n == e.display.lowercased() {
                    guard case .command(.spend(let d, let m)) = outcome else {
                        Issue.record("\"\(n)\" did not spend on a door named \(e.display)")
                        continue
                    }
                    #expect(d.name == e.display, "\"\(n)\" spent on \(d.name)")
                    #expect(m == 20, "\"\(n)\" spent \(m)")
                } else {
                    #expect(outcome == .silence,
                            "\"\(n)\" is a catalogue nickname, not \(e.display)'s name, and must name no door")
                }
            }
        }
    }

    /// The tightest sentence in the product is no more reachable by a nickname
    /// than the grant is: a close that names no door closes no door, exactly
    /// as the spend above, and the name says so.
    @Test func onlyTheDisplayNameClosesItsOwnDoor() {
        for e in LaunchCatalog.entries {
            let s = appState(for: e)
            for n in e.names {
                let outcome = DeterministicParser.parse("no more \(n) today", state: s)
                if n == e.display.lowercased() {
                    guard case .command(.closeDoorToday(let d, _)) = outcome else {
                        Issue.record("\"\(n)\" did not close a door named \(e.display)")
                        continue
                    }
                    #expect(d.name == e.display, "\"\(n)\" closed \(d.name)")
                } else {
                    #expect(outcome == .silence,
                            "\"\(n)\" is a catalogue nickname, not \(e.display)'s name, and must close no door")
                }
            }
        }
    }

    /// **AND THE CATALOGUE'S NICKNAMES NO LONGER REACH `spokenForms`.** The map
    /// that once handed a catalogue nickname to `Door.spokenForms`
    /// (`namesByDisplay`) is gone: `spokenForms` is the door's own name and
    /// nothing else, for every entry — not merely the three the old
    /// `notDoorTriggers` exclusion list named. Inverted from the test this used
    /// to be, which asserted the opposite.
    @Test func catalogueNicknamesAreAbsentFromSpokenForms() {
        for e in LaunchCatalog.entries {
            let forms = Set(Door(name: e.display).spokenForms)
            #expect(forms == [e.display.lowercased()], "\(e.display) carries more than its own name")
            for n in e.names where n != e.display.lowercased() {
                #expect(!forms.contains(n), "\(e.display) still answers to nickname \"\(n)\"")
            }
        }
    }

    /// **AND A NAME THAT IS ORDINARY ENGLISH IS NOT A DOOR TRIGGER.** The
    /// catalogue's `names` answer "which app do I open", where a loose synonym
    /// is free because a chip has already been tapped. The grammar asks "did
    /// this sentence name a door" of every token of arbitrary prose, and there
    /// it is not free: with "snap" in the grammar's vocabulary, "im about to
    /// snap, give me 10 minutes" GRANTED ten minutes of Snapchat, "my patience
    /// snaps after 20 minutes" granted twenty, and "close everything im about
    /// to snap" shut Snapchat ALONE and left every other door open, because the
    /// sentence now named a door and the doorful arm of the close rule took it.
    @Test func anOrdinaryEnglishNameNeverTriggersADoor() {
        let doors = [Door(name: "Snapchat"), Door(name: "Instagram"),
                     Door(name: "TikTok"), Door(name: "YouTube")]
        let s = PolicyState(budgetMinutes: 60,
                            downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                            doors: doors)
        for text in ["im about to snap give me 10 minutes",
                     "my patience snaps after 20 minutes",
                     "give me 20 minutes in a snap",
                     "i need 15 minutes to make a snap decision",
                     "cap tiktok at 20 before i snap"] {
            if case .command(.spend(let d, _)) = DeterministicParser.parse(text, state: s),
               d.name == "Snapchat" {
                Issue.record("\"\(text)\" bought Snapchat minutes")
            }
        }
        // The broadest tighten in the product must not collapse to one door.
        #expect(DeterministicParser.parse("close everything im about to snap", state: s)
                == .command(.closeAllToday(until: nil)),
                "an idiom containing \"snap\" narrowed a close over every door to one")
    }

    /// The shorthand the old exclusion list carved out no longer reaches the
    /// grammar either — `Door.spokenForms` never carried it in the first
    /// place now, so "yt", "fb" and "twitter" reach silence exactly like every
    /// other catalogue nickname. Inverted from the test this used to be, which
    /// asserted the opposite.
    @Test func theOldShorthandNoLongerReachesTheGrammar() {
        let s = PolicyState(budgetMinutes: 60,
                            downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                            doors: [Door(name: "Instagram"), Door(name: "YouTube"),
                                    Door(name: "Facebook"), Door(name: "X")])
        for text in ["unlock yt for 20", "give me 20 minutes of yt",
                     "give me 20 of fb", "20 minutes of twitter",
                     "give me 15 minutes of twitter"] {
            #expect(DeterministicParser.parse(text, state: s) == .silence, "\(text)")
        }
    }

    /// Snapchat is still reachable by its own name. The escape hatch this test
    /// used to pin — a user-chosen nickname living in `Door.aliases` — is gone
    /// as a stored property, and nothing replaces it: "snap" names no door,
    /// alias or not. Inverted from the test this used to be, which asserted
    /// the nickname still worked.
    @Test func theExcludedNameNoLongerWorksAnyway() {
        let plain = PolicyState(budgetMinutes: 60,
                                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                                doors: [Door(name: "Snapchat")])
        guard case .command(.spend(let d, let m)) =
                DeterministicParser.parse("give me 10 minutes of snapchat", state: plain) else {
            Issue.record("Snapchat stopped answering to its own name")
            return
        }
        #expect(d.name == "Snapchat")
        #expect(m == 10)

        // There is no more alias table to write "snap" into, so the nickname
        // stays unknown for the door it once might have named.
        #expect(DeterministicParser.parse("give me 10 minutes of snap", state: plain) == .silence)
    }

    /// A door whose name is not in the catalogue gains nothing and loses
    /// nothing — `spokenForms` is the name alone, in or out of the catalogue.
    @Test func aDoorOutsideTheCatalogueKeepsItsOwnForms() {
        #expect(Door(name: "Zzyzx").spokenForms == ["zzyzx"])
    }
}
