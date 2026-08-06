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

private let catalogueNames = LaunchCatalog.entries.flatMap(\.names)

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

    /// `knows` is what setup asks before it will let a name become a door, and
    /// it must answer for every spelling the catalogue itself carries.
    @Test func knowsEverythingItCarriesAndNothingElse() {
        for e in LaunchCatalog.entries {
            for n in e.names { #expect(LaunchCatalog.knows(n), "knows(\(n))") }
            #expect(LaunchCatalog.knows(e.display), "knows(\(e.display))")
            #expect(LaunchCatalog.knows(e.display.uppercased()), "knows(\(e.display.uppercased()))")
            #expect(LaunchCatalog.entry(named: e.display)?.display == e.display)
        }
        #expect(!LaunchCatalog.knows("mastodon"))
        #expect(!LaunchCatalog.knows(""))
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
            doors: [Door(name: e.display, aliases: e.names)]
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

    /// **EVERY NAME SPENDS ON ITS OWN DOOR.** One sentence, every spelling in
    /// the catalogue: the canonical ask. Passing it means no earlier rule
    /// claimed the sentence — not STATUS, not the window, not a close, not a
    /// cap — which is the whole collision check, stated as behaviour rather
    /// than as a list of keywords this test would have to keep in step with.
    @Test func everyNameSpendsOnItsOwnDoor() {
        for e in LaunchCatalog.entries {
            let s = state(for: e)
            for n in e.names {
                guard case .command(.spend(let d, let m)) =
                        DeterministicParser.parse("give me 20 minutes of \(n)", state: s)
                else {
                    Issue.record("\"\(n)\" did not spend")
                    continue
                }
                #expect(d.name == e.display, "\"\(n)\" spent on \(d.name)")
                #expect(m == 20, "\"\(n)\" spent \(m)")
            }
        }
    }

    /// **AND EVERY NAME STILL ASKS.** The elliptical ask is the other half of
    /// the hot path: a door named with an opening verb and no duration must
    /// reach "How long?" rather than silence.
    @Test func everyNameReachesTheElipticalAsk() {
        for e in LaunchCatalog.entries {
            let s = state(for: e)
            for n in e.names {
                guard case .command(.placeBoundAsk(let d)) =
                        DeterministicParser.parse("give me \(n)", state: s)
                else {
                    Issue.record("\"\(n)\" did not reach the ask")
                    continue
                }
                #expect(d.name == e.display, "\"\(n)\" asked about \(d.name)")
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
                == .command(.placeBoundAsk(door: hinge)))
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
                DeterministicParser.parse("tiktoks for ten", state: state())
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
