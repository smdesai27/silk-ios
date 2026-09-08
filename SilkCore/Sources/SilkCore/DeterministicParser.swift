import Foundation

/// The deterministic grammar. Complete on its own: it must handle 100% of the
/// SPEND hot path and every canonical rule phrasing with no model present.
/// The on-device model (SilkModelParser, app target) is a widener for unseen
/// paraphrases of the rare rule intents — its output passes through the same
/// Validator, and this parser always runs first.
public enum DeterministicParser {

    /// `recentDoor` is the one thing the grammar is told about the turn
    /// before: the door the bar last wrote out for her, if the last reply was
    /// a hint. It is read by exactly one rule — the bare number — so that
    /// "tiktok" answered "Write it out: unlock TikTok for 10 min." and then
    /// "10" writes out TikTok and not the first door on the list. The
    /// grammar stays a pure function of its arguments; the memory is the
    /// app's, and one turn long (`AppModel.recentHintDoor`).
    public static func parse(_ utterance: String, state: PolicyState,
                             recentDoor: Door? = nil) -> ParseOutcome {
        let text = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .silence }
        let tokens = NumberParser.tokenize(text)
        guard !tokens.isEmpty else { return .silence }

        let door = firstDoor(in: tokens, state: state)
        // Read once, asked two ways. `number` is the SINGLE number — nil for
        // zero and nil for several, because two numbers is ambiguity and
        // compilers don't guess. The list itself survives because "no number"
        // and "no single number" are different absences: rules 6 and 8 answer
        // a doorful sentence missing its duration, and a sentence carrying
        // "ten or twenty" is not missing one — it stated two, and the answer
        // to that is the widener's, not "How long?".
        let numbers = NumberParser.allNumbers(in: text)
        let number = numbers.count == 1 ? numbers.first : nil

        // The clause partition, built at most once and only when a rule asks
        // for it. `ClauseIndex(text)` walks the string once, so it is cheap —
        // but `hugeInputStaysCheapAndSilent` bounds a ten-thousand-word input,
        // and the honest way to keep that bound honest is that a sentence which
        // never asks a clause question never pays for the answer. The cap rules,
        // rule 3's door guard, rule 5's two removal guards and rule 7's
        // ambiguity guard are the only callers, and every one of them needs a
        // named door first.
        //
        // Built from `text` — the same string `tokens` came from — so
        // `clauses().tokens == tokens` by construction. That equality is the
        // whole reason ClauseIndex owns its tokens (NumberParser.swift): a
        // position taken from one tokenization and used against another lands
        // somewhere real and wrong. Every cap helper below indexes into
        // `index.tokens` and never into this array.
        var clauseMemo: NumberParser.ClauseIndex?
        func clauses() -> NumberParser.ClauseIndex {
            if let clauseMemo { return clauseMemo }
            let built = NumberParser.ClauseIndex(text)
            clauseMemo = built
            return built
        }

        // 1. STATUS — a question about the balance, with no number and no door verb.
        //    Ahead of every cap rule by design: "how much of my tiktok budget is
        //    left" is a question, and the answer to a question is never a new
        //    rule. (spec §5.8 records the imprecision this leaves.)
        //    A KNOWN IMPRECISION LIVES HERE, and it is left alone deliberately.
        //    Five of the six STATUS triggers are substring tests over the whole
        //    sentence, so a close with a balance question riding along — "no
        //    more tiktok today how much is left", "block instagram and tell me
        //    whats left" — answers the balance and drops the close on the
        //    floor. The door the user asked to shut stays open.
        //
        //    A gate was written for it and then taken back out, and the reason
        //    is worth more than the gate was. `hasClosingVerb` is a test over
        //    the whole sentence and `door` is `firstDoor` — the first door
        //    NAMED, not the door the closing verb governs — so gating STATUS on
        //    "there is a close here" hands the sentence to rule 4, which closes
        //    whichever door was spelled first. Measured, on the shape users
        //    actually type when they have two things to say:
        //
        //      "how much is left on tiktok, block instagram"  → closed TIKTOK
        //      "how much of my tiktok block is left"          → closed TIKTOK
        //          (here "block" is a NOUN, and there is no close in the
        //           sentence at all)
        //      "whats left, i want to block reddit later"     → closed REDDIT
        //
        //    So the gate traded a DROPPED close for a WRONG one. A dropped
        //    close costs the user the sentence and she says it again; a wrong
        //    close shuts a door she is using and canon will not let her open it
        //    again before tomorrow. Between a recoverable failure and an
        //    unrecoverable one this rule keeps the recoverable one.
        //
        //    What would actually fix it is not here: rule 4 has to decide WHICH
        //    door a closing verb governs — clause-scoped, the way the cap rules
        //    already read their own — and until it can, nothing above it should
        //    be routing sentences to it on the strength of a substring.
        if isStatusAsk(text, hasDoor: door != nil) { return .command(.status) }

        // 2. DOWN HOURS — must be checked before budget: both can carry a number.
        //    With a time it is a setter; without one it is a question, and the
        //    answer is the window as it stands ("Down hours run 10:00 PM to
        //    7:00 AM." — docs/design/handoff/README.md:244). "night" matches as
        //    a token, never a substring: "tonight" belongs to sentences about
        //    today ("no more instagram tonight"), not the window. Bare "night"
        //    stays a mention: the prototype's query triggers are down hours,
        //    bedtime, quiet (Silk Mockup.dc.html:333), and "night" alone
        //    appears in too many sentences that are not about the window.
        let windowMention = says(text, downHour) || tokens.contains("night")
            || says(text, bedtime) || says(text, quiet)
        // The setter is about the window, and window sentences never name a
        // door or ask to be let in. Without those two guards, "give me 20
        // minutes of tiktok before bedtime" reads its 20 as 8 PM and a spend
        // request lands as a global tighten.
        if windowMention, door == nil, !hasAskFrame(tokens) {
            // One reading of the edge, used twice: the evening assumption and
            // the setter must never disagree about which edge this is, or a
            // stated 7 becomes 19:00 and then lands on the end.
            let edgeIsStart = isStart(text)
            // A STATED MERIDIEM IS STATED. "at 3 in the morning" names its
            // half of the day as surely as "3 am" does, and the evening
            // assumption exists only for hours that named none — a guess must
            // never override a statement, or "quiet at 3 in the morning" is
            // one careless flag from a 15:00 start. The phrase outranks the
            // edge's assumption in both directions: a stated morning stays a
            // morning, and a stated evening reads as one even on the end
            // edge, where the bare-hour assumption is a morning.
            if let t = NumberParser.timeOfDay(in: strip(text, of: "down hours"),
                                              assumeEvening: statedDayHalf(text) ?? edgeIsStart),
               // THE HOUR'S OWN CLAUSE MUST BE ABOUT THE WINDOW. The setter
               // used to fire on a window word ANYWHERE in the sentence plus
               // the first hour-shaped number anywhere else, so ordinary prose
               // moved a window edge: "work was quiet so i left at 4" set a
               // 4 PM start (a fifteen-hour night, instant, because longer is
               // tighter), "the baby went down at 7, quiet night finally" a
               // 7 PM one, and "pretty quiet day, i finished 20 pages of my
               // book" — "finished" reading as an end marker — a 20:00 END
               // against a 22:00 start, a twenty-two-hour lockdown out of a
               // sentence about a book. The prototype lists bedtime/quiet as
               // QUERY triggers; the setter arm was the widening, and the gate
               // narrows it back to the sentences that put the window's own
               // name in the same breath as the hour. A refused sentence falls
               // to the query arms below, which read the window back — a
               // harmless read, never a moved edge.
               windowOwnsTheStatedHour(clauses()) {
                // An end stated as a bare hour may be ambiguous in a way that
                // costs the user hours of lockdown, but that is the Validator's
                // to refuse: it is the one point every parser passes, and the
                // grammar's job is to read the sentence, not to price it.
                return .command(edgeIsStart ? .setDownHoursStart(t) : .setDownHoursEnd(t))
            }
        }
        if says(text, downHour) { return .command(.downHoursQuery) }
        // Bare "night" terminates — see the mention rule above — but not over a
        // sentence that names a door and closes it: "block instagram at night" is
        // the tightest thing in the product with a window word riding along,
        // and the hoisted CLOSE below is never wrong in direction. The window
        // word still poisons SPEND through `windowMention`, so nothing on the
        // grant side opens by walking past this line.
        if tokens.contains("night"), door == nil || !hasClosingVerb(text) { return .silence }
        if says(text, bedtime) || says(text, quiet), door == nil {
            return .command(.downHoursQuery)
        }

        // 4. CLOSING VERBS — "no more X today", "block X", "im done with X",
        //    "stop letting me open X", "close X". Lexical proposal only; the
        //    polarity that matters is recomputed by state diff in the Validator.
        //    A trailing "until 9" rides along as a stated hour; "everything" or
        //    "all" in the door slot closes every door at once.
        //    (docs/design/handoff/Silk Mockup.dc.html:327-331)
        //
        //    HOISTED, and unchanged in content. It used to sit after BUDGET;
        //    it now executes ahead of every rule that can produce a ceiling,
        //    because a close is the tightest thing in the product and is never
        //    wrong in direction. Rule 4.5 can raise a ceiling and rule 2.5 can
        //    remove one, and a `!hasClosingVerb` veto written into each of them
        //    is a list that goes stale the moment a third is added — which is
        //    exactly how "block tiktok, 20 minutes a day is plenty" came back
        //    having RAISED a ten-minute ceiling to twenty, parked it for
        //    tomorrow, and never shut the door at all. ORDER covers every cap
        //    path at once, including the ones not written yet: a doorful close
        //    returns here and nothing below it runs, and every cap rule below
        //    requires a named door, so a doorless close cannot reach them
        //    either.
        //
        //    The rule numbers below are identities, not positions — every
        //    cross-reference in the source and in docs/design/per-app-caps.md
        //    still names the same rule.
        //
        //    What the hoist costs, stated rather than discovered later: "block
        //    instagram and make it 30 a day" was `setBudget(30)` and is now a
        //    close on Instagram. Both are tightenings, the close is the tighter,
        //    and a sentence naming a close first has never had a second
        //    compilation. A doorless "cut off my budget at 30 a day" is
        //    unaffected: rule 4 declines without a door and rule 3 still has it.
        if hasClosingVerb(text) {
            let until = restUntil(in: text)
            if let d = door {
                return .command(.closeDoorToday(door: d, until: until))
            }
            // The doorless close is about the REST OF TODAY, and a period word
            // with a number is a statement about every day. "cut off all my
            // apps at 30 a day" and "block everything, 30 a day" set an
            // allowance and name no door and no deadline; the hoist put this arm
            // in front of BUDGET and turned both into a close over every door
            // for the rest of the day. The doorful arm above keeps the hoist
            // whole — "block tiktok, 20 minutes a day is plenty" is still a
            // close — because there the sentence named the door it wants shut.
            if tokens.contains("everything") || tokens.contains("all"),
               !((statesAPeriod(text) || mentionsThePool(tokens)) && number != nil) {
                return .command(.closeAllToday(until: until))
            }
        }

        // 2.5 + 4.5 CAPS — one ceiling on one door, set or cleared. See
        //     `capOutcome` for the two rules and what each would get wrong
        //     without the clause gate.
        //
        //     Ahead of BUDGET because a cap sentence may carry a period word
        //     ("tiktok 20 a day", "no daily limit on tiktok") and rule 3 claims
        //     100% of those. Ahead of ADD/REMOVE because "remove the tiktok
        //     cap" and "drop the tiktok limit" both open with a token rule 5
        //     reads as a door removal — this feature manufactures the two
        //     sentences that DESTROY a door by asking about its ceiling. Ahead
        //     of SPEND, which is the rule the set sentences are being taken
        //     back from: "cap tiktok at 20" granted twenty minutes and
        //     unshielded the app, in reply to a sentence asking to restrict it.
        //
        //     A window word makes a number's meaning ambiguous — "cap tiktok at
        //     bedtime" is a schedule, and per-app schedules are out of scope —
        //     so the whole family defers, exactly as SPEND does.
        if door != nil, !windowMention,
           let outcome = capOutcome(clauses(), state: state, text: text) {
            return outcome
        }

        // 3. BUDGET — "make it thirty minutes a day", "thirty a day", "budget of 40".
        //
        //    It no longer needs a cap branch: every period-word sentence that a
        //    door plainly owns has already been claimed above. What is left here
        //    is the pool's own sentence — and rule 3 TERMINATES on every path.
        //    That is not decoration. The previous attempt let one shape fall out
        //    of this block so a later rule could have it, and when that rule also
        //    declined, the union of two correct refusals walked past ADD/REMOVE
        //    into SPEND: "give me 60 a day max on tiktok" debited the entire
        //    remaining budget and took the wall down, out of a sentence stating a
        //    daily maximum. A period word makes a sentence a statement about
        //    every day, and no statement about every day may spend today's pool.
        // The trigger is two questions, not one: a statement about every day,
        // or a sentence that says the pool's NAME at all.
        //
        // RULE 3 TERMINATES ON EVERY PATH, and the trigger is where that
        // invariant lives. It was briefly narrowed — the pool arm fired only
        // when the pool noun preceded the number — and the sentences it stopped
        // claiming did not stop existing: they fell THROUGH, past ADD/REMOVE
        // into SPEND, and "drop me to 20, im over budget on instagram" DELETED
        // A DOOR while "cut me to 20, tiktok is eating my budget" opened one.
        // That is the exact failure the block's own comment below describes
        // from the last time it was allowed to fall out of its own arm. So the
        // trigger is wide and the DECISION inside it is narrow.
        if statesAPeriod(text) || mentionsThePool(tokens) {
            guard let n = number else { return .silence }
            // A QUESTION THE SENTENCE ITSELF ANSWERS "no" IS DECLINED — the
            // pool's own copy of the cap family's veto, which lived only in
            // `capSet` where no pool sentence reaches it, so a request-modal
            // pool question the sentence itself answers "no" wrote the
            // refused allowance: "should i set my budget to 30? tbh no"
            // became the standing budget with only a toast (ROUND 6, n25 —
            // FINDING 10 replayed one family over). Anchored on the pool's
            // number exactly as `namesThePool`, `poolStatementIsAttributed`
            // and the fallback's mood gate anchor it — the first number
            // token, or the idioms' own "hour" — and asked AHEAD of the
            // shortcut so both of rule 3's write paths sit behind it.
            // Terminating silence, rule 3's own invariant: the answer to a
            // question is never a new allowance.
            let poolAnchor = tokens.indices.first(where: {
                NumberParser.readsAsNumber(tokens[$0])
            }) ?? tokens.firstIndex(of: "hour")
            if let poolAnchor,
               let asked = clauses().clauseRange(containing: poolAnchor),
               aLaterClauseDeclinesTheAsk(clauses(), clause: asked) {
                return .silence
            }
            // Naming the pool means the pool, however close a door stands:
            // "budget of 40 for instagram" is 40 minutes of budget, and "bump
            // my daily budget to 60 tiktok is killing me" is a budget raise
            // with a reason attached — but only when the pool OWNS the number.
            // "budget" used to be matched as a bare substring of the whole
            // sentence, so "give me 20 of tiktok, im on a budget" halved the
            // shared pool instantly, answered "20 left today.", and never
            // opened TikTok. A sentence that merely mentions budgeting states
            // no new allowance; it terminates here, and silence reaches the
            // widener, which can read it as the spend it is. Ownership is
            // clause-scoped — see `namesThePool` for the mirrored order and
            // the idiom that each defeated the pure position test.
            if mentionsThePool(tokens), namesThePool(clauses()) {
                // A QUOTED ALLOWANCE IS NOT AN INSTRUCTION. The shortcut had
                // no attribution gate, so "they said set my budget to 40, no
                // cap on tiktok" wrote the allowance the sentence only
                // reports — where the fallback's own mood gate
                // (`describesRatherThanSetsThePool`) would have refused on
                // the spoken subject "they" (ROUND 3, n10). A speech verb
                // ahead of the pool's number in the number's own clause is
                // somebody's words being reported, and a quoted allowance is
                // a parked RAISE whenever it exceeds the standing pool.
                // Terminating silence — rule 3's own invariant — and the
                // FINDING 11 pool-claim veto still parks the trailing
                // clearing, so both prongs fail closed at once.
                if poolStatementIsAttributed(clauses()) { return .silence }
                // A QUESTION ASKED BY INVERSION IS STILL A QUESTION. The
                // shortcut's mood gating was the attribution test alone, so a
                // pool question fronted with a plain auxiliary — "am" is not
                // a request modal, and "gonna" holds no seat — walked past
                // both the declined-ask veto (keyed on `requestModals` in the
                // asked clause) and this arm's own gate: "am i really gonna
                // set my budget to 30? no" wrote the refused allowance, and
                // the decline was not even load-bearing — the bare question
                // wrote the same 30 (ROUND 7, n29 — FINDING 10 replayed one
                // MOOD over). The cap family already refuses the inverted
                // question on `reportsRatherThanAsks`' fronted-auxiliary
                // core ("was tiktok capped at an even 20 before" is pinned
                // silence); this is that core, one family over. Terminating
                // silence — rule 3's own invariant: the answer to a question
                // is never a new allowance.
                if poolAskIsAnInvertedQuestion(clauses()) { return .silence }
                return .command(.setBudget(minutes: n))
            }
            // A sentence that merely MENTIONS budgeting states no new
            // allowance, and it does not get a shortcut. It falls to the guards
            // below — the same ones every other period-word sentence passes —
            // which is what makes this narrowing safe: rule 3 still terminates
            // on every path, and the door guard still refuses to move the pool
            // on a sentence about one app.
            // Otherwise the pool's sentence is about no door in particular. If
            // the clause carrying the number NAMES a door and no cap rule above
            // could read it, the sentence is about that door and the pool must
            // not move on it — "20 a day for youtube and reddit" names two doors
            // and one ceiling, and cutting everyone's budget is not what it
            // asked for. Silence reaches the widener, which cannot produce a cap
            // at all (§5.7) and so cannot get the door wrong either.
            //
            // The same question asked the other way round for the sentence
            // whose ceiling word and number were split by a clause opener:
            // "cap tiktok so i only get 20 a day" puts the door in one breath
            // and its number in the next, so the number's clause names no door
            // and the pool moved on a sentence about one app. A ceiling word
            // LEADING a door is the shape `capSet` itself reads; a clause with
            // that shape and no number of its own has proposed a ceiling this
            // grammar cannot resolve, and the pool is not the consolation prize.
            // Scoped to the LEADING order on purpose — "make it 30 a day, tiktok
            // is my limit" and "60 a day, tiktok is past my limit" trail their
            // ceiling word behind the door, where it is commentary, and those
            // sentences still move the pool.
            if door != nil, numberClauseNamesADoor(clauses(), state: state)
                || aCeilingLeadsADoorWithNoNumber(clauses(), state: state)
                || aBareDoorTopicPrecedesTheNumberClause(clauses(), state: state) {
                return .silence
            }
            // A REPORT IS NOT AN INSTRUCTION, and a REFUSAL IS NOT ONE EITHER —
            // the discipline the cap family already has, extended to the pool's
            // own fallback. This arm used to fire on "a day"/"daily" plus any
            // single number with no mood gate and no negator scan, so doorless
            // chatter rewrote the shared allowance: "i smoke 5 a day, trying to
            // quit" cut the day to five minutes, "my daily standup ran 45
            // minutes again" set 45, and "i would never allow 60 a day" wrote
            // the very number it refuses — every one an instant tighten whose
            // only receipt is "N left today.". The gate is the same shape as
            // `capSet`'s: silence terminates, and the widener (which owns
            // `setBudget` behind the Validator's provenance) gets the sentence
            // instead of the pool losing it.
            if describesRatherThanSetsThePool(clauses(), state: state) { return .silence }
            return .command(.setBudget(minutes: n))
        }

        // 5. ADD / REMOVE a door. "add reddit" — the name is whatever follows,
        //    unless it carries a number: "add 30 minutes" is a budget ask in
        //    disguise, not a door called "30 minutes". Silence over minting.
        if tokens.first == "add", tokens.count >= 2 {
            let name = tokens.dropFirst().joined(separator: " ")
            if NumberParser.readsAsNumber(name) { return .silence }
            if state.door(named: name) != nil {
                // Adding an existing door is a no-op ask; treat as silence.
                return .silence
            }
            return .command(.addDoor(name: name))
        }
        //    The removal branch declines two shapes, and deletion is the one
        //    outcome this file can never take back, so it gets neither of them.
        //
        //    A CEILING NAMED IN THE DOOR'S OWN BREATH is not a door. This is a
        //    BELT, and says so: the cap rules above claim every removal-shaped
        //    ceiling sentence they can read, and a clause they cannot read
        //    terminates in silence rather than walking down here. What is left
        //    for this guard is the sentence whose ceiling word trails its door
        //    with no remover beside it — "drop, tiktok is my limit" — which no
        //    cap rule matches and which must still not delete TikTok. Deletion
        //    takes the app, its shield and its alias table, and it is the one
        //    outcome this file can never take back, so it does not get the
        //    sentences nobody could read.
        //
        //    The guard is CLAUSE-scoped, and that is the whole of it: "drop
        //    tiktok, im at my limit" and "drop instagram, ive hit my limit 20
        //    times" carry the same noun in a second breath, where it is a reason
        //    and not an object, and they ARE door removals. A sentence-wide
        //    `hasCapNoun` reads them as ceilings and answers a request to delete
        //    a door with silence.
        //
        //    A NUMBER THE SENTENCE POINTS AT is a ceiling with the noun elided:
        //    "drop tiktok to 20" and "drop tiktok down to 20" are somebody
        //    lowering a cap, and answering them by deleting the door is the
        //    same unrecoverable mistake. The guard is the DIRECTION, not the
        //    digit — written as "a number anywhere" it turned "drop instagram
        //    for good, ive wasted 3 hours today", "remove youtube, i have 2 too
        //    many" and "remove instagram after 5 years" into GRANTS on the very
        //    doors the user asked to delete.
        //    AND BOTH REFUSALS TERMINATE. Declining and walking on is what this
        //    file's own comment says killed the previous attempt one rule over:
        //    "the union of two correct refusals walked past ADD/REMOVE into
        //    SPEND". It happened again here. "drop tiktok to 20" is somebody
        //    lowering a ceiling; the guard below spared the door, nothing else
        //    claimed the sentence, and rule 7 answered it by DEBITING TWENTY
        //    MINUTES AND TAKING THE WALL DOWN on the very app being restricted.
        //    A removal-shaped sentence this rule cannot read compiles to
        //    nothing. Silence reaches the widener, which per §5.7 can produce
        //    neither a cap nor a deletion, so it cannot get this wrong either.
        if (tokens.first == "remove" || tokens.first == "drop"), let d = door {
            guard !capNounSharesTheDoorsClause(clauses(), state: state, door: d),
                  !doorsClauseStatesANewCeiling(clauses(), state: state, door: d)
            else { return .silence }
            return .command(.removeDoor(door: d))
        }

        // 6. PLACE-BOUND SPEND — a door plus a place-phrase and no number at
        //    all. "give me instagram until i leave the gym" / "while im at the
        //    gym…"
        //    A condition can start a grant; only a number can end one. The
        //    answer is no longer "How long?" — a question that took whatever
        //    fragment came back as the whole ask — but the sentence itself.
        //    NOT WHEN THE ASK IS NEGATED. "dont give me instagram while im at
        //    work" is a rule she is stating, not a sentence to be written out
        //    for her; the refusal below is rule 7's own, read here so the two
        //    halves of the spend grammar cannot disagree about "dont".
        if let d = door, hasPlaceBinding(text), numbers.isEmpty {
            guard !aNegatorRefusesTheAsk(clauses()), !asksForLess(tokens) else { return .silence }
            return .writeItOut(door: d, minutes: nil)
        }

        // 7. SPEND — the hot path. A door and exactly one number, with the door
        //    occupying a real slot (not an incidental mention). Window words
        //    make the number's meaning ambiguous — "keep instagram quiet until
        //    9" must not become a nine-minute grant — so those sentences defer
        //    to the model instead.
        //
        //    AND THE NUMBER'S CLAUSE MUST FUND THE DOOR BEING GRANTED. Three
        //    readings of one invariant, every one asked of door ids with the
        //    same test the cap rules use, so "give me 20 of instagrams,
        //    instagram i mean" is still one door named twice — once inflected,
        //    once bare — and still spends.
        //    SEVERAL doors in the clause — "instagram tiktok ten" — is two
        //    names competing for one quantity, and granting whichever was
        //    spelled first is the guess `parse`'s `number` binding has refused
        //    for numbers since the parser shipped: several is not one, and one
        //    is the only count that compiles.
        //    ONE door in the clause must BE the door in hand. "tiktok is my
        //    weakness, give me 15 of reddit" funds reddit while `firstDoor`
        //    holds tiktok; a guard that only counted answered yes and the
        //    grant left on a door no clause paid for.
        //    NO door in the clause hands the question to the whole sentence,
        //    which must then name exactly one: "im at my limit on tiktok, give
        //    me 20 minutes" says tiktok and spends, and "20 minutes, tiktok or
        //    instagram" says two, where first-spelled-wins is the same refused
        //    guess wearing a comma.
        //    Every refusal terminates: silence reaches the widener, and a
        //    grant on the wrong door cannot be taken back.
        //    AND A REFUSAL IS NOT AN ASK. A negator standing in front of the
        //    door is the same fact rule 4.5 already reads for ceilings, and
        //    SPEND never learned it: "no tiktok for 20 minutes" bought twenty
        //    minutes of the app the sentence was refusing. It stayed small only
        //    because the hour spellings carried no number — "no tiktok for 2h"
        //    was silent and "no tiktok for 2 hours" granted two minutes — so
        //    reading the unit turned a two-minute mistake into a two-hour one,
        //    which is how it was found. The hole is older than the unit.
        //
        //    Silence and not a decline, for the reason the cap rule states:
        //    declining walks into the next rule and buys the app anyway.
        if let d = door, let n = number, !windowMention {
            guard spendClauseFunds(d, clauses(), state: state) else { return .silence }
            guard !aRefusalNamesTheDoor(d, clauses(), state: state) else { return .silence }
            // AND A NEGATOR ON THE OPENING VERB IS THE SAME REFUSAL. "dont
            // open tiktok for 20 minutes" is the plainest way to type one, and
            // the noun scan above cannot see it — while the close rule vetoes
            // itself on the opener token, so nothing else claimed the sentence
            // and the refused app was opened for exactly the refused minutes.
            guard !aNegatorRefusesTheAsk(clauses()) else { return .silence }
            // A STATED DEADLINE IS NOT A DURATION. "give me tiktok till 7"
            // asks for the app until a CLOCK; reading the 7 as seven minutes
            // debits the pool on a reading no human shares, and the re-ask
            // after those minutes double-debits the day. The close side reads
            // the same words as a clock ("block tiktok until 9"); the grant
            // side cannot state a deadline, so it stays silent rather than
            // misread one.
            guard !theNumberIsADeadline(clauses()) else { return .silence }
            // SECONDS ARE NOT MINUTES. "give me 30 seconds of instagram" granted
            // thirty MINUTES — sixty times the stated ask, the mirror of the
            // "2 hours -> 2 minutes" class the number reader exists to kill.
            // The domain cannot hold a fraction of a minute, so the path
            // declines the unit the way the cap rule declines hours.
            guard !theNumberStatesSeconds(clauses()) else { return .silence }
            // AND A REPORT IS NOT AN ASK — the gate the cap family has had
            // since `reportsRatherThanSets`, extended to the one rule where
            // the wrong answer is the unrecoverable direction: "i watched
            // tiktok for 45 minutes at lunch" was answered with an open door
            // and a debited pool, and the parse being non-silent meant the
            // widener never saw it.
            let commits = statesACommitment(clauses(), state: state)
            guard !reportsRatherThanSpends(clauses(), state: state, commitment: commits)
            else { return .silence }
            // AND AN ASK NEEDS A VERB. This is the one point in the file that
            // mints minutes, and until now a door standing next to a number
            // was enough: "instagram 10" opened Instagram for ten minutes,
            // and so did every sentence that happened to mention an app and a
            // quantity in one breath. A door and a number are the OBJECT and
            // the AMOUNT of a request; the request itself is the verb, and
            // nothing here required one.
            //
            // NOT SILENCE. Silence would hand the shortcut to the widener,
            // which is a model, and a model asked to read "instagram 10" will
            // read it as the grant this line just refused — the tightening
            // would last exactly as long as it took to reach the fallback.
            // `.writeItOut` terminates the turn on a POSITIVE answer that
            // debits nothing and shows the sentence that would grant, so the
            // next thing typed is a sentence this rule can mint from.
            //
            // The commitment frame counts as the verb. "im using instagram for
            // 5 minutes" carries "using" on the list; "i'm going on instagram
            // for 10" and "i'm spending 10 on instagram" carry the gerund of
            // one, which no token match can see — see `statesACommitment`,
            // which the mood gate above just consulted for the same sentence.
            guard hasOpeningVerb(tokens) || commits else {
                return .writeItOut(door: d, minutes: n)
            }
            return .command(.spend(door: d, minutes: n))
        }

        // 8. ELLIPTICAL ASK — a door named with an opening verb and no duration.
        //    "give me instagram" is a real request missing one word, and the
        //    answer is the whole sentence with the word in it: "Write it out:
        //    unlock Instagram for 10 min." Silence here read as not listening.
        //    (docs/design/handoff/Silk Mockup.dc.html:322)
        //    NO duration means NONE: "give me ten or twenty of tiktok" has no
        //    single number, but writing a sentence out for somebody who stated
        //    two durations is not listening either — that ambiguity is the
        //    widener's, exactly as rule 7 refuses it.
        //    AND NOT WHEN THE VERB IS NEGATED. "dont give me tiktok",
        //    "whatever you do do not open instagram tonight" carry an opening
        //    verb and mean its opposite; handing back "Write it out: unlock
        //    TikTok for 10 min." to somebody refusing TikTok is not listening
        //    either. Rule 7's negator guard, for the same reason it is read in
        //    rule 6: one refusal for every shape of the ask.
        //    AND NOT FOR A SENTENCE ASKING FOR LESS. "i need to use instagram
        //    less", "i want to cut down on tiktok" carry an opening verb and
        //    a door and mean the opposite of an ask; writing out the sentence
        //    that opens the app is the wrong answer to somebody asking for
        //    help closing it. They fall silent — the widener's, if there is
        //    one — on a refusal-only word list (`asksForLess`), where a word
        //    nobody thought of costs a hint and never a grant.
        if let d = door, numbers.isEmpty, hasOpeningVerb(tokens) {
            guard !aNegatorRefusesTheAsk(clauses()), !asksForLess(tokens) else { return .silence }
            return .writeItOut(door: d, minutes: nil)
        }

        // 9. THE NUMBER ALONE — "10", "10 minutes", "ten min please". Somebody
        //    who was just handed "Write it out: unlock Instagram for 10 min."
        //    and typed back the part she thought was missing.
        //
        //    LAST, after every rule that can claim a sentence, so nothing loses
        //    one: "budget 30" is still a setter and reaches this line never.
        //    The tokens must be the number and NOTHING but units and filler —
        //    an unrecognised word means the sentence is prose and prose is the
        //    widener's, exactly as it was before this rule existed.
        //
        //    The door is the FIRST door, because a number names none and the
        //    hint has to name one to be a sentence. It is a guess, and it is
        //    free: nothing is debited, nothing opens, and the user reads the
        //    door's name in the reply before she types it.
        //    The door is the one the bar last wrote out for her when there is
        //    one (`recentDoor`, still hers — a door removed since is not
        //    guessed), and the FIRST door otherwise, because a number names
        //    none and the hint has to name one to be a sentence. Either way it
        //    is free: nothing is debited, nothing opens, and she reads the
        //    door's name in the reply before she types it.
        if let n = number, isBareQuantity(tokens) {
            let remembered = recentDoor.flatMap { r in state.doors.first { $0.id == r.id } }
            guard let hinted = remembered ?? state.doors.first else { return .silence }
            return .writeItOut(door: hinted, minutes: n)
        }

        // 10. THE DOOR ALONE — "instagram", "tiktok please". The other half of
        //     the same fragment, and the same answer with the minutes left for
        //     the hint to supply.
        if numbers.isEmpty, let d = bareDoor(tokens, state: state) {
            return .writeItOut(door: d, minutes: nil)
        }

        return .silence
    }

    /// Whether the sentence is a QUANTITY and nothing else — the number, its
    /// unit, and the words that carry neither meaning nor a proposition.
    ///
    /// A whitelist, for the reason every whitelist in this file is one: written
    /// as "no verb and no door" it would claim arbitrary prose, and this rule
    /// stands after every other, where a wrong claim silently takes a sentence
    /// off some earlier rule's successor. Every token must be either part of
    /// the number ("twenty five" is two tokens and one quantity) or a word on
    /// the list.
    private static func isBareQuantity(_ tokens: [String]) -> Bool {
        // "twenty five minutes please" is four tokens; six is already more
        // than this shape can be, and the bound is what keeps a pasted
        // ten-thousand-word sentence from being walked here at all.
        guard (1...6).contains(tokens.count) else { return false }
        return tokens.allSatisfy { tok in
            bareQuantityWords.contains(tok) || Int(tok) != nil || NumberParser.isNumberWord(tok)
        }
    }

    /// The units and filler a bare quantity may wear. Minutes only: "2 hours"
    /// is a quantity this product cannot spend in a day it has already capped
    /// at one, and a bare "2 hours" is more likely a report than an ask.
    private static let bareQuantityWords: Set<String> = [
        "min", "mins", "minute", "minutes", "m", "for", "of", "please", "pls",
    ]

    /// The door named with nothing but politeness around it: "instagram",
    /// "tiktok please". Matched through `door(_:in:)` like every other door in
    /// this file, so the deinflection ("hinges") is the same one, and matched
    /// on the WHOLE remainder so a second noun refuses.
    private static func bareDoor(_ tokens: [String], state: PolicyState) -> Door? {
        // A door name is one token or two, and the politeness is one more, so
        // four is already more than this shape can be. The bound is here and
        // not inside the filter because it is what keeps a ten-thousand-word
        // paste from allocating a ten-thousand-word string on the way to `nil`
        // (`hugeInputStaysCheapAndSilent`).
        guard (1...4).contains(tokens.count) else { return nil }
        let rest = tokens.filter { $0 != "please" && $0 != "pls" }
        guard !rest.isEmpty else { return nil }
        return door(rest.joined(separator: " "), in: state)
    }

    // MARK: - Doors

    private static func firstDoor(in tokens: [String], state: PolicyState) -> Door? {
        // Single-token names. A door answers to its NAME and to nothing
        // else now (Door.spokenForms), so there is no nickname table to walk.
        for tok in tokens {
            if let d = door(tok, in: state) { return d }
        }
        // Two-token names ("focus friend" style), just in case.
        for i in 0..<max(0, tokens.count - 1) {
            if let d = door(tokens[i] + " " + tokens[i + 1], in: state) { return d }
        }
        return nil
    }

    /// One door name, matched through its inflections. Every door recognizer in
    /// this file goes through here so they cannot disagree about what counts as
    /// a name — and what counts is the door's own name, case-folded, plus the
    /// trailing "s" this function strips. No aliases, no catalogue nicknames:
    /// "10 minutes of insta" names no door at all now.
    ///
    /// "tiktok's daily limit is 20" and "tiktoks daily limit is 20" are one
    /// sentence with one meaning, and they parsed differently because the
    /// tokenizer splits on punctuation: the apostrophe form became ["tiktok",
    /// "s"] and matched, the bare plural stayed one token and did not. So the
    /// second one named no door, no cap rule could see it, and it cut the
    /// SHARED budget from 40 to 20 — instantly, because a tighten does not wait
    /// — on the strength of whether the user typed an apostrophe.
    ///
    /// Nothing is minted. The stripped form still has to hit a spoken form
    /// exactly, so "limits", "caps" and "minutes" match nothing, and the only
    /// way this can invent a door is if the user owns one whose name is another
    /// door's name plus an "s".
    private static func door(_ form: String, in state: PolicyState) -> Door? {
        if let d = state.door(named: form) { return d }
        guard let base = deinflected(form) else { return nil }
        return state.door(named: base)
    }

    /// A trailing plural or possessive "s", stripped — or nil when the token is
    /// too short for the ending to be an inflection rather than the word, or
    /// when the token is a word of English in its own right.
    private static func deinflected(_ form: String) -> String? {
        guard form.count > 3, form.hasSuffix("s"), !ordinaryWords.contains(form) else { return nil }
        return String(form.dropLast())
    }

    /// The words whose final "s" is not an inflection of a door's name, however
    /// much they look like one. THIS IS ABOUT DEINFLECTION AND NOTHING ELSE:
    /// door matching is token-exact everywhere in this file, so "anything else"
    /// and "nothing else" have never named Hinge and are not what this guards.
    /// The token itself is looked up in a Set — a substring test here would
    /// find "hinge" inside both of those and is exactly the mistake this file
    /// has paid for four times over in the cap lexicon.
    ///
    /// "everything hinges on it, give me 20 minutes" is the sentence that
    /// bought the list. With a Hinge door in state, "hinges" deinflected to
    /// "hinge", `firstDoor` takes the earliest match in the sentence, and rule
    /// 7 found a door and one number and FUNDED TWENTY MINUTES OF HINGE out of
    /// an ordinary English verb. The clause guard could not save it: the number
    /// sits in a doorless breath, which defers to the whole sentence, and the
    /// whole sentence named exactly one door — the wrong one, and the only one.
    ///
    /// A LIST IS THE RIGHT SHAPE HERE, for the reason `negators` is a list: a
    /// word added can only ever SUBTRACT a door match, and a door match not
    /// made is a silence that reaches the widener. It cannot invent a grant, so
    /// the direction it fails in is the safe one. That is the opposite of the
    /// cap lexicon's whitelists, where an unrecognised word had to decline.
    ///
    /// THE TEST FOR MEMBERSHIP is both halves at once: the inflected form must
    /// have a common ordinary-English reading, AND no natural reading as the
    /// app. "snaps" fails the second half and is deliberately absent — "show me
    /// my snaps" is a real way to ask for Snapchat, and blocking it would cost
    /// a sentence to buy nothing, because nobody's patience snapping is
    /// followed by a request for minutes. Nobody says "my hinges" either.
    /// Rarities like "discords" and "amazons" fail the first half; a seat here
    /// costs the plural of a real door name, and a word with no sentence is not
    /// worth one.
    private static let ordinaryWords: Set<String> = ["hinges"]

    /// The door whose name BEGINS at `i`, and the index of the token its name
    /// ENDS on. One token, or the bigram `t[i] + " " + t[i + 1]` when a second
    /// token is still inside `bound`.
    ///
    /// **Every "is there a door here" scan in this file goes through here.**
    /// They were six copies of the same three lines, and they have to agree to
    /// the token: `doorIndex` exists only to say where `doors` matched,
    /// `clauseNames` asks the same question about one id, and `capSet` reads
    /// the END of the name to know which tokens ARE the door — a scan that
    /// disagreed with its neighbour by one token would let the door's own
    /// determiner read as a fresh phrase and kill the shape.
    ///
    /// `bound` and not `t.count` because most callers ask WITHIN A CLAUSE: a
    /// bigram straddling a boundary is two breaths, not a name. Callers reading
    /// the whole utterance pass `t.count` and get the same rule.
    ///
    /// ONE TOKEN WINS over the bigram, which is how `doors(in:of:state:)`
    /// always resolved it. The two can only disagree in a state where one
    /// door's name is another door's name plus a word, and no catalogue entry
    /// is shaped like that.
    ///
    /// THE INVARIANT THE TWO-TOKEN PATH RESTS ON: every door name today is a
    /// single catalogue display token, so in any shipping state the bigram
    /// matches nothing at all. The path stays because the catalogue may one day
    /// carry a two-word entry, and it is exercised by the tests that build a
    /// door with a two-word name — a dead branch nothing tests is a branch that
    /// will be wrong when it wakes.
    ///
    /// That invariant is also the fast path. Building the bigram costs a
    /// concatenation plus the `lowercased()` inside `door(named:)`, on every
    /// token of arbitrary prose — the paste path's whole budget — to ask a
    /// question whose answer is already known from the roster. So the roster is
    /// asked instead: no space in any door's key, no bigram.
    private static func doorAt(_ t: [String], _ i: Int, within bound: Int,
                               state: PolicyState) -> (door: Door, end: Int)? {
        guard i < bound else { return nil }
        if let d = door(t[i], in: state) { return (d, i) }
        guard i + 1 < bound, anyDoorNameIsTwoTokens(state),
              let d = door(t[i] + " " + t[i + 1], in: state)
        else { return nil }
        return (d, i + 1)
    }

    /// Whether any door's name is more than one token — the roster question
    /// `doorAt` asks before it will pay for a bigram. A scan of at most six
    /// short keys, against a string built and lowercased per token otherwise.
    private static func anyDoorNameIsTwoTokens(_ state: PolicyState) -> Bool {
        state.doors.contains { $0.key.utf8.contains(UInt8(ascii: " ")) }
    }

    /// How many doors a clause names, and which. One door named twice — once
    /// bare and once inflected, "cap instagram at 20, instagrams eating my day"
    /// — is still one door: the test is on the id, not on the count of matches.
    private enum ClauseDoors {
        case none
        case one(Door)
        case several
    }

    private static func doors(in clause: Range<Int>, of index: NumberParser.ClauseIndex,
                              state: PolicyState) -> ClauseDoors {
        let t = index.tokens
        var found: Door?
        for i in clause {
            guard let d = doorAt(t, i, within: clause.upperBound, state: state)?.door
            else { continue }
            if let already = found, already.id != d.id { return .several }
            found = d
        }
        guard let found else { return .none }
        return .one(found)
    }

    /// Where a door's name first stands inside a clause, matched exactly as
    /// `doors(in:of:state:)` matches it so the two can never disagree.
    private static func doorIndex(in clause: Range<Int>, of index: NumberParser.ClauseIndex,
                                  state: PolicyState) -> Int? {
        let t = index.tokens
        return clause.first { doorAt(t, $0, within: clause.upperBound, state: state) != nil }
    }

    // MARK: - The cap lexicon

    /// The sentence's own word for a ceiling. A NOUN names the rule and can
    /// stand as its verb ("cap tiktok at 20", "i want tiktok capped at 20"); a
    /// QUANTIFIER only bounds whatever it is attached to, which may be a
    /// ceiling or may be this afternoon's ask ("let me on tiktok, max 20").
    /// The two are separated because only the second is ever a hedge.
    ///
    /// Every one of these matches at a TOKEN boundary, never as a substring:
    /// "unlimited" contains "limit" and is a grant-shaped ask, exactly as
    /// "unlock" contains "lock", "tonight" contains "night" and "weekend"
    /// contains "end". This file has paid for the substring four times.
    ///
    /// "capping" is the gerund of the same word, and its absence left the
    /// politest cap request of all shaped like nothing: "would you mind
    /// capping tiktok at 20" carried no cap lexeme, walked to rule 7, and the
    /// fronted "would" bought the spend gate's request-modal exemption — a
    /// GRANT on the app being restricted (ROUND 3, n8). An entry here can
    /// only pull a clause out of the grant direction and into this family's
    /// own gates: the reports stay reports ("im capping tiktok at 20" still
    /// dies on the subject-ahead scan), and the polite inversion compiles to
    /// the set it wraps.
    private static let capNouns: Set<String> = ["cap", "caps", "capped", "capping",
                                                "limit", "limits", "ceiling"]
    private static let capQuantifiers: Set<String> = ["max", "maximum", "under"]

    /// The verbs that take a ceiling away. "uncap" needs no noun beside it; the
    /// rest do.
    ///
    /// "without", "forget" and "any" are deliberately NOT here. Each produced a
    /// loosening out of a demand FOR a ceiling — "no tiktok without a limit",
    /// "dont forget the tiktok limit", "set any limit on tiktok" — and "any" in
    /// particular cannot be rescued by structure, because it sits directly on
    /// the noun in both the demand and the refusal. The only word that tells
    /// those apart is the NEGATOR, which is already the word doing the work.
    private static let capRemovers: Set<String> = ["remove", "drop", "lift", "off",
                                                   "rid", "uncap", "uncapped"]

    /// Words that negate what follows them. A negator is not a lexeme to be
    /// added to a list of removers; it is a property of the clause that REVERSES
    /// one. Every other negation precedent in this file errs toward tightening
    /// ("dont block instagram" still closes); this is the first that can loosen,
    /// which is why it is modelled rather than ignored.
    ///
    /// THE CONTRACTION FAMILY IS COMPLETE, and completing it is the one place a
    /// list is the right answer in this file. `capSet`'s veto and
    /// `clearingPhrase` both read this set to REFUSE, so a word added here can
    /// only ever subtract a ceiling change — the direction both rules must fail
    /// in. It cost 110 sentences to leave half-written: "i shouldnt cap tiktok
    /// at 20", "tiktok isnt capped at 20" and the rest of {shouldnt, wouldnt,
    /// couldnt, isnt, arent, wasnt, havent, hasnt, mustnt, aint} × five setter
    /// phrasings wrote the ceiling they refuse, which against a capped door is a
    /// parked RAISE. The apostrophe spellings are here for the reason
    /// `door(_:in:)` deinflects: an apostrophe is not a rule.
    ///
    /// The LEXICAL negators — "refuse", "nobody", "no one" — are the same
    /// argument. `reportsRatherThanAsks` refuses them in the clearing direction
    /// by their spoken subject, and that test cannot reach a clause whose
    /// subject is elided; the word itself can.
    private static let negators: Set<String> = ["no", "none", "not", "never",
                                                "dont", "don't", "doesnt", "doesn't",
                                                "cant", "can't", "wont", "won't",
                                                "didnt", "didn't",
                                                "isnt", "isn't", "arent", "aren't",
                                                "wasnt", "wasn't", "werent", "weren't",
                                                "shouldnt", "shouldn't",
                                                "wouldnt", "wouldn't",
                                                "couldnt", "couldn't",
                                                "mustnt", "mustn't",
                                                "havent", "haven't", "hasnt", "hasn't",
                                                "hadnt", "hadn't", "aint", "ain't",
                                                "refuse", "refuses", "nobody", "noone"]

    /// The negators that can stand directly on a noun phrase, which is the only
    /// way a bare word clears a ceiling on its own ("no cap on tiktok").
    private static let nounNegators: Set<String> = ["no", "none", "not", "never"]

    /// The spoken declines — the interjections that answer a question "no"
    /// without negating anything else in this grammar. "should i cap tiktok at
    /// 20? nah" wrote the ceiling the asker talked themselves out of, because
    /// the declined-question veto asked its answer clause to be all
    /// `nounNegators` and the commonest spoken decline there is was not in the
    /// inventory (ROUND 3, n3). Read ONLY by that veto, and only to SILENCE a
    /// setter — an entry here can only subtract a written ceiling, which is
    /// the direction the family must fail in. NOT added to `nounNegators`
    /// itself: that set also feeds the clearing family, where a new word is a
    /// LOOSENING, and "nah cap on tiktok" must not start clearing ceilings.
    ///
    /// "nope" — the single commonest spoken decline in English — held no seat,
    /// so the brand-new n25 pool veto was defeated on its first round by the
    /// same inventory-by-subtraction move that produced n3, this time in the
    /// decline inventory rather than the transparency one: "should i set my
    /// budget to 30? nope" wrote the refused allowance (ROUND 7, n28). Seated
    /// with its spelling variant "naw" — the fix is the class edge, not one
    /// word.
    private static let spokenDeclines: Set<String> = ["nah", "naw", "nope", "nvm"]

    /// The transparent discourse adverbs an ANSWER clause may carry without
    /// ceasing to answer. "should i cap tiktok at 20? actually no" answers no
    /// — and the declined-question veto's allSatisfy broke first on
    /// "actually" (ROUND 3, n9) and then, with "actually" admitted alone, on
    /// its nearest neighbours: "honestly no" and "probably not" both lifted
    /// the veto and wrote the refused ceiling (ROUND 4, n13). An inventory
    /// rather than one word, because the class is the handful of adverbs
    /// English drops into an answer slot without adding a proposition of
    /// their own — which is why "tbh" is in it: the lexicon's own slang
    /// spelling of "honestly", already seated in `trailingParticles` AND
    /// `slangEmphatics` as propositionless, broke the same allSatisfy one
    /// synonym over and "should i cap tiktok at 20? tbh no" wrote the
    /// refused ceiling (ROUND 5, n18 — the n3/n9/n13 seam's fourth
    /// iteration). And the seat belongs to the CLASS, not the word: "ngl"
    /// and "fr" each held the identical two propositionless seats "tbh"
    /// held, and each broke the same allSatisfy one synonym over again —
    /// "should i cap tiktok at 20? ngl no" and "? fr no" both wrote the
    /// refused ceiling (ROUND 6, n21 — the seam's fifth iteration). So the
    /// inventory takes the whole of `slangEmphatics` by construction: a
    /// word this lexicon already classifies as propositionless slang
    /// cannot be missing its answer seat, and a sixth synonym cannot
    /// reopen the seam. Read by the declined-question vetoes, and by the
    /// report gates' lead-slot step-over (`clauseLead`); the veto's clause
    /// must still CONTAIN a decline — a bare trailing adverb answers
    /// nothing — and every read can only subtract a written ceiling or an
    /// allowance move, the direction both families must fail in.
    ///
    /// "yeah" is the one non-adverb with a seat: the colloquial decline
    /// "yeah no" CUSHIONS its "no" with an affirmation that answers nothing
    /// on its own, and with no seat the allSatisfy broke on it exactly as it
    /// broke on the adverbs (ROUND 7's inventory sweep, beside n27/n28). The
    /// contains-a-decline guard keeps the bare affirmation inert — "should i
    /// cap tiktok at 20? ngl yeah" is pinned to LAND — so the seat can only
    /// subtract, like every other read of this set.
    private static let answerSlotAdverbs: Set<String> =
        Set(["actually", "honestly", "probably", "definitely", "yeah"]).union(slangEmphatics)

    /// Words that open a noun phrase. Only the clearing rule reads them, and
    /// only to find where a ceiling's own phrase STARTS — "take the 20 minute
    /// cap off tiktok" quotes its number to say which ceiling, and that number
    /// lives inside the phrase the remover is moving.
    private static let determiners: Set<String> = ["the", "a", "an", "my", "our",
                                                   "this", "that", "any", "some"]

    /// Prepositions that aim a number at a ceiling. "drop the tiktok limit TO
    /// 20" states a new one; "remove the 20 minute tiktok cap" does not, and
    /// the difference is this word and nothing else. A NUMBER IS NOT ALWAYS A
    /// CEILING, and gating a clearing on the mere absence of a number answered
    /// a request to remove a restriction by installing one.
    private static let ceilingPrepositions: Set<String> = ["to", "at", "of", "under", "below"]

    /// The verbs that ask to be let in, as SINGLE TOKENS — `hasOpeningVerb`
    /// answers only whether the sentence carries one anywhere, and the cap
    /// rules need the position. "lemme" is the same word as "let me": the
    /// tokenizer keeps it whole, so the two spellings reach here as one token
    /// and as two, and "lemme have under 20 of tiktok" compiled to a permanent
    /// ceiling while "let me have under 20 of tiktok" spent.
    /// "have" is on it because the suite's own canonical spend is "can i HAVE
    /// twenty minutes of tiktok" — the class was always "ask to be let in", and
    /// the word was missing from it, so "can i have max 20 of tiktok" compiled
    /// to a permanent ceiling while "give me max 20 of tiktok" spent. "lemme"
    /// was added beside it and then taken off again: every sentence it would
    /// have caught spells the ask "lemme HAVE …", so the word had no sentence of
    /// its own, and a lexeme with no sentence is a lexeme that cannot be tested.
    private static let askVerbs: Set<String> = ["give", "gimme", "let", "open",
                                                "unlock", "want", "need", "have"]

    /// The stems of `openingVerbs`, DERIVED from it and never written by
    /// hand: the one-word verbs, and the first word of the phrasal ones whose
    /// second word is an object or a particle ("give me", "let me", "go on",
    /// "get on"). Frames that open with a pronoun or a modal ("i want", "can
    /// i", "i'd like") contribute nothing — a negator does not stand on those.
    /// Read ONLY by `aNegatorRefusesTheAsk`, the spend path's own refusal, so
    /// a stem here can turn a grant into silence and can do nothing else; and
    /// derived so that the next verb added to the grant is refused by the
    /// same edit, which is the hole the hand-kept copy of this list had. The
    /// cap family keeps reading `askVerbs` alone, which is the lexicon its
    /// own rows were pinned against.
    private static let openingVerbStems: Set<String> = Set(openingVerbPhrases.compactMap { phrase in
        if phrase.count == 1 { return phrase[0] }
        return phrase.count == 2 && (phrase[1] == "me" || phrase[1] == "on") ? phrase[0] : nil
    })

    /// The words that can stand INSIDE a ceiling's own noun phrase: a
    /// determiner, a number, a measure or period word, the door being talked
    /// about, the prepositions that hang a phrase off a noun, and the particles
    /// that trail one without predicating anything of it.
    ///
    /// A WHITELIST, and that is the entire safety argument. Written as a
    /// blacklist — "no pronoun and no subordinator between the remover and the
    /// noun" — every word nobody thought of CLEARS a ceiling, which is the
    /// direction this file has been lost in three times. Written this way an
    /// unrecognised word declines, and a declined clearing costs a silence.
    ///
    /// What it buys, and each of these was a loosening: "turn off tiktok im at
    /// my limit" and eleven sentences like it ask for the APP to be shut and
    /// name the ceiling as the reason — "im", "ive", "until" and "its" cannot
    /// stand inside a noun phrase, so the ceiling is not what the remover is
    /// moving. "i dont want a bigger tiktok limit" is a plea for a SMALLER one,
    /// and "bigger" is the word that says the negation landed on the size.
    /// "i dont want the tiktok cap removed" predicates a removal OF the ceiling,
    /// and "removed" is not a noun-phrase word either.
    private static let measureWords: Set<String> = ["minute", "minutes", "min", "mins",
                                                    "hour", "hours", "hr", "hrs",
                                                    "second", "seconds", "sec", "secs",
                                                    "daily", "day", "days", "week", "weekly"]
    private static let phrasePrepositions: Set<String> = ["of", "on", "for", "in", "from"]
    /// The slang emphatics ride with the grammar's own particles: "no cap on
    /// tiktok fr fr" trails its plea with emphasis, not with a predicate. A
    /// word here can only ADMIT a tail — it never widens what counts as a
    /// remover or a ceiling — so the cost of a wrong entry is a clearing this
    /// file would otherwise have declined, and every entry is a word with no
    /// other reading in this lexicon.
    private static let trailingParticles: Set<String> = ["anymore", "please", "today",
                                                          "tonight", "thanks",
                                                          "fr", "frfr", "ngl", "rn",
                                                          "tho", "lol", "lmao", "tbh",
                                                          "lowkey", "highkey", "deadass",
                                                          "pls", "plz", "tops"]

    /// The pure SLANG half of `trailingParticles` — the Gen-Z emphatics, as
    /// opposed to politeness ("please", "pls") and timing ("today"). Read only
    /// by the emphatic gate in `clearingPhrase`, and only to REFUSE a
    /// clearing: a slang particle standing AHEAD of a bare negator marks the
    /// phrase as the slang "no cap" ("fr no cap tho tiktok"), exactly as an
    /// unrecognized Gen-Z opener does — the whitelist admitted these as
    /// noun-phrase filler because the same words legitimately TRAIL a real
    /// clearing ("no cap on tiktok fr fr"), and the tail admission must not
    /// double as an opener pass (FINDING 9). An entry here can only subtract
    /// a loosening, which is the direction the family must fail in.
    ///
    /// "lowkey" was the class's missing member: propositionless answer-slot
    /// slang that appeared in this grammar only as a chatter example inside
    /// `clearingPhrase`'s comment, so the by-construction union
    /// (`answerSlotAdverbs`) missed it and "should i cap tiktok at 20? lowkey
    /// no" wrote the refused ceiling — the n3/n9/n13/n18/n21 seam's sixth
    /// iteration, at the union's own edge (ROUND 7, n27). Seated here, where
    /// "tbh"/"fr"/"ngl" sit, together with the class's remaining common
    /// members ("highkey", "deadass") — the fix is the class edge, not one
    /// word.
    private static let slangEmphatics: Set<String> = ["fr", "frfr", "ngl", "tbh",
                                                      "tho", "lol", "lmao", "rn",
                                                      "lowkey", "highkey", "deadass"]

    /// The auxiliaries and copulas, contractions included. A finite verb is what
    /// turns a request into a REPORT — "no limit on tiktok" asks for one to go,
    /// "there IS no limit on tiktok" says one is already gone — and putting one
    /// in front of the subject is how English asks a question without a question
    /// mark: "did you take the cap off tiktok".
    ///
    /// A closed class, which is what makes it safe to write down. The verbs that
    /// can head an imperative are an OPEN class and could never be listed; these
    /// are the whole inventory of English, so the mood test is written as their
    /// complement. It is also why the contraction family costs nothing to
    /// complete here and cost a defect in `negators`: "i shouldnt remove the
    /// tiktok cap" is refused for having a finite verb, not for the "n't".
    private static let auxiliaries: Set<String> = [
        "is", "isnt", "isn't", "are", "arent", "aren't", "was", "wasnt", "wasn't",
        "were", "werent", "weren't", "am", "be", "been", "being",
        "do", "does", "doesnt", "doesn't", "did", "didnt", "didn't",
        "has", "hasnt", "hasn't", "have", "havent", "haven't", "had", "hadnt", "hadn't",
        "can", "cant", "can't", "could", "couldnt", "couldn't",
        "should", "shouldnt", "shouldn't", "would", "wouldnt", "wouldn't",
        "will", "wont", "won't", "shall", "may", "might", "must",
    ]

    /// The MODALS, which are the auxiliaries that ask rather than report. Every
    /// other finite verb puts a clause in the indicative and makes it a
    /// description — "the tiktok cap IS 60" — but a modal is how English wraps
    /// an instruction in politeness: "CAN i cap tiktok at 20", "my tiktok limit
    /// SHOULD be 20 a day". Both of those are pinned setters, and a mood gate
    /// written without this exemption refuses them.
    ///
    /// A subset of `auxiliaries` rather than a set beside it, so the two cannot
    /// disagree about whether a word is a finite verb: the mood test asks for a
    /// finite verb that is NOT a modal.
    private static let modals: Set<String> = [
        "can", "cant", "can't", "could", "couldnt", "couldn't",
        "should", "shouldnt", "shouldn't", "would", "wouldnt", "wouldn't",
        "will", "wont", "won't", "shall", "may", "might", "must", "mustnt", "mustn't",
    ]

    /// The REQUEST modals: the half of `modals` that can wrap an instruction.
    /// "CAN i cap tiktok at 20" and "my tiktok limit SHOULD be 20 a day" are
    /// pinned setters and are the whole reason the setter's mood gate has a
    /// modal exemption at all.
    ///
    /// The EPISTEMIC half — {will, may, might, must} and "will"'s contraction —
    /// is not here. Dropping it, together with the wh-word narrowing beside it,
    /// closed 149 sentences: "the tiktok cap WILL be 60", "tiktok MIGHT be
    /// capped at 60", "i MUST have capped tiktok at 60", "there WILL be a 60
    /// minute limit on tiktok". Every one is a speculation or a recollection
    /// ABOUT a ceiling, and every one wrote the ceiling it speculates about,
    /// which against a capped door is a parked
    /// raise. A pinned setter is always a request, never a speculation, so the
    /// exemption the requests need is narrower than the class it was written on.
    ///
    /// A subset of `modals` for the same reason `modals` is a subset of
    /// `auxiliaries`: the mood test and the finite-verb test must not disagree
    /// about what a word is.
    private static let requestModals: Set<String> = [
        "can", "cant", "can't", "could", "couldnt", "couldn't",
        "should", "shouldnt", "shouldn't", "would", "wouldnt", "wouldn't", "shall",
    ]

    /// The third-party subjects — the pronouns that hand a clause's verb to
    /// somebody who is not the speaker and not the one being asked. Read ONLY
    /// by the requestModals exemption's subject guard in
    /// `reportsRatherThanSets`: "can you believe THEY capped tiktok at 20" is
    /// a rhetorical report, not a request, and the pronoun is what says whose
    /// act the modal is wrapping. A subset of `subjects` so the two sets
    /// cannot disagree about what a word is; first person ("i") and the
    /// imperative's addressee ("you") are deliberately absent, because those
    /// are exactly the requests the exemption exists for.
    private static let thirdPartySubjects: Set<String> = [
        "he", "she", "they", "theyve", "they've",
    ]

    /// The wh-words. A question is never a rule change — README rule 1's own
    /// principle, applied to STATUS since the parser shipped and to nothing
    /// else, which is how "why is there no limit on tiktok" came back having
    /// REMOVED the ceiling the sentence was complaining about the absence of.
    private static let whWords: Set<String> = ["why", "how", "what", "whats", "what's",
                                               "who", "whos", "who's", "whose",
                                               "where", "when", "which"]

    /// The pronouns and expletives that can stand as a clause's subject. English
    /// marks a command by leaving the subject OUT, so a clause that speaks one is
    /// describing rather than instructing.
    private static let subjects: Set<String> = [
        "i", "im", "i'm", "ive", "i've", "id", "i'd", "ill", "i'll",
        "you", "youve", "you've", "youre", "you're", "we", "weve", "we've",
        "he", "she", "they", "theyve", "they've", "it", "its", "it's",
        "there", "theres", "there's", "that", "thats", "that's", "this", "these", "those",
        "nobody", "noone", "somebody", "someone", "everybody", "everyone", "anybody", "anyone",
    ]

    /// The verbs of wanting. The one command that does speak its own subject is
    /// the first-person volition — "i want the tiktok cap gone", "i dont want a
    /// limit on tiktok" — which the clearing rule already reads as a remover.
    private static let volitions: Set<String> = ["want", "wanna", "need", "wish"]

    /// The period phrase, as the token shape rule 3's own trigger has: "a day",
    /// "per day", "daily". Token-shaped rather than substring so that "today"
    /// is not "a day" and "instagram 20 for the day" is not a habit — that
    /// sentence is an ordinary spend and reading its "day" as a period would
    /// turn a grant into a permanent ceiling.
    private static func periodPhrase(_ t: [String], in clause: Range<Int>) -> Bool {
        clause.contains { i in
            if t[i] == "daily" { return true }
            return t[i] == "day" && i > clause.lowerBound
                && (t[i - 1] == "a" || t[i - 1] == "per")
        }
    }

    /// Whether the sentence is about a period rather than about now. Rule 3's
    /// own trigger, `internal` so the invariant suite can ask the parser the
    /// same question the parser asks — a restated copy in the tests would
    /// drift, and then the property proved is not the property that ships.
    static func statesAPeriod(_ text: String) -> Bool {
        saysAny(text, periodPhrases)
    }

    private static let periodPhrases: [Phrase] =
        [" a day", "per day", "daily"].map(Phrase.init)

    /// The window's own names, read as substrings by rule 2 and its two query
    /// arms. "night" is deliberately not here — it matches as a TOKEN, and the
    /// comment in `parse` says why.
    private static let downHour = Phrase("down hour")
    private static let bedtime = Phrase("bedtime")
    private static let quiet = Phrase("quiet")

    /// Whether the sentence says the pool's name at all — rule 3's other
    /// trigger, and the doorless close's veto.
    ///
    /// The STEM, token-shaped, because both halves of that matter. `statesAPeriod`
    /// used to carry "budget" as a bare SUBSTRING of the whole utterance, which
    /// is how "give me 20 of tiktok, im on a budget" halved the daily allowance
    /// — the defect `namesThePool` below exists to fix. Narrowing it to the
    /// exact token went too far the other way: "budgeted", "budgeting" and
    /// "budgets" stopped claiming their sentences, and rule 3 not claiming a
    /// sentence means some LATER rule does. "last week i budgeted 60 for
    /// youtube" walked into the rules below it, and "block everything, my
    /// budget is 30" lost the veto that keeps a doorless close off a sentence
    /// stating an allowance — closing every door in the product instead.
    ///
    /// A stem is what the substring was reaching for and a token is the shape
    /// the rest of this file uses, so it is both.
    static func mentionsThePool(_ tokens: [String]) -> Bool {
        tokens.contains { $0.hasPrefix("budget") }
    }

    /// Whether the pool OWNS the sentence's number — the narrower question, and
    /// the only one that may move the allowance.
    ///
    /// That was the loosest test in the file, and it cost the user her ask:
    /// "give me 20 of tiktok, im on a budget" said `statesAPeriod`, took rule 3,
    /// found the token, and set the DAILY ALLOWANCE to twenty — instantly,
    /// because tightening does not wait — then answered "20 left today.", which
    /// reads like a plausible reply to the question she asked. Nothing opened.
    /// The pool was halved by a sentence that merely mentioned budgeting, and
    /// "budget" was the only entry in the period test matched as a substring
    /// rather than as a token (contrast `periodPhrase`, which is token-shaped
    /// precisely so that "today" is not "a day").
    ///
    /// The pool's own sentence puts its number AFTER the pool noun — and IN
    /// THE POOL NOUN'S OWN BREATH — because that is what stating a new value
    /// looks like in English: "budget of 40", "set the budget to 25", "my
    /// tiktok budget should be 25", "i want a budget of 40". A sentence whose
    /// number comes first is a sentence about something else with budgeting
    /// mentioned afterwards, and the number belongs to whatever asked for it.
    ///
    /// POSITION ALONE WAS NOT ENOUGH, and the sentence that proved it is the
    /// mirror of the one this function was written to fix: "im on a budget,
    /// give me 20 of tiktok" puts the pool noun BEFORE the number — in a
    /// different clause, attached to a different thought — and a pure order
    /// test handed the 20 to the pool. Same cut, same instant tighten, same
    /// silent non-opening as the forward order, surviving in exactly the
    /// "[budget excuse], [spend ask]" shape people actually type. So the pool
    /// owns the number only when it stands before it in the SAME clause; a
    /// noun in another breath is commentary, and the sentence falls to the
    /// guards below like every other period-word sentence.
    ///
    /// A number that occupies NO token — the idioms, where "my budget is an
    /// hour" carries its 60 in no digit anywhere — is anchored at the idiom's
    /// own "hour", which every idiom in `allNumbers`' table contains. The
    /// first draft skipped the anchor and answered "the pool's" whenever no
    /// token parsed as a number, on the theory that a quantity nothing spells
    /// has no competing claim — and the competing claim was the spend ask
    /// standing right on it: "give me an hour of tiktok, im on a budget"
    /// resurrected the fixed defect through the idiom door, in the exact
    /// forward order the tests pin for digits.
    ///
    /// Takes the clause index rather than bare tokens because the clause
    /// question cannot be answered after `tokenize` has erased the commas;
    /// rule 3 builds the index only when the pool stem is present, so the
    /// sentences that never mention it never pay (see `clauses()`).
    /// `internal` for the same reason `statesAPeriod` is: the invariant suite
    /// asks the parser the same question the parser asks, and a restated copy in
    /// the tests would drift away from the rule it claims to prove.
    static func namesThePool(_ index: NumberParser.ClauseIndex) -> Bool {
        let tokens = index.tokens
        guard let pool = tokens.firstIndex(of: "budget") else { return false }
        // "budget" AS AN ADJECTIVE NAMES NO POOL. "we stayed at a budget hotel
        // for 3 nights" and "my budget phone died 2 times today" put the exact
        // token ahead of a number in one clause — the whole of the old test —
        // and cut the day's allowance to the count of nights or crashes,
        // instantly. The pool's own sentence CONTINUES from its noun: with a
        // preposition ("budget of 40", "set the budget to 25", "budget for the
        // day"), a finite verb ("my budget is 30", "my tiktok budget should be
        // 25"), the number itself ("daily budget 60"), or nothing at all
        // ("im on a budget"). A "budget" trailed by an ordinary noun is
        // modifying that noun, and the number belongs to whatever the noun is
        // doing — the sentence falls to the fallback's mood gate below like
        // any other period-word sentence.
        if let clause = index.clauseRange(containing: pool), pool + 1 < clause.upperBound {
            let next = tokens[pool + 1]
            let continues = ceilingPrepositions.contains(next)
                || phrasePrepositions.contains(next)
                || auxiliaries.contains(next) || negators.contains(next)
                || NumberParser.readsAsNumber(next)
            if !continues { return false }
        }
        let anchor = tokens.firstIndex(where: { NumberParser.readsAsNumber($0) })
            ?? tokens.firstIndex(of: "hour")
        guard let anchor else { return true }
        return pool < anchor && index.sameClause(pool, anchor)
    }

    /// Whether the pool statement is somebody's REPORTED words — a speech verb
    /// or a quotative standing ahead of the pool's number in the number's own
    /// clause ("they SAID set my budget to 40", "he WAS LIKE set my budget to
    /// 40"). Anchored exactly as `namesThePool` anchors: the first number
    /// token, or the idioms' own "hour". Read only by rule 3's shortcut, and
    /// only to SILENCE it into the fallback's own doctrine — so this test can
    /// only subtract an allowance move, which is the direction the pool must
    /// fail in (ROUND 3, n10; ROUND 4, n14).
    private static func poolStatementIsAttributed(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        let anchor = t.indices.first(where: { NumberParser.readsAsNumber(t[$0]) })
            ?? t.firstIndex(of: "hour")
        guard let anchor, let clause = index.clauseRange(containing: anchor) else { return false }
        let ahead = clause.lowerBound..<anchor
        if ahead.contains(where: { speechVerbs.contains(t[$0]) }) { return true }
        // THE QUOTATIVE REPORTS WORDS AS SURELY AS A SPEECH VERB. "he was
        // like set my budget to 40" carries no `speechVerbs` entry — the
        // dominant spoken quotative is a copula glued to its particle — so
        // the shortcut wrote the quoted allowance this gate exists to refuse
        // (ROUND 4, n14). The copula-particle pairs ("was like", "were
        // like", "be all" and their crossings) and the bare "goes" are the
        // whole inventory, and the pair must NOT stand directly on the
        // number: "my budget was like 40" hedges its own quantity — an
        // approximation, not somebody's words — where a quotative introduces
        // a sentence, never a bare number. Read by this gate and mirrored by
        // the bare-door-topic veto's attributed arm (ROUND 5, n19), and in
        // both places an entry can only subtract an allowance move — the
        // direction the pool must fail in.
        return ahead.contains { i in
            if t[i] == "goes" { return true }
            return ["was", "were", "be"].contains(t[i]) && i + 1 < clause.upperBound
                && ["like", "all"].contains(t[i + 1]) && i + 2 != anchor
        }
    }

    /// Whether the pool's sentence is a question asked by INVERSION — a plain
    /// finite auxiliary standing in the lead slot of the clause holding the
    /// pool's number ("AM i really gonna set my budget to 30"). English fronts
    /// an auxiliary to ask, and the request modals are the one fronting that
    /// wraps an instruction instead ("CAN you set my budget to 45" is a pinned
    /// setter) — the exact split `reportsRatherThanAsks`' fronted-auxiliary
    /// core and the `requestModals` doc already draw for the cap family.
    /// Anchored exactly as `namesThePool` anchors — the first number token, or
    /// the idioms' own "hour" — and read through `clauseLead`'s walk so a kept
    /// opener or a transparent adverb cannot evict the auxiliary from the slot.
    /// Read only by rule 3's shortcut, and only to SILENCE it, so this test can
    /// only subtract an allowance move — the direction the pool must fail in
    /// (ROUND 7, n29).
    private static func poolAskIsAnInvertedQuestion(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        let anchor = t.indices.first(where: { NumberParser.readsAsNumber(t[$0]) })
            ?? t.firstIndex(of: "hour")
        guard let anchor, let clause = index.clauseRange(containing: anchor) else { return false }
        let lead = clauseLead(t, clause: clause)
        return auxiliaries.contains(t[lead]) && !requestModals.contains(t[lead])
    }

    /// Whether the pool's fallback sentence is prose ABOUT a daily quantity
    /// rather than an instruction stating one — rule 3's mood gate, asked of
    /// the clause holding the number (or, for the token-less idioms, the
    /// idiom's own "hour", exactly as `namesThePool` anchors them).
    ///
    /// The discipline is `capSet`'s, but the tests are its own, because the
    /// pool's canonical setters speak words the cap gate refuses: "make IT 30 a
    /// day" carries a pronoun the cap gate reads as a subject, "40 a day IS
    /// what i already have" carries a copula after its number, and "i told my
    /// friends ID DO 30 a day" opens with the flattest report frame there is —
    /// all three are pinned setters. So the gate reads only what stands BEFORE
    /// the number, and reads it narrowly:
    ///
    ///  - a NEGATOR ahead of the number refuses the allowance it names ("i
    ///    would never allow 60 a day", "no way im doing 90 a day"), with the
    ///    "no more than" carve-out the cap scan already makes;
    ///  - a FIRST-PERSON COMMITMENT is a command however it opens: "id"/"ill"
    ///    anywhere ahead ("i told my friends id do 30 a day"), or "let"/"lets"
    ///    leading the clause ("lets do 30 a day from now on");
    ///  - a REQUEST MODAL ahead (no wh-word) and a VOLITION keep their
    ///    exemptions, exactly as in `reportsRatherThanSets`;
    ///  - then a spoken SUBJECT or wh-word leading the clause is a report ("i
    ///    smoke 5 a day", "we stayed at a budget hotel for 3 nights"); a
    ///    DETERMINER leading a clause that predicates something is one ("my
    ///    daily standup ran 45 minutes again" — while the fragment "an hour a
    ///    day" predicates nothing and stays a setter); and a FINITE non-modal
    ///    verb ahead of the number is a description ("the budget flight was 45
    ///    dollars").
    private static func describesRatherThanSetsThePool(_ index: NumberParser.ClauseIndex,
                                                       state: PolicyState) -> Bool {
        let t = index.tokens
        let anchor = t.indices.first(where: { NumberParser.readsAsNumber(t[$0]) })
            ?? t.firstIndex(of: "hour")
        guard let anchor, let clause = index.clauseRange(containing: anchor),
              let first = clause.first
        else { return false }
        let ahead = clause.lowerBound..<anchor
        let refused = ahead.contains { i in
            guard negators.contains(t[i]) else { return false }
            return !(t[i] == "no" && i + 2 < clause.upperBound
                     && t[i + 1] == "more" && t[i + 2] == "than")
        }
        if refused { return true }
        if ahead.contains(where: { t[$0] == "id" || t[$0] == "ill" }) { return false }
        if t[first] == "let" || t[first] == "lets" { return false }
        if !ahead.contains(where: { whWords.contains(t[$0]) }),
           ahead.contains(where: { requestModals.contains(t[$0]) }) { return false }
        if statesAVolition(t, clause: clause) { return false }
        if subjects.contains(t[first]) || whWords.contains(t[first]) { return true }
        if determiners.contains(t[first]), !predicatesNothing(t, clause: clause, state: state) {
            return true
        }
        // A participle ahead of the number heads a report with its subject
        // elided: "rent DROPPED 5 a day" and "SPENT 40 a day on apps once"
        // state facts, not allowances.
        if ahead.contains(where: { isHabitParticiple(t[$0]) }) { return true }
        // A finite verb ahead of the number describes; but only when what it
        // predicates is not the allowance's own vocabulary. "daily limits are
        // 20" is a pinned setter whose subject IS the rule; "the budget
        // flight was 45 dollars" predicates of a flight.
        guard ahead.contains(where: { auxiliaries.contains(t[$0]) && !modals.contains(t[$0]) })
        else { return false }
        return !ahead.allSatisfy { i in
            auxiliaries.contains(t[i]) || isNounPhraseWord(t, i, state: state)
                || capNouns.contains(t[i]) || capQuantifiers.contains(t[i])
                || t[i].hasPrefix("budget")
        }
    }

    /// Whether one token could stand inside a ceiling's own noun phrase. See
    /// `measureWords` for why this is a whitelist and what it costs.
    private static func isNounPhraseWord(_ t: [String], _ i: Int, state: PolicyState) -> Bool {
        let w = t[i]
        if determiners.contains(w) || measureWords.contains(w)
            || phrasePrepositions.contains(w) || trailingParticles.contains(w) { return true }
        // A number premodifies a ceiling to say WHICH one — "the 20 minute cap".
        if NumberParser.readsAsNumber(w) { return true }
        // The door names the ceiling — "the TIKTOK cap" — and a two-token name
        // is admitted from either half, since neither word alone is the door.
        if door(w, in: state) != nil { return true }
        if i + 1 < t.count, door(w + " " + t[i + 1], in: state) != nil { return true }
        if i > 0, door(t[i - 1] + " " + w, in: state) != nil { return true }
        // The possessive's orphan. "tiktok's limit" reaches here as [tiktok,
        // s, limit] — the tokenizer splits on the apostrophe — and that "s" is
        // the door's own name continuing, not a word of the phrase's own.
        // Admitted only beside its door, the same skip `doorIsATopic` and
        // `doorHeadsTheSubject` already make.
        if w == "s", i > 0, door(t[i - 1], in: state) != nil { return true }
        return false
    }

    /// Whether every token in a range belongs to one noun phrase. The range is
    /// always one the clause already gave — between two words the rule found —
    /// so this is a bounded scan and never a threshold.
    private static func spansOneNounPhrase(_ t: [String], _ range: Range<Int>,
                                           state: PolicyState) -> Bool {
        range.allSatisfy { isNounPhraseWord(t, $0, state: state) }
    }

    /// The clause's LEAD SLOT — its first token that says something: past at
    /// most one kept clause opener (the four words `spendFragment` steps over;
    /// a second would have opened its own clause) and past any stack of
    /// transparent answer-slot adverbs, which drop into a clause without
    /// adding a proposition of their own.
    ///
    /// One walk, shared by the two report gates that key on what LEADS a
    /// clause, because the seam kept reopening one gate over: the gerund
    /// gate's step-over was exactly one opener and ONE adverb deep, so two
    /// stacked propositionless adverbs left it blind exactly as the raw
    /// t[clause.lowerBound] key had ("honestly tbh capping tiktok at 20
    /// never worked for me" — ROUND 6, n20), and `reportsRatherThanAsks`'
    /// final clause-lead determiner test read the raw first token with no
    /// step-over at all, so one kept opener or one transparent adverb
    /// evicted the demonstrative from the lead slot ("so that 20 minute cap
    /// on tiktok never worked for me" — ROUND 6, n24, the FINDING 7 seam's
    /// third resurrection). Both readers consume this walk to REFUSE a
    /// write, so the walk can only subtract one — the direction the family
    /// must fail in — and a clause that is nothing but openers and adverbs
    /// keeps its last token as the lead, which no gate reads as evidence.
    private static func clauseLead(_ t: [String], clause: Range<Int>) -> Int {
        var lead = clause.lowerBound
        if lead + 1 < clause.upperBound,
           ["but", "so", "anyway", "though"].contains(t[lead]) { lead += 1 }
        while lead + 1 < clause.upperBound,
              answerSlotAdverbs.contains(t[lead]) { lead += 1 }
        return lead
    }

    /// Whether this clause TALKS ABOUT a ceiling instead of asking for one to
    /// move. Two shapes, and both are structure rather than vocabulary.
    ///
    /// A FINITE VERB standing before the clearing words. "no limit on tiktok"
    /// asks for a restriction to go; "there IS no limit on tiktok", "i HAVE no
    /// limit on tiktok" and "tiktok IS not capped" report that one is already
    /// absent, and the copula is the whole difference. Fronted, the same verb is
    /// how English asks a question with no question mark — "did you take the cap
    /// off tiktok", "should i uncap tiktok", "is the tiktok cap off". Eleven such
    /// sentences came back as CLEARINGS, and against a capped door a clearing is
    /// a parked loosening that outlives the conversation that made it. README
    /// rule 1's own comment already says the answer to a question is never a new
    /// rule; it was applied to STATUS and to nothing else.
    ///
    /// A SPOKEN SUBJECT. English marks a command by leaving the subject out, so
    /// "remove the tiktok cap" is an instruction and "the tiktok cap isnt coming
    /// off" is a report. This is what refuses "i refuse to remove the tiktok
    /// cap" and "nobody should remove the tiktok cap" without adding a single
    /// word to `negators` — the list a reviewer rightly called arbitrary where
    /// it stopped, because a semantic class has no edge to stop at. Pronouns,
    /// auxiliaries and wh-words do.
    ///
    /// The one command that speaks its own subject is the first-person volition
    /// — "i want the tiktok cap gone", "i dont want a limit on tiktok" — reached
    /// by walking past the subject and whatever negation is glued to it. It is
    /// asked FIRST, which is the repair the scan below forced: the volition
    /// escape used to sit behind the scan and was unreachable whenever the scan
    /// found anything, so widening the scan by one set would have refused "i
    /// dont want any cap on tiktok" — a pinned clearing.
    ///
    /// A SUBJECT STANDING ANYWHERE BEFORE THE PHRASE, not only at the clause's
    /// first token. "apparently theres no cap on tiktok" speaks its subject one
    /// word in, and so do "honestly", "unfortunately", "right now", "turns out"
    /// and twenty more: twenty-three of twenty-nine adverbs tested turned the
    /// bare report — correctly refused — into a CLEARING. An adverb cannot make
    /// a report an instruction, and the scan already walked that span for
    /// auxiliaries and wh-words. One set wider, same bounded scan.
    /// A DOOR HEADING A NOUN PHRASE, which is the other way English speaks a
    /// subject and the one this feature manufactures — Settings prints the door
    /// name beside the word "cap" on a row, so "tiktoks cap sits at 60" is a
    /// sentence a user now has a reason to say. `subjects` lists the pronouns
    /// and expletives; a proper noun is a subject too, and the only proper nouns
    /// this parser knows are its doors.
    ///
    /// 160 sentences in one sweep: {tiktoks, tiktok's, tiktok, instagrams,
    /// instas} × {cap, limit, ceiling} × {sits at, stands at, went to, reads,
    /// shows, started at, …} × {45, 60} all WROTE the ceiling they report, which
    /// against a door capped at ten is a parked loosening out of a statement of
    /// fact. "the tiktok cap sits at 60" was already correctly silent — the only
    /// difference was the possessive — and the clearing half had the identical
    /// hole ("tiktoks got no cap" parked a clearing while "tiktok has no cap"
    /// fell silent). `main` matched none of these at all, having no door
    /// deinflection, so this PR both found the door and wrote the ceiling.
    private static func reportsRatherThanAsks(_ t: [String], clause: Range<Int>,
                                              phraseStart: Int, state: PolicyState) -> Bool {
        if statesAVolition(t, clause: clause) { return false }
        for i in clause.lowerBound..<min(phraseStart, clause.upperBound) {
            // A DEMONSTRATIVE STANDING DIRECTLY ON THE PHRASE OPENS IT.
            // `subjects` holds "that" and "this" for the report gates, and
            // this scan read them as spoken subjects even in the one slot
            // where they are determiners opening the ceiling's own phrase:
            // "set THAT 20 minute cap on tiktok" died as a report, one
            // determiner over from the pinned canonical setter "set a 15
            // minute cap on instagram" (ROUND 4, n16). The n5 fix already
            // rules a demonstrative between a recipient door and its
            // trailing cap noun a determiner, and the n6 pardon already
            // reads a determiner on the number as the number's own phrase
            // opener — this is the same word in the mirror slot, pardoned
            // only when it stands IMMEDIATELY on the phrase. Anywhere else
            // it keeps its subject reading, so "that caps tiktok at 20"
            // (the demonstrative one slot back, standing as a subject) is
            // still a report, and a clause the demonstrative LEADS still
            // answers to the determiner test below.
            if subjects.contains(t[i]), determiners.contains(t[i]), i + 1 == phraseStart {
                continue
            }
            if auxiliaries.contains(t[i]) || whWords.contains(t[i]) || subjects.contains(t[i]) {
                return true
            }
        }
        if doorHeadsTheSubject(t, clause: clause, state: state) { return true }
        // THE CLAUSE-LEAD TEST READS THE LEAD SLOT, NOT THE RAW FIRST TOKEN.
        // The demonstrative pardon above `continue`s past "that" standing
        // directly on the phrase, on the promise that "a clause the
        // demonstrative LEADS still answers to the determiner test below" —
        // and this guard read t[clause.first] raw, so one kept opener or one
        // transparent adverb evicted the demonstrative from the slot and the
        // promise went unkept: "so that 20 minute cap on tiktok never worked
        // for me" and "honestly that 20 minute cap on tiktok never worked
        // for me" both wrote the ceiling the report complains about, while
        // the unpreambled twin stayed silence (ROUND 6, n24 — the FINDING 7
        // seam's third resurrection, one gate over from the n17 fix). The
        // lead slot is `clauseLead`'s walk — the same one the gerund gate
        // consumes — and reading it here can only turn a write into a
        // report's silence.
        let lead = clauseLead(t, clause: clause)
        guard lead < clause.upperBound,
              subjects.contains(t[lead]) || auxiliaries.contains(t[lead])
                || whWords.contains(t[lead]) || determiners.contains(t[lead])
        else { return false }
        return true
    }

    /// Whether the clause opens with a door standing at the head of a noun
    /// phrase — the shape of "tiktoks cap sits at 60" and of "instagrams got no
    /// cap", and NOT the shape of the verbless setters this feature is built on.
    ///
    /// The walk runs forward from the door through everything that can belong to
    /// the noun phrase it heads, and answers YES the moment it meets a word that
    /// cannot. That word is the predicate, and a clause with a subject and a
    /// predicate is a report.
    ///
    /// Two escapes, and each is paid for by a pinned row:
    ///  - `per` is a noun-phrase word HERE and nowhere else. "tiktok 20 per day"
    ///    is a pinned setter whose "per" would otherwise read as the predicate;
    ///  - a CEILING PREPOSITION carrying a number is the elliptical setter
    ///    "tiktoks cap to 20", where the preposition aims a quantity rather than
    ///    predicating anything. "sits AT 60" does not reach this, because "sits"
    ///    already answered.
    private static func doorHeadsTheSubject(_ t: [String], clause: Range<Int>,
                                            state: PolicyState) -> Bool {
        let first = clause.lowerBound
        guard first < clause.upperBound, door(t[first], in: state) != nil else { return false }
        var j = first + 1
        if j < clause.upperBound, t[j] == "s" { j += 1 }
        while j < clause.upperBound {
            let w = t[j]
            if isNounPhraseWord(t, j, state: state) || capNouns.contains(w)
                || capQuantifiers.contains(w) || negators.contains(w)
                || capRemovers.contains(w) || w == "per" { j += 1; continue }
            if ceilingPrepositions.contains(w), j + 1 < clause.upperBound,
               NumberParser.readsAsNumber(t[j + 1]) { return false }
            return true
        }
        return false
    }

    /// Whether the clause is the one command that speaks its own subject: a
    /// first-person volition, reached by walking past the subject and whatever
    /// negation or auxiliary is glued to it. "i want a cap on tiktok", "i dont
    /// want any limit on instagram", "i want my instagram limit to be 20".
    ///
    /// Extracted from `reportsRatherThanAsks` so the setter's mood gate can ask
    /// the same question, and so it can be asked BEFORE the scans rather than
    /// after them. The entry condition is the same one the scan's guard has, so
    /// no clause answers this that would not have reached the walk before.
    private static func statesAVolition(_ t: [String], clause: Range<Int>) -> Bool {
        guard let first = clause.first,
              subjects.contains(t[first]) || auxiliaries.contains(t[first])
                || whWords.contains(t[first]) || determiners.contains(t[first])
        else { return false }
        var j = first + 1
        while j < clause.upperBound, auxiliaries.contains(t[j]) || negators.contains(t[j]) {
            j += 1
        }
        return j < clause.upperBound && volitions.contains(t[j])
    }

    /// Whether the clause predicates NOTHING of what it names — a bare noun
    /// phrase, which cannot be a report because a report needs a verb.
    ///
    /// The mood gate's one exemption that is not a word: "a 20 minute cap on
    /// tiktok a day" and "an hour a day of tiktok" open with a determiner, which
    /// is a shape reports also have ("the tiktok cap is 60"), and both are
    /// pinned setters. What separates them is that the first two are noun
    /// phrases all the way to the end and the third has a copula. Written as a
    /// list of opening frames this would be the same mistake `capSet`'s own
    /// comment records; written as `spansOneNounPhrase` plus the cap lexicon it
    /// is the question this file already asks everywhere else, and an
    /// unrecognised word makes the clause a predicate, which REFUSES.
    private static func predicatesNothing(_ t: [String], clause: Range<Int>,
                                          state: PolicyState) -> Bool {
        clause.allSatisfy { i in
            isNounPhraseWord(t, i, state: state)
                || capNouns.contains(t[i]) || capQuantifiers.contains(t[i])
        }
    }

    /// Whether this clause DESCRIBES a ceiling instead of asking for one — the
    /// setter's half of the mood gate, and the root cause of three blockers.
    ///
    /// `capCleared` got `reportsRatherThanAsks` and `capSet` got nothing, so the
    /// pair was perfectly asymmetric: "there is no limit on tiktok" was
    /// correctly silent and "there is a 60 minute limit on tiktok" WROTE a
    /// sixty-minute ceiling. Against a door capped at ten that is a parked
    /// raise, out of a sentence that is not an instruction at all. A report is
    /// not an instruction in either direction.
    ///
    /// A FINITE VERB ANYWHERE IN THE CLAUSE, not only before the phrase. The
    /// clearing rule scans forward because a clearing phrase runs to the end of
    /// what it removes; a setter's number can stand before its copula ("30
    /// minutes a day on tiktok is too much") or after it ("the tiktok cap is
    /// 60"), and only the whole-clause question reads both.
    ///
    /// THREE EXEMPTIONS, and each is paid for by a pinned row:
    ///  - a REQUEST MODAL before the number or the door marks a REQUEST — "can i
    ///    cap tiktok at 20", "my tiktok limit should be 20 a day";
    ///  - a first-person VOLITION is the command that speaks its own subject —
    ///    "i want my instagram limit to be 20";
    ///  - a clause that PREDICATES NOTHING is a fragment, and a fragment naming
    ///    a ceiling has proposed one — "a 20 minute cap on tiktok a day", "an
    ///    hour a day of tiktok".
    private static func reportsRatherThanSets(_ t: [String], clause: Range<Int>,
                                              phraseStart: Int, state: PolicyState) -> Bool {
        // THE EXEMPTION IS FOR REQUESTS, AND A QUESTION IS NOT ONE. Written
        // unconditionally on the whole modal class, this early return preempted
        // the finite-verb test, the wh-word test AND the spoken-subject test, so
        // one polite auxiliary anywhere ahead of the phrase bought a clause the
        // right to write a ceiling. Two narrowings, 149 sentences:
        //  - a WH-WORD before the phrase defeats it. "why should the tiktok cap
        //    be 60" and "can you tell me why the tiktok cap is 60" are askings
        //    ABOUT a ceiling and both wrote one; README rule 1's principle is
        //    that the answer to a question is never a new rule, and the modal
        //    was letting the question skip the gate that enforces it.
        //  - only the REQUEST modals qualify. See `requestModals`.
        //
        // AND THE REQUEST MUST BE THE SPEAKER'S OWN. The exemption had no
        // subject guard, so a third-party sentence wearing a modal wrote
        // standing policy: "can you believe they capped tiktok at 20" is a
        // rhetorical report of somebody else's act, and "my mom would cap the
        // tiktok at 20 if she could" is an attributed hypothetical — both
        // walked through on one polite auxiliary (ROUND 3, n1). Two guards,
        // each a closed class:
        //  - a THIRD-PARTY SUBJECT anywhere ahead of the phrase defeats it —
        //    the modal is wrapping "they capped", not a request;
        //  - the word standing DIRECTLY ON the modal must be one a request
        //    can put there. English glues a declarative modal to its
        //    subject's last word, so that slot holds the whole answer: a
        //    fronted modal is the question's own inversion ("CAN i cap
        //    tiktok at 20", "WOULD you kindly cap youtube at 25"), "i" and
        //    "you" are the speaker and the one being asked ("everyone says i
        //    SHOULD cap tiktok at 20" is a first-person committal however it
        //    opens), and the rule's own noun phrase is the subject-is-the-
        //    rule setter ("my tiktok limit SHOULD be 20 a day"). "my mom
        //    WOULD cap" puts the attributed person exactly there, and an
        //    unrecognised word in that slot makes the clause an attribution,
        //    which REFUSES the exemption and lets the report gates read the
        //    sentence. Adjacency, not a span scan — a scan from the clause's
        //    start would refuse the reported first-person committal above.
        let ahead = clause.lowerBound..<min(phraseStart, clause.upperBound)
        if !ahead.contains(where: { whWords.contains(t[$0]) }),
           let modalAt = ahead.first(where: { requestModals.contains(t[$0]) }),
           !ahead.contains(where: { thirdPartySubjects.contains(t[$0]) }),
           modalAt == clause.lowerBound || t[modalAt - 1] == "i" || t[modalAt - 1] == "you"
               || isNounPhraseWord(t, modalAt - 1, state: state)
               || capNouns.contains(t[modalAt - 1])
               || capQuantifiers.contains(t[modalAt - 1]) { return false }
        if statesAVolition(t, clause: clause) { return false }
        // A CLAUSE LED BY THE GERUND HAS SPOKEN ITS SUBJECT — THE GERUND
        // PHRASE ITSELF — AND WHAT TRAILS THE NUMBER IS PREDICATED OF IT.
        // Every report scan here reads only what stands AHEAD of the phrase,
        // and the finite-verb test below reads only `auxiliaries` — so a
        // clause that LEADS with the cap lexeme's gerund put its evidence
        // entirely behind the number, where no gate looked: "capping tiktok
        // at 20 never worked for me" (a past-efficacy report) and "capping
        // tiktok at 20 would free up my budget" (a weighed hypothetical)
        // both wrote the ceiling they only discuss (ROUND 4, n12). English
        // heads an imperative with a BASE verb — the habitual arm's own
        // doctrine, "a gerund or past participle heads a description" — so
        // the leading gerund is a subject, and a tail after its number that
        // cannot belong to the ceiling's own noun phrase is a predicate: a
        // report. The polite inversion keeps its set ("would you mind
        // capping tiktok at 20" — the gerund does not lead), and the bare
        // restatement keeps its fragment reading ("capping tiktok at 20 a
        // day" — the tail is the phrase's own vocabulary, and an empty tail
        // predicates nothing).
        //
        // AND THE LEAD SLOT IS THE FIRST TOKEN THAT SAYS SOMETHING. Written
        // on t[clause.lowerBound] raw with a number-bearing token required
        // at phraseStart, transparent material defeated both keys at once
        // (ROUND 5, n17): a kept clause opener occupies the first slot ("ok
        // so capping tiktok at 20 never worked for me" — the FINDING 7
        // seam, resurrected a second time), one transparent adverb evicts
        // the gerund the same way ("honestly capping tiktok at 20 would
        // free up my budget", whose "would" is a modal the finite-verb test
        // below rightly excludes), and the idiom table's quantity occupies
        // no token at all ("capping tiktok at an hour never worked for me"
        // — against a capped door a parked RAISE to 60) — while the report
        // evidence sat behind the number, where no other gate reads. The
        // lead slot is `clauseLead`'s walk: one kept opener, exactly as
        // `spendFragment` and the remover-claim arm step over the same four
        // words (at most one can lead a clause — a second would have opened
        // its own), then any STACK of `answerSlotAdverbs` entries — the
        // walk was one adverb deep, so two stacked propositionless adverbs
        // left the gerund off the lead slot and the gate went blind exactly
        // as the raw t[clause.lowerBound] key had ("honestly tbh capping
        // tiktok at 20 never worked for me" — ROUND 6, n20). A read that
        // can only subtract a written ceiling.
        //
        // And a token-less quantity anchors the tail at the idiom's own
        // last word — "hour" or "half", which every idiom in `allNumbers`'
        // table ends in — ONLY where the word ahead of it is the idiom's
        // own determiner half ("a", "an", "one", "half", "quarter": the
        // whole table's inventory of predecessors). A bare last-word scan
        // took any "half" in the clause, so a decoy that is nobody's
        // quantity anchored an empty tail and stood the gate down while the
        // report evidence sat between the idiom's real hour and the decoy,
        // where no gate read: "capping tiktok at an hour never worked for
        // my better half" parked a RAISE to 60 against the capped door
        // (ROUND 6, n20). The predecessor gate can only move the anchor OFF
        // a decoy and back onto the quantity — one more read that only
        // subtracts.
        let gerundLead = clauseLead(t, clause: clause)
        if capNouns.contains(t[gerundLead]), t[gerundLead].hasSuffix("ing") {
            let anchor: Int?
            if phraseStart < clause.upperBound,
               NumberParser.readsAsNumber(t[phraseStart]) {
                anchor = phraseStart
            } else {
                anchor = clause.last(where: { i in
                    (t[i] == "hour" || t[i] == "half") && i > clause.lowerBound
                        && ["a", "an", "one", "half", "quarter"].contains(t[i - 1])
                })
            }
            if let anchor, !spansOneNounPhrase(t, anchor + 1..<clause.upperBound, state: state) {
                return true
            }
        }
        let finiteVerb = clause.contains {
            auxiliaries.contains(t[$0]) && !modals.contains(t[$0])
        }
        guard finiteVerb || reportsRatherThanAsks(t, clause: clause, phraseStart: phraseStart,
                                                  state: state)
        else { return false }
        return !predicatesNothing(t, clause: clause, state: state)
    }

    // MARK: - Caps

    /// The whole cap decision, clause by clause.
    ///
    /// **The property the clause index buys, and the one that killed most of the
    /// defects: a cap sentence has its ceiling word, its door and its number in
    /// ONE clause.** Every rule below is that sentence, gated on that clause.
    /// No rule here asks HOW FAR APART two words are — the span-of-three, the
    /// span-of-two and the reach-of-two that preceded this were approximations
    /// of clause structure by counting, and counting is what failed three times.
    /// What is left is order (which word leads), adjacency (which word is the
    /// next one), and bounded scans between two positions the clause already
    /// gave. What each rule would get wrong without the gate is recorded on the
    /// rule.
    ///
    /// A clause may hold more than one predicate — a sentence-final abbreviation
    /// merges with what follows, so "down hours till 11 p.m. cap tiktok at 20"
    /// is one clause (NumberParser.swift, `split`) — so no rule here assumes one
    /// clause is one command. The gate is a NECESSARY condition, never a
    /// sufficient one; every rule still has to read the words it found.
    ///
    /// nil means "no clause is cap-shaped", and the ladder keeps going. Anything
    /// else TERMINATES, `.silence` included: a cap-shaped sentence this cannot
    /// resolve must never keep walking, because what it walks into is SPEND, and
    /// the answer to "cap tiktok and instagram at 20" is not twenty minutes of
    /// TikTok with the wall down.
    private static func capOutcome(_ index: NumberParser.ClauseIndex,
                                   state: PolicyState, text: String) -> ParseOutcome? {
        for clause in clauseRanges(index) {
            // AND THE CLAUSE MUST BE THE ONE THE SENTENCE IS ABOUT. This loop
            // walks EVERY clause and sits ahead of SPEND and of rule 5, and the
            // hoist that put it there was justified by one clause holding both a
            // cap word and a number — "cap tiktok at 20" granting. It does not
            // license a cap clause reaching across a boundary to veto a
            // DIFFERENT clause's intent: "give me 20 of tiktok, uncap instagram"
            // answered the second breath and dropped the first on the floor, and
            // "remove instagram, no cap on tiktok" cleared TikTok's ceiling and
            // never removed Instagram at all.
            //
            // Two clauses naming two different doors with two different intents
            // is the ambiguity `parse`'s `number` binding and `capOutcome`'s own
            // `.several` arm already refuse — for numbers and for doors inside
            // one clause respectively.
            // Applied across clauses, and only backwards: an EARLIER clause
            // states the sentence's first intent, and this rule may not
            // overrule it.
            if let outcome = capCleared(index, clause: clause, state: state),
               !anotherDoorIsClaimedEarlier(index, before: clause, state: state,
                                            door: capDoor(of: outcome)),
               // A pool command is a first breath too, and a trailing
               // LOOSENING may not overrule it — see
               // `aPoolCommandIsClaimedEarlier` for the scoping (FINDING 11).
               !(capDoor(of: outcome) != nil
                 && aPoolCommandIsClaimedEarlier(index, before: clause)) {
                return outcome
            }
            if let outcome = capSet(index, clause: clause, state: state, text: text),
               !anotherDoorIsClaimedEarlier(index, before: clause, state: state,
                                            door: capDoor(of: outcome)) {
                return outcome
            }
        }
        return nil
    }

    /// The door a cap outcome would move, or nil when the outcome moves none —
    /// which is the shape of every terminating refusal in this family.
    private static func capDoor(of outcome: ParseOutcome) -> Door? {
        guard case .command(.setDoorCap(let d, _)) = outcome else { return nil }
        return d
    }

    /// Whether an EARLIER clause names a door and states an intent of its own.
    ///
    /// An intent is a NUMBER — that clause names a door and a quantity, which is
    /// the shape SPEND would have answered — or the REMOVER that OPENS THAT
    /// CLAUSE, which is rule 5's own shape. Both are things this sentence said
    /// first, and a ceiling in a later breath does not get to speak for them.
    ///
    /// THE REMOVER ARM IS ANCHORED TO ITS CLAUSE, NOT TO THE UTTERANCE. It used
    /// to require `earlier.lowerBound == 0`, so one greeting ahead of the removal
    /// undid the whole guard: "hey, remove instagram, no cap on tiktok" cleared
    /// TikTok's ceiling and never removed Instagram, while the same sentence
    /// without the "hey," removed the door correctly. The number arm beside it
    /// never had a position lock, which is exactly why the sibling defect is
    /// robust and this one was not. A first breath is the first breath that says
    /// something, not the first token of the string.
    ///
    /// NOT SCOPED TO A DIFFERENT DOOR, which was the first cut and left the
    /// same defect behind a repeated name: "give me 20 of instagram, uncap
    /// instagram" names one door twice, and the clearing still swallowed the
    /// ask for twenty minutes. Whether the second breath happens to spell the
    /// same app is not what decides whether the first breath was heard.
    ///
    /// A cap outcome with no door — the `.silence` `capCleared` returns for two
    /// doors in one clause — is never suppressed: that silence is a refusal, and
    /// a refusal may not be talked out of terminating.
    private static func anotherDoorIsClaimedEarlier(_ index: NumberParser.ClauseIndex,
                                                    before clause: Range<Int>,
                                                    state: PolicyState,
                                                    door d: Door?) -> Bool {
        guard d != nil else { return false }
        let t = index.tokens
        for earlier in clauseRanges(index) where earlier.upperBound <= clause.lowerBound {
            guard doorIndex(in: earlier, of: index, state: state) != nil else { continue }
            if earlier.contains(where: { NumberParser.readsAsNumber(t[$0]) }) {
                return true
            }
            // A CLAUSE OPENER KEEPS ITS WORD, AND THE WORD IS NOT WHAT THE
            // BREATH SAYS. The anchor fix already ruled that "a first breath
            // is the first breath that says something, not the first token of
            // the string" — and then this arm tested the clause's first token
            // raw, so "ok so remove instagram, no cap on tiktok" resurrected
            // the exact defect the anchor closed for "hey, remove instagram…":
            // the "so" opener occupies the slot, the removal went unclaimed,
            // and the trailing loosening parked (FINDING 7). The opener is
            // stepped over exactly as `spendFragment` steps over the same
            // four words; at most one can lead a clause, because a second
            // would have opened a clause of its own.
            var lead = earlier.lowerBound
            if ["but", "so", "anyway", "though"].contains(t[lead]),
               lead + 1 < earlier.upperBound {
                lead += 1
            }
            if capRemovers.contains(t[lead]) {
                return true
            }
        }
        return false
    }

    /// Whether an EARLIER clause is a POOL COMMAND — the pool's own stem with
    /// a number in the same breath, which is rule 3's sentence said first.
    ///
    /// The guard above respects only earlier clauses that name a DOOR, so a
    /// leading pool command was invisible and a trailing LOOSENING overruled
    /// it: "set my budget to 40, no cap on tiktok" dropped the budget move and
    /// parked the clearing — inverting the guard's own first-intent doctrine
    /// (FINDING 11). The intent test is bare number-presence, mirroring the
    /// door arm's (whose recall seam is pinned as such); consulted only for
    /// CLEARINGS, because the loosening direction is the defect and the
    /// tightening flavor ("make my budget 60 a day, cap tiktok at 20") is
    /// pinned as an accepted recall seam — both outcomes there tighten.
    private static func aPoolCommandIsClaimedEarlier(_ index: NumberParser.ClauseIndex,
                                                     before clause: Range<Int>) -> Bool {
        let t = index.tokens
        for earlier in clauseRanges(index) where earlier.upperBound <= clause.lowerBound {
            guard earlier.contains(where: { t[$0].hasPrefix("budget") }) else { continue }
            if earlier.contains(where: { NumberParser.readsAsNumber(t[$0]) }) {
                return true
            }
        }
        return false
    }

    /// The clause ranges of an utterance, in order. `ClauseIndex` hands out one
    /// range at a time — deliberately, since a rule's question is always about a
    /// particular token — so a rule that wants to consider every clause walks
    /// them by jumping from one range's end to the next. No clause id is ever
    /// read or subtracted; "two clauses apart" is the counting mistake one level
    /// up, and the primitive withholds the number that would allow it.
    private static func clauseRanges(_ index: NumberParser.ClauseIndex) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < index.tokens.count, let r = index.clauseRange(containing: i) {
            ranges.append(r)
            i = r.upperBound
        }
        return ranges
    }

    /// 2.5 CAP CLEARED — "uncap tiktok", "no cap on tiktok", "remove the tiktok
    ///     cap", "take the cap off youtube", "i dont want a limit on instagram".
    ///
    ///     Claimed rather than left silent, which is the important part. SILENCE
    ///     IS NOT INERT: `AppModel.handle` hands a silent parse to the on-device
    ///     model, whose only "less access" verb is `closeDoor` and which has no
    ///     cap vocabulary at all — so "no cap on tiktok", a request to REMOVE a
    ///     restriction, is a plausible instant close. A loosening answered with
    ///     the strongest tightening in the product is the worst outcome
    ///     available, and it is what leaving these sentences unmatched buys.
    ///
    ///     WITHOUT THE CLAUSE GATE this rule reads a remover in one breath and a
    ///     ceiling in the next as one request. "drop tiktok, im at my limit" is a
    ///     door removal and came back a cap clearing; "i want 20 of tiktok, no
    ///     cap needed" is a spend and came back a cap clearing with the request
    ///     for twenty minutes dropped on the floor; "no tiktok, no limits"
    ///     refuses the app outright and came back having loosened it. All three
    ///     are two-clause sentences whose parts were glued together by a
    ///     tokenizer that could not see a comma.
    private static func capCleared(_ index: NumberParser.ClauseIndex, clause: Range<Int>,
                                   state: PolicyState) -> ParseOutcome? {
        guard let phrase = clearingPhrase(index, clause: clause, state: state) else { return nil }
        // A QUESTION IS NEVER A RULE CHANGE, and neither is a statement of fact.
        // See `reportsRatherThanAsks` for the eleven sentences that reached here
        // and left with the ceiling removed.
        guard !reportsRatherThanAsks(index.tokens, clause: clause,
                                     phraseStart: phrase.lowerBound,
                                     state: state) else { return nil }
        // AND NOTHING IS PREDICATED OF THE CEILING AFTERWARDS. "i dont want the
        // tiktok cap removed", "…gone", "…lifted", "…touched", "…raised",
        // "…any higher" all ask for the ceiling to STAY or to come DOWN, and
        // every one of them cleared it: the phrase ends at the noun, and the
        // word that says what she does not want done TO the noun trails it. A
        // ceiling's phrase may be followed by its own prepositional tail ("a cap
        // ON TIKTOK") and by nothing else.
        //
        // This is also what refuses a REMOVAL trailing the noun — "i dont want
        // the cap off tiktok" — so `clearingPhrase` needs no separate scan for
        // one. A remover after the head is a word after the phrase, and no
        // remover is a noun-phrase word, so the two tests are the same test.
        guard spansOneNounPhrase(index.tokens, phrase.upperBound + 1..<clause.upperBound,
                                 state: state) else {
            // AND THE REFUSAL TERMINATES WHEN THE CLAUSE IS ABOUT A DOOR.
            // This guard used to DECLINE unconditionally, and a decline walks
            // the ladder into SPEND: "uncap tiktok because 20 was too strict"
            // glues its reason's number and copula into the clause, the tail
            // fails, and a request to CLEAR a ceiling was answered with a
            // grant and a debited pool on the very app being loosened —
            // violating the family's own doctrine that a cap-shaped sentence
            // must never keep walking (FINDING 4). A clause holding a door
            // and a clearing phrase IS cap-shaped, so it terminates.
            //
            // Two carve-outs, each the shape a pinned sentence needs the nil
            // for: a DOORLESS clause is commentary riding beside somebody
            // else's ask ("give me 20 of tiktok, no cap needed" — the grant
            // must keep walking to clause one), and a stated NEW ceiling is
            // `capSet`'s sentence, one rule over in the same breath ("drop
            // the tiktok limit TO 20" declines here so the set can land).
            if case .none = doors(in: clause, of: index, state: state) { return nil }
            if statesANewCeiling(index, clause: clause) { return nil }
            return .silence
        }
        switch doors(in: clause, of: index, state: state) {
        case .none:
            return nil
        case .several:
            // Two doors and one clearing is the ambiguity `parse`'s `number`
            // binding has refused for numbers since the parser shipped — two
            // readings, no answer. Silence, never a
            // fall-through: "no limit on tiktok or instagram" must not remove
            // whichever ceiling was spelled first.
            return .silence
        case .one(let d):
            // A SENTENCE THAT REFUSES THE APP IS NOT ASKING TO UNCAP IT. "no
            // tiktok no limits" governs the door with its first negator; the
            // second one governs "limits" exactly as designed, and the rule
            // fired on a sentence whose subject is that she wants none of the
            // app. The comma'd spelling is two clauses and never reaches here;
            // one word should not be the difference.
            guard !negatorStandsOnTheDoor(index, clause: clause, state: state) else { return nil }
            // A stated new ceiling is a SET, and `capSet` below has it: "drop
            // the tiktok limit to 20" says what the new ceiling is. That used to
            // be a `statesANewCeiling` guard of its own and is now the number
            // test below, because the two agreed on every sentence in the corpus
            // and disagreed only on one: "take the cap OF 20 off tiktok" is the
            // single shape where a preposition aims at a number INSIDE the
            // clearing phrase, and there the number says WHICH ceiling to
            // remove, so the guard was refusing a clearing it should have made.
            // Two belts, one untested and one wrong where it was reachable.
            // Every number this clause carries must lie inside the clearing
            // phrase. A number inside identifies the ceiling being removed
            // ("remove the 20 minute tiktok cap"); a number outside belongs to
            // something else, which means the clause is doing two things and
            // this rule may not answer for both.
            //
            // AND THE REFUSAL TERMINATES, which is this family's own doctrine
            // ("a cap-shaped sentence this cannot resolve must never keep
            // walking, because what it walks into is SPEND") applied to the
            // one guard that was still declining. The subtractive lowering
            // puts its amount OUTSIDE the phrase — "take 20 off my tiktok
            // limit" finds off…limit and the 20 stands ahead of it — so the
            // decline walked the ladder into rule 7 and a request to LOWER a
            // restriction was answered by debiting 20 minutes and taking the
            // wall down on the app being restricted. "knock 10 off the tiktok
            // cap" and "shave 15 off my instagram limit" are the same shape.
            // The grammar cannot write the subtraction (it does not know the
            // old ceiling's number is not the sentence's); silence reaches the
            // widener, which per §5.7 can produce no cap and no grant out of
            // this either.
            guard everyNumberLiesInside(phrase, index, clause: clause) else { return .silence }
            return .command(.setDoorCap(door: d, minutes: nil))
        }
    }

    /// The span of the phrase that asks for a ceiling to go away, or nil when
    /// this clause is not asking. Runs from the word that removes to the ceiling
    /// it removes, in whichever order they were said, so `capCleared` can ask
    /// whether a number belongs to the request or to something else.
    ///
    /// A NEGATOR BEFORE A REMOVER CANCELS IT, and this is a property of the
    /// clause, not a pair to add to a list. "dont remove the tiktok cap", "never
    /// remove the tiktok cap", "dont take the cap off tiktok", "please dont drop
    /// the tiktok limit" and "dont lift the tiktok cap" all cleared the ceiling
    /// they were pleading for, because an earlier cut special-cased "dont" only
    /// as the pair "dont want" and then let the next remover fire alone. Every
    /// one of them is a LOOSENING produced by a sentence that says the opposite,
    /// and a loosening waits for tomorrow, so the mistake also outlives the
    /// conversation that made it.
    ///
    /// "dont want" survives as a remover — a negated volition IS a request for
    /// absence — but only while what it governs is the ceiling. Where a removal
    /// verb comes first the negation lands on the removal instead, so "i dont
    /// want to remove the tiktok cap" declines and "i dont want any cap on
    /// tiktok" clears. Which head follows the negator is the whole test.
    ///
    /// "off limits" is excluded as an ordered pair, and it is the reason this
    /// reads positions instead of intersecting two sets. "off" removes a ceiling
    /// and "limits" is one, but together they are English's flattest way of
    /// saying FORBIDDEN — so "tiktok is off limits", the strongest tightening
    /// sentence a person has words for, came back having removed the ceiling.
    private static func clearingPhrase(_ index: NumberParser.ClauseIndex, clause: Range<Int>,
                                       state: PolicyState) -> ClosedRange<Int>? {
        let t = index.tokens
        func head(after i: Int) -> Int? {
            (i + 1..<clause.upperBound).first {
                capRemovers.contains(t[$0]) || capNouns.contains(t[$0])
            }
        }
        var phrase: ClosedRange<Int>?
        var firstNegator: Int?

        for i in clause where negators.contains(t[i]) {
            if firstNegator == nil { firstNegator = i }
            guard let h = head(after: i) else { continue }
            // The negator's own object is a removal: what she is refusing is the
            // removing, and nothing in this clause clears anything.
            if capRemovers.contains(t[h]) { return nil }
            let governs: Bool
            if t[i] == "dont" || t[i] == "don't" || t[i] == "doesnt" || t[i] == "doesn't" {
                // A NEGATED VOLITION IS A REQUEST FOR ABSENCE — but only of what
                // the wanting takes as its object. "i dont want a cap on tiktok"
                // wants no ceiling; "i dont want to go over my tiktok limit",
                // "…to hit my tiktok limit", "…to blow past my instagram cap"
                // and "i dont want a bigger tiktok limit" all want the ceiling
                // KEPT, and every one of them removed it. The test is that
                // everything between "want" and the ceiling belongs to the
                // ceiling's own noun phrase: an infinitive "to", a verb, or a
                // comparative is a predicate of its own, and the negation landed
                // on that instead.
                governs = i + 1 < clause.upperBound && t[i + 1] == "want"
                    && spansOneNounPhrase(t, i + 2..<h, state: state)
            } else if nounNegators.contains(t[i]) {
                // A bare negator is a DETERMINER: it governs the noun phrase it
                // opens and nothing else. So it governs the ceiling word only
                // while the ceiling word is inside that phrase, and two things
                // say it is not — a SECOND DETERMINER, which opens a phrase of
                // its own, and a DOOR, which is a noun of its own.
                //
                // "no daily limit on tiktok" reaches its noun across an
                // adjective and clears. "do not take the cap off tiktok" is
                // pleading for the ceiling to stay, and its "the" says the "not"
                // landed on the verb; without that test the negator cancelled
                // the remover and then cleared the ceiling by itself — a
                // loosening out of a sentence begging for the opposite. "no
                // tiktok without a limit" is a demand FOR a ceiling, and the
                // door in between says which noun the "no" landed on.
                //
                // Structure, not a token count: an earlier cut asked for the
                // noun within two tokens, which is the same measurement that
                // failed three times and which reads "no daily limit" and "not
                // take the" as the same shape.
                //
                // The noun-phrase test rides alongside rather than replacing
                // those two: it is the same question asked of every OTHER word
                // in between, and a word that cannot stand inside a noun phrase
                // says the negator's phrase ended before the ceiling did.
                // AND THE NEGATOR'S PHRASE MUST BE WHAT THE CLAUSE IS SAYING,
                // not an emphatic trailing it. "No cap" is slang for "no lie",
                // and a full predicate ahead of it makes it the tail of a
                // chatter sentence, never a clearing request: "ngl tiktok
                // ruined my sleep no cap", "fr tiktok got me no cap", "me and
                // tiktok no cap" and "lowkey addicted to tiktok no cap" all
                // removed the very ceiling the user set on the app, because
                // the report gate only recognizes subjects from its pronoun
                // and auxiliary lists and Gen-Z filler openers are on neither.
                // The deliberate clearings keep their shapes: "no cap on
                // tiktok" leads its clause, "tiktok no cap" has only the door
                // ahead, and "uncap tiktok no cap" has a remover — so the
                // words before the negator must all be ones a clearing's own
                // span can hold (the noun-phrase whitelist plus the removers),
                // and a word that cannot ("ruined", "got", "addicted") says
                // the clause already said something else.
                // A slang particle AHEAD of the negator is emphatic evidence
                // in its own right — its noun-phrase seat exists for the tail
                // of a real clearing, not for its opening (FINDING 9; see
                // `slangEmphatics`).
                let emphatic = (clause.lowerBound..<i).contains { j in
                    slangEmphatics.contains(t[j])
                        || (!isNounPhraseWord(t, j, state: state)
                            && !capRemovers.contains(t[j]))
                }
                governs = !emphatic && !(i + 1..<h).contains { j in
                    determiners.contains(t[j])
                        || door(t[j], in: state) != nil
                        || (j + 1 < clause.upperBound && door(t[j] + " " + t[j + 1], in: state) != nil)
                } && spansOneNounPhrase(t, i + 1..<h, state: state)
            } else {
                governs = false
            }
            if governs, phrase == nil { phrase = i...h }
        }

        for i in clause where capRemovers.contains(t[i]) {
            // A remover under a negator has already been refused above; a
            // remover anywhere after one is refused here, and the cost of being
            // wrong is silence, which is the direction this rule must fail in.
            if let n = firstNegator, i > n { continue }
            if t[i] == "uncap" || t[i] == "uncapped" {
                if phrase == nil { phrase = i...i }
                continue
            }
            // The one pair whose halves reverse each other.
            if t[i] == "off", i + 1 < clause.upperBound, capNouns.contains(t[i + 1]) { continue }
            guard let noun = clause.first(where: { capNouns.contains(t[$0]) }) else { continue }
            // AND THE CEILING MUST BE WHAT THE REMOVER IS MOVING. This arm asked
            // only whether a cap noun existed ANYWHERE in the clause, so "off"
            // plus a "limit" in a different predicate read as one noun phrase:
            // "turn off tiktok im at my limit", "keep tiktok off until i hit my
            // limit", "cut tiktok off im at my cap" and nine more ask for the
            // APP to be shut and name the ceiling as the REASON — and every one
            // of them removed the ceiling instead, a parked loosening out of the
            // tightest thing the user could have said. The comma'd spelling of
            // each already declined, and one comma may not be the difference
            // between closing a door and loosening it.
            //
            // The test is the words in between: "remove [the tiktok cap]" is one
            // phrase, and "off tiktok — im at my limit" is not, because "im",
            // "ive", "its" and "until" cannot stand inside a noun phrase.
            // `nounPhraseStart` already walks the noun-before-remover direction;
            // this is the direction that had no test at all.
            guard spansOneNounPhrase(t, min(i, noun) + 1..<max(i, noun), state: state)
            else { continue }
            if phrase == nil {
                phrase = nounPhraseStart(t, clause: clause, noun: noun, remover: i)...max(i, noun)
            }
        }
        return phrase
    }

    /// Where the ceiling's own noun phrase starts, when the remover TRAILS it —
    /// "take [the 20 minute cap] off tiktok". The number in that shape is a
    /// premodifier naming which ceiling, and a phrase that began at the noun
    /// would leave it outside and decline a real clearing.
    ///
    /// A noun phrase starts at its determiner, so this walks back to one rather
    /// than counting tokens: an earlier cut reached back a fixed two, which is
    /// the same measurement this file is rebuilding to avoid. The walk stops at
    /// an ask verb or another remover, because neither can stand inside the noun
    /// phrase, and it never leaves the clause.
    private static func nounPhraseStart(_ t: [String], clause: Range<Int>,
                                        noun: Int, remover: Int) -> Int {
        guard noun < remover else { return min(noun, remover) }
        var j = noun
        while j > clause.lowerBound {
            j -= 1
            if determiners.contains(t[j]) { return j }
            if capRemovers.contains(t[j]) || askVerbs.contains(t[j]) { return j + 1 }
        }
        return clause.lowerBound
    }

    /// Whether a bare negator stands directly ON the door — "no tiktok", "not
    /// tiktok". Adjacency, which is the shape of a determiner on its noun, and
    /// not a window: a negator two or three words off is governing something
    /// else.
    private static func negatorStandsOnTheDoor(_ index: NumberParser.ClauseIndex,
                                               clause: Range<Int>, state: PolicyState) -> Bool {
        guard let d = doorIndex(in: clause, of: index, state: state), d > clause.lowerBound
        else { return false }
        return nounNegators.contains(index.tokens[d - 1])
    }

    /// Whether a number in this clause is the TARGET of a ceiling preposition —
    /// "cap tiktok AT 20", "drop the tiktok limit TO 20", "a limit OF 20". The
    /// preposition is what makes a number a new ceiling; a number merely present
    /// is a premodifier, a reason, a count or a date.
    private static func statesANewCeiling(_ index: NumberParser.ClauseIndex,
                                          clause: Range<Int>) -> Bool {
        let t = index.tokens
        return clause.contains { i in
            i > clause.lowerBound && ceilingPrepositions.contains(t[i - 1])
                && NumberParser.readsAsNumber(t[i])
        }
    }

    /// The same question asked of whichever clause names the door — rule 5's
    /// second guard, and the one that is load-bearing: "drop tiktok to 20" is
    /// somebody lowering a ceiling with the noun elided, and no cap rule above
    /// can read it, so without this the sentence deleted the door.
    ///
    /// What makes it a ceiling is the PREPOSITION aimed at the number, and
    /// nothing else. Written as "a number anywhere in the sentence" the guard
    /// declined on any digit at all, and "drop instagram for good, ive wasted 3
    /// hours today", "remove youtube, i have 2 too many" and "remove instagram
    /// after 5 years" fell through to SPEND and GRANTED the doors the user asked
    /// to delete. Scoped to the door's clause for the same reason the cap-noun
    /// guard is — a number in a second breath is a reason, not a target — which
    /// costs nothing and makes the two guards read the same way.
    ///
    /// AND TO THE DOOR BEING REMOVED. Both guards walked every clause for one
    /// naming ANY door, so a ceiling stated about a SECOND app refused the
    /// removal of the first: "remove reddit, tiktok is my limit" is an
    /// unambiguous door removal with a reason attached, and it compiled to
    /// nothing. The guard's own comment claimed it was the door's clause; it was
    /// any door's clause. Rule 5 knows which door it matched, so it says so.
    private static func doorsClauseStatesANewCeiling(_ index: NumberParser.ClauseIndex,
                                                     state: PolicyState, door d: Door) -> Bool {
        clauseRanges(index).contains { clause in
            clauseNames(d, in: clause, of: index, state: state)
                && statesANewCeiling(index, clause: clause)
        }
    }

    /// Whether this clause names THIS door, matched exactly as every other door
    /// recognizer here matches, so they cannot disagree. A clause naming two
    /// doors names both: the question is about one of them, not about how many.
    private static func clauseNames(_ d: Door, in clause: Range<Int>,
                                    of index: NumberParser.ClauseIndex,
                                    state: PolicyState) -> Bool {
        let t = index.tokens
        return clause.contains {
            doorAt(t, $0, within: clause.upperBound, state: state)?.door.id == d.id
        }
    }

    /// Whether every number this clause carries lies inside the clearing phrase.
    private static func everyNumberLiesInside(_ phrase: ClosedRange<Int>,
                                              _ index: NumberParser.ClauseIndex,
                                              clause: Range<Int>) -> Bool {
        let t = index.tokens
        return !clause.contains { i in
            !phrase.contains(i) && NumberParser.readsAsNumber(t[i])
        }
    }

    /// 4.5 CAP SET — "cap tiktok at 20", "limit tiktok to 20", "tiktok max 20",
    ///     "20 minute limit on tiktok", "at most 20 of tiktok", "keep tiktok
    ///     under 20" — and the habitual sentences that name no ceiling word at
    ///     all: "tiktok 20 a day", "make my instagram 15 min a day", "an hour a
    ///     day of tiktok".
    ///
    ///     Every one of the first group compiled to a GRANT before this rule
    ///     existed: rule 7 fires on a door plus one number, so a sentence asking
    ///     to TIGHTEN a door spent the shared budget and unshielded the app,
    ///     with no recovery — the parse is non-silent, so the widener never
    ///     runs. Dormant only because nobody says "cap tiktok" to a Silk with no
    ///     caps; this feature manufactures the utterance and Settings prints the
    ///     word on a row.
    ///
    ///     WITHOUT THE CLAUSE GATE the two shapes read across a boundary in both
    ///     directions. "tiktok is capped, give me 20 minutes" took its ceiling
    ///     word and door from one breath and its number from the next, and
    ///     answered a spend with a cap. "make it 30 a day, instagram is killing
    ///     me" is a budget move whose door is commentary in a second clause, and
    ///     the habitual shape read it as an instant per-door tighten under a
    ///     reply saying the pool was unchanged — it collided EXACTLY with the
    ///     widest real cap sentence when measured by distance, three tokens
    ///     each, which is how the measurement was proved unfixable.
    private static func capSet(_ index: NumberParser.ClauseIndex, clause: Range<Int>,
                               state: PolicyState, text: String) -> ParseOutcome? {
        let t = index.tokens
        // WHERE THE DOOR'S NAME BEGINS AND WHERE IT ENDS, from ONE match. The
        // scans below must know which tokens ARE the door, because the door's
        // own name is never evidence about the words around it — a determiner
        // inside a matched two-token name is part of the name, not a determiner
        // opening a fresh phrase. Asking `doorIndex` for the start and then
        // asking `door(_:in:)` again for whether the match had been a bigram
        // made two answers out of one question, and the second one could only
        // ever be a re-derivation of the first.
        var span: (start: Int, end: Int)?
        for i in clause {
            if let m = doorAt(t, i, within: clause.upperBound, state: state) {
                span = (i, m.end)
                break
            }
        }
        guard let span else { return nil }
        let doorStart = span.start
        let doorEnd = span.end

        // The clause reads its OWN numbers. Asking the whole utterance would put
        // "im at 9. cap tiktok at 20" — two numbers, two breaths — beyond every
        // rule here, and would hand a clause its neighbour's quantity.
        let numbers = NumberParser.allNumbers(in: t[clause].joined(separator: " "))
        // Where the number STANDS, when it stands anywhere: a number the reader
        // only finds through an idiom ("an hour a day") occupies no token, so
        // the tests below fall back to the door. Guessing a position for it
        // would be guessing.
        let numberAt = clause.first { NumberParser.readsAsNumber(t[$0]) }
        let lexeme = capLexemeIndex(t, in: clause)

        // Shape one: the clause states a ceiling word, and that word LEADS what
        // it bounds.
        //
        // POSITION is what separates a ceiling from a hedge, not politeness.
        // Every cap phrasing states the ceiling word first — before the number
        // ("cap tiktok at 20") or, when the number opens the sentence, before
        // the door it governs ("20 minute limit ON tiktok"). Every hedged spend
        // states it last: "20 minutes of tiktok max", "i need 20 minutes of
        // tiktok max" and "tiktok for 20 minutes max" are the hot path with a
        // qualifier trailing the ask, and reading them as rules gave the user a
        // permanent daily ceiling and no open app. A list of opening frames
        // could tell them apart in neither direction: "i need" was never on it
        // and "can i" was, so a hedge became a rule and "can i cap tiktok at 20"
        // became a grant — the very defect this rule exists to kill.
        var shaped = false
        // Leading the NUMBER is the ordinary shape; leading the DOOR is the
        // shape a number that opens the sentence forces ("20 minute limit ON
        // tiktok"). With no number in the clause at all — an idiom's quantity
        // occupies no token — the door is what is left to lead.
        let leadsTheNumber = lexeme.flatMap { l in numberAt.map { l < $0 } } ?? false
        // The door-leading disjunct is for cap NOUNS ONLY, and both halves of
        // that are paid for.
        //
        // A QUANTIFIER cannot lead by standing before the door when the number
        // already stood before IT: "20 minutes max on tiktok" and "20 minutes of
        // tiktok max" are the same sentence with the hedge in a different place,
        // and the first compiled to a permanent ceiling with no grant and no
        // open app — against a capped door, to a parked RAISE, so the hot-path
        // ask returned nothing at all. A cap noun still leads a door it precedes,
        // which is what "20 minute limit ON tiktok" is.
        //
        // AND THE CLAUSE MUST CARRY A NUMBER. Without this, any clause where a
        // ceiling word merely preceded a door name was declared shaped, failed
        // `numbers.count == 1` with zero of them, and returned the TERMINATING
        // `.silence` — so "im at my limit on tiktok, give me 20 minutes" and 158
        // sentences like it lost the grant that is README rule 1, and "i want a
        // limit on tiktok" lost the written-out sentence rule 8 exists to give. A
        // clause that states no number has PROPOSED nothing. The idiom case is
        // why the test is on `numbers` and not on `numberAt`: "cap tiktok at an
        // hour" has a quantity and no token holding it.
        let leadsTheDoor = lexeme.map { l in
            l < doorStart && !numbers.isEmpty && capNouns.contains(t[l])
        } ?? false
        if let lexeme, leadsTheNumber || leadsTheDoor {
            // A REMOVER STANDING BETWEEN THE CEILING WORD AND ITS DOOR MARKS
            // THE CLEARING FAMILY'S SENTENCE, AND THIS SHAPE MAY NOT RE-CLAIM
            // IT AS A PROPOSAL. "can you take the 20 minute cap off tiktok"
            // is a polite clearing, declined by `reportsRatherThanAsks` as
            // its own comment discloses (a fronted request modal reads as a
            // plain auxiliary — no exemption on the clearing side) — and then
            // THIS shape read the clearing's quoted premodifier as a set:
            // "cap" leads "tiktok" with the 20 ahead, and the fronted modal
            // bought `reportsRatherThanSets`' exemption, so the sentence
            // WROTE the very ceiling it asked to remove (ROUND 3, n11). The
            // "off" between the noun and the door says the ceiling is being
            // moved OFF the door, not aimed at it. Terminating silence, not
            // a decline: the bare spelling is claimed by `capCleared` before
            // this rule ever runs, so the only sentences that reach this
            // test are the clearing family's own declined moods — and a
            // decline here walks into SPEND.
            if lexeme < doorStart,
               (lexeme + 1..<doorStart).contains(where: { capRemovers.contains(t[$0]) }) {
                return .silence
            }
            // AND NOTHING STARTS A NEW PREDICATE BETWEEN THEM. Leading is not
            // government: "ive hit my limit give me 20 of tiktok" opens with a
            // ceiling word that governs nothing — it is commentary about why she
            // is asking — and it leads the number, so the hot path compiled to a
            // permanent ceiling and the app never opened. The comma'd spelling
            // is two clauses and the gate has it; this is the same sentence
            // typed without the comma, where the word standing between the
            // ceiling word and its number is what says the two belong to
            // different predicates.
            //
            // An ask verb was the only one tested, which reads that sentence and
            // not its mirror: "give me 20 minutes im at my limit on tiktok"
            // puts the ask FIRST, so the ask verb is outside the span and the
            // trailing commentary took the sentence — a lost grant, and against
            // a capped door a parked raise. A SUBJECT and a DETERMINER say the
            // same thing an ask verb says: "im", "theres" and "the" each open a
            // predicate or a phrase of their own, and a ceiling word cannot
            // reach across one to the number it bounds. All three are closed
            // classes, and all three are the same question — is there a
            // boundary in here — rather than three separate exceptions.
            //
            // A bounded scan between two positions the clause already gave, not
            // a threshold: the range is whatever the sentence put between them.
            // Well-formed by the condition above — entering here requires the
            // ceiling word to lead one of the two, so the pair never coincides,
            // which matters because a user may name a door "Max" or "Limit" and
            // an inverted range traps.
            let reach = numberAt ?? doorStart
            let intervenes = (min(lexeme, reach) + 1..<max(lexeme, reach)).contains { i in
                // THE DOOR'S OWN NOUN PHRASE IS NOT A BOUNDARY. The scan asks
                // whether a fresh predicate or phrase stands between the
                // ceiling word and what it bounds — and the door standing
                // there is the setter's own OBJECT, not an interruption. Two
                // holes, one cause: "cap my tiktok at 20" hangs a possessive
                // directly on the door's name, and a two-token door name would
                // carry its own determiner INSIDE the tokens the door matched
                // by. Both counted as boundaries, the shape died, and the
                // ladder answered a restriction by taking the wall down
                // (FINDINGS 1-2). Only the possessive half is live today — no
                // catalogue name is two tokens, the invariant `doorAt` writes
                // down — and the second half is the reason the span is read
                // from the match rather than assumed to be one token. The
                // door's matched tokens are skipped, and
                // so is a determiner standing IMMEDIATELY on the door's first
                // token — that determiner opens the door's phrase, which is
                // the phrase being capped. A determiner anywhere else keeps
                // its boundary reading, so "make the tiktok limit 20" (the
                // determiner ahead of the LEXEME) and the commentary shapes
                // ("ive hit my limit give me 20 of tiktok", where an ask verb
                // intervenes) are exactly as they were.
                if (doorStart...doorEnd).contains(i) { return false }
                if determiners.contains(t[i]), i + 1 == doorStart { return false }
                // AND NEITHER IS THE NUMBER'S OWN PHRASE. "cap tiktok at A
                // strict 20" and "cap tiktok at AN even 20" hang a determiner
                // (and at most one adjective) on the NUMBER the lexeme aims
                // at — the same proposal "cap tiktok at 20" states with the
                // phrase spelled out — and the boundary reading killed the
                // shape, so `capSet` returned nil instead of terminating and
                // rule 7 answered a restriction with a GRANT (ROUND 3, n6).
                // A determiner within two tokens of the number opens the
                // number's phrase; two and no more, so "the tiktok cap my
                // mom set is 20" keeps its boundary and the mood gates keep
                // reading it.
                if determiners.contains(t[i]), let numberAt,
                   i + 1 == numberAt || i + 2 == numberAt { return false }
                return askVerbs.contains(t[i]) || subjects.contains(t[i])
                    || determiners.contains(t[i])
            }
            // A BARE QUANTIFIER inside a request to be let in is a quantifier on
            // the ask, not a rule about tomorrow: "give me under 20 of tiktok"
            // is a spend. A cap NOUN outranks the frame, the same way "stop
            // letting" outranks the opener veto in `hasClosingVerb` — "cap" is
            // the sentence's own noun and no politeness around it makes it an
            // ask. With a period word the sentence is habitual and the
            // quantifier bounds the habit, so the veto lifts: "give me 60 a day
            // max on tiktok" states a daily maximum.
            //
            // The frame is read as TOKENS IN THIS CLAUSE, which is the whole
            // repair. `hasOpeningVerb` answers for the whole utterance and
            // cannot say where its verb stands, and the comment eight lines above says a frame list
            // "could tell them apart in neither direction: 'i need' was never on
            // it" — and then the code used one, so "i need under 20 of tiktok"
            // and "gimme under 20 of tiktok" compiled to ceilings while "give me
            // under 20 of tiktok" spent. Reading the whole text was the second
            // bug in the same line: a "give me" in a DIFFERENT clause vetoed the
            // rule, so "tiktok max 20, give me instagram" granted twenty minutes
            // of the door it was asked to cap. `askVerbs` is the same lexicon
            // this file already owns, as tokens, which is what can say where a
            // verb stands.
            let hedged = isQuantifier(t, at: lexeme)
                && clause.contains { askVerbs.contains(t[$0]) }
                && !periodPhrase(t, in: clause)
            // A CLAUSE LED BY A REMOVER HAS STATED A REMOVAL, NOT A CEILING.
            // "drop instagram ive hit my limit 20 times" opens with rule 5's own
            // verb, names the door it wants deleted, and then says how many
            // times she hit the ceiling — and the count became the ceiling, on
            // the door she asked to delete, which against a capped Instagram is
            // a parked RAISE. The comma'd spelling removes the door. What says
            // the ceiling is not what "drop" is moving is the same question
            // `clearingPhrase` asks of its own remover: the words in between —
            // "ive" cannot stand inside a noun phrase, so "my limit" is a second
            // predicate and not the opener's object.
            let led = clause.lowerBound
            let removerLeads = capRemovers.contains(t[led])
                && !spansOneNounPhrase(t, min(led, lexeme) + 1..<max(led, lexeme), state: state)
            if !intervenes && !hedged && !removerLeads {
                shaped = true
            }
        }
        // A CAP NOUN COMMANDING A DOOR WITH NO NUMBER OF ITS OWN IS A CEILING
        // THIS GRAMMAR CANNOT RESOLVE, and the answer is the terminating
        // silence, not a decline. "put a limit on instagram, 25 max" and "cap
        // tiktok. at 20" split the proposal across a boundary, so the clause
        // that names the ceiling and the door fails the number test above —
        // and a decline walks the ladder into SPEND, which answers a request
        // to RESTRICT the app by debiting the pool and taking the wall down
        // with the OTHER breath's number. The refusal is scoped to the mood
        // the setter itself requires: a report ("im at my limit on tiktok,
        // give me 20 minutes") and a volition ("i want a limit on tiktok")
        // are commentary and rule 8's own sentence, and both keep walking.
        // A NEGATOR AHEAD OF THE NOUN hands the clause to the clearing family
        // instead — "remove instagram, no cap on tiktok" already had its
        // clearing suppressed by the earlier removal, and this arm may not
        // overrule the same first breath from one rule over.
        if let lexeme, capNouns.contains(t[lexeme]), lexeme < doorStart, numbers.isEmpty,
           !(clause.lowerBound..<lexeme).contains(where: { negators.contains(t[$0]) }),
           !statesAVolition(t, clause: clause) {
            // A POLITE QUESTION IS STILL A CAP PROPOSAL, and it terminates
            // like one WHEN A NUMBER STANDS IN ANOTHER BREATH.
            // `reportsRatherThanAsks` reads a request modal as a plain
            // auxiliary — no `requestModals` exemption, unlike
            // `reportsRatherThanSets` — so "can you cap tiktok? 20 minutes"
            // had its question clause refused as a report, this arm declined
            // instead of terminating, and the bare "20 minutes" in the next
            // breath was a perfect spendFragment: a request to RESTRICT the
            // app funded a grant on it (FINDING 5). The exemption is the
            // setter gate's own, wh-guard included, scoped to this arm so the
            // clearing family's question refusals ("should i uncap tiktok")
            // stay refusals — and scoped to the utterances whose decline the
            // ladder would actually spend, because a NUMBERLESS polite ask is
            // rule 8's own sentence: "can i get a cap on tiktok" is pinned as
            // the cap ask missing one word, answered with that word, and
            // nothing below rule 8 can grant with no number anywhere.
            let ahead = clause.lowerBound..<lexeme
            let politeAsk = !ahead.contains(where: { whWords.contains(t[$0]) })
                && ahead.contains(where: { requestModals.contains(t[$0]) })
                && t.indices.contains { i in
                    !clause.contains(i) && NumberParser.readsAsNumber(t[i])
                }
            if politeAsk
                || !reportsRatherThanAsks(t, clause: clause, phraseStart: lexeme,
                                          state: state) {
                return .silence
            }
        }
        // A QUANTIFIER STRANDED FROM ITS NUMBER IS THE SAME UNRESOLVABLE
        // PROPOSAL. The arm above covers cap NOUNS only, so "keep tiktok
        // under, say, 20" — dictation commas stranding the quantifier from
        // its number — fell through, and the doorless "20" clause funded a
        // grant on the app being restricted (FINDING 6). A door with a bare
        // trailing quantifier and no number has proposed a ceiling this
        // grammar cannot resolve. STRANDED means the boundary cut the number
        // off: the quantifier is its clause's LAST word, so "keep tiktok
        // under control, give me 20 of tiktok" — where "under" bounds a noun
        // of its own — keeps its grant; the ask-verb exemption keeps the hedged
        // elliptical asks walking ("give me tiktok max" still reaches rule
        // 8's written-out sentence); and the mood exemptions are the noun arm's own.
        if let lexeme, capQuantifiers.contains(t[lexeme]), lexeme > doorEnd, numbers.isEmpty,
           lexeme == clause.upperBound - 1,
           !clause.contains(where: { askVerbs.contains(t[$0]) }),
           !(clause.lowerBound..<lexeme).contains(where: { negators.contains(t[$0]) }),
           !statesAVolition(t, clause: clause),
           !reportsRatherThanAsks(t, clause: clause, phraseStart: lexeme, state: state) {
            return .silence
        }

        // Shape two: the habitual sentence, which names a period and a door and
        // needs no ceiling word — "tiktok 20 a day". Naming the POOL takes it
        // back, however close the door stands: "budget of 40 for instagram" is
        // 40 minutes of budget.
        //
        // AND THE DOOR MUST BE A TOPIC RATHER THAN A SUBJECT. This shape names
        // no ceiling word at all, so the only thing making it a rule is the bare
        // apposition of a door and a daily quantity — "tiktok 20 a day". Let the
        // door take a predicate of its own and the same tokens are a REPORT
        // about what the app does: "tiktok takes 30 minutes a day" and "30
        // minutes a day on tiktok is too much" both wrote the very number they
        // complain about as a ceiling, and the second says in words that thirty
        // is the wrong one. The test is the word standing directly after the
        // door, asked with the noun-phrase whitelist every other rule here uses,
        // so an unrecognised word declines.
        if periodPhrase(t, in: clause), numbers.count == 1, !t.contains("budget"),
           doorIsATopic(t, clause: clause, doorStart: doorStart, state: state) {
            // A PARTICIPLE HEADING THE CLAUSE IS A HABIT REPORT WITH ITS
            // SUBJECT ELIDED, NOT A RULE. `doorIsATopic` answers yes
            // unconditionally when the door does not lead, and the mood gate
            // below only sees subjects from the pronoun lists — so "checking
            // tiktok 50 times a day" and "scrolling tiktok 45 minutes a day
            // lately" compiled the complaint's own number as standing policy,
            // where "she checks instagram 40 times a day" was rightly silent:
            // one elided "i was" was the whole difference. English heads an
            // imperative with a BASE verb ("make my instagram 15 min a day");
            // a gerund or past participle heads a description. Terminating
            // silence, not a decline, for the family's usual reason — a
            // decline walks onward, and the sentence still names a door and a
            // number.
            if doorStart != clause.lowerBound,
               isHabitParticiple(t[clause.lowerBound])
                || phrasePrepositions.contains(t[clause.lowerBound]) {
                // A phrase preposition heads the same report — "ON tiktok 90
                // minutes a day lately" — never a command; every pinned
                // habitual setter leads with its door, its number, its
                // determiner or a base verb.
                return .silence
            }
            shaped = true
        }
        // THE DATIVE SETTER HANDS THE CEILING TO THE DOOR, NOT TO THE USER.
        // "give tiktok a 20 minute ceiling" trails its cap noun behind both
        // the number and the door, so neither shape above can read it — and
        // the decline walked into rule 7, which read "give" + door + number
        // as the hot path and GRANTED the very restriction being asked for
        // (FINDING 3). The distinguishing structure is the dative: the ask
        // verb's recipient is the DOOR ITSELF ("give THE DOOR …", never
        // "give ME"), with a cap noun in the recipient's wake. Terminating
        // silence — the grammar cannot resolve which shape this proposal is,
        // and a grant is the one wrong answer. The volitional asks keep rule
        // 8's written-out sentence ("i want tiktok capped" is the command that speaks
        // its subject).
        //
        // A BOUNDARY SCAN BETWEEN THE DOOR AND THE CAP NOUN, NOT THE
        // NOUN-PHRASE WHITELIST. The first cut asked `spansOneNounPhrase`,
        // and one sincere adjective broke it: "give tiktok a HARD 20 minute
        // cap" is not whitelist vocabulary, so the arm declined, and the
        // decline walked into rule 7's give-door-number hot path — a request
        // to RESTRICT the app funded twenty minutes of it (ROUND 3, n4).
        // The whitelist doctrine's direction-of-failure argument INVERTS
        // here: in the clearing rules an unrecognised word must decline
        // because a clearing is a loosening, but this arm's decline lands on
        // SPEND, so an unrecognised word must TERMINATE. What keeps the
        // decline is a real second predicate between the recipient and the
        // cap noun — a subject or a fresh ask verb, the same closed-class
        // boundary question shape one's `intervenes` scan asks — because
        // then the cap noun is not aimed at the door at all: "give tiktok 20
        // so I dont blow my limit" spends, and "my limit" belongs to the "i".
        // Determiners are NOT boundaries here: they open the ceiling's own
        // phrase ("give tiktok A hard cap"), the recipient's mirror of the
        // FINDINGS 1-2 skip.
        //
        // AND "THAT" BETWEEN THE RECIPIENT AND THE CAP NOUN IS A DETERMINER.
        // `subjects` holds the demonstratives for the report gates, so the
        // boundary scan read "give tiktok THAT 20 minute cap we talked
        // about" as a second predicate, withheld the termination, and the
        // decline walked into rule 7's give-door-number hot path — the
        // FINDING 3 inversion, resurrected through the third demonstrative
        // (ROUND 3, n5). Between a recipient door and its trailing cap noun
        // a demonstrative opens the ceiling's own phrase exactly as "a"
        // does, and `determiners` already says so; a subject that is no
        // determiner ("i", "you", "we") keeps its boundary reading.
        //
        // THE RECIPIENT FRAME IS NOT ASK-VERB-KEYED. "set tiktok to a 20
        // minute cap" is the same proposal one verb over — the cap noun
        // trails number and door alike, so neither lead test can see it, and
        // the askVerbs key let the clause walk to rule 7 and SPEND (ROUND 3,
        // n7). A clause-LEADING verb this grammar does not know, with the
        // door standing directly on it as its object, is the same frame; the
        // closed classes are what the lead must NOT be — a determiner, a
        // subject, an auxiliary, a wh-word, a negator, a remover, the phrase
        // vocabulary — because each of those heads a report or a family with
        // rules of its own ("the tiktok cap should be 15 a day" keeps its
        // subject-is-the-rule set, the questions keep their gates, and a
        // remover-led clause is `capCleared`'s to decline).
        //
        // AND THE DOOR MAY WEAR ITS OWN DETERMINER. "give THE tiktok a 20
        // minute ceiling", "give MY tiktok a 20 minute limit" are the same
        // dative with an article on the recipient, and the frame read only
        // the bare "give tiktok …" — so the determiner form walked past the
        // termination into rule 7 and was GRANTED the twenty minutes it asked
        // to be held to. The rows that should have caught it spelled the
        // door "the gram", which named no door, and passed on the lookup.
        let lead = clause.lowerBound
        let recipientOnTheVerb = doorStart == lead + 1
            || (doorStart == lead + 2 && determiners.contains(t[lead + 1]))
        let leadingVerbTakesTheDoor = recipientOnTheVerb
            && !determiners.contains(t[lead]) && !subjects.contains(t[lead])
            && !auxiliaries.contains(t[lead]) && !whWords.contains(t[lead])
            && !negators.contains(t[lead]) && !capRemovers.contains(t[lead])
            && !isNounPhraseWord(t, lead, state: state)
        // AND A CAP NOUN STANDING DIRECTLY ON THE DOOR, IN A CLAUSE THAT
        // STATES NO QUANTITY, IS A MENTION — WHEN ANOTHER CLAUSE ASKS IN
        // FULL. "forget THE TIKTOK CAP, give me 20 minutes", "give me 20 of
        // instagram, ignore the tiktok cap": "tiktok cap" is one compound
        // noun, the door's cap referred to, and the determiner widening
        // above made that spelling reach this arm, whose terminating silence
        // threw away a whole grant standing in the next clause. Three
        // conditions, each one a sentence that was granted without it:
        // the noun must stand ON the door, because the setter opens the
        // ceiling's own phrase between them ("give tiktok A hard cap");
        // the clause must carry no quantity at all — `numbers`, the
        // idiom-aware count, not a token scan, because "give the tiktok cap
        // AN HOUR" holds sixty with no token reading as a number and was
        // funded an hour of the app it asked to cap; and some OTHER clause
        // must carry an opening verb, because the grant this exception
        // keeps must be a whole ask, not the bare "20 minutes" after "set
        // the tiktok cap," which the fragment rule would otherwise write out
        // as an unlock of the door just asked to be held. When all three
        // hold the mention is left to the clause that asks; the cap it
        // names is not loosened by that, since a standing ceiling clamps
        // every grant on its door (`Validator`), so "raise the tiktok cap,
        // give me 20 minutes" spends twenty of whatever the ceiling leaves.
        let capNounSitsOnTheDoor = lexeme == doorEnd + 1
        let anotherClauseAsks = clauseRanges(index)
            .contains { $0 != clause && hasOpeningVerb(Array(t[$0])) }
        let aMentionOfTheCap = capNounSitsOnTheDoor && numbers.isEmpty && anotherClauseAsks
        if !shaped, let lexeme, capNouns.contains(t[lexeme]), lexeme > doorEnd,
           !aMentionOfTheCap,
           doorStart > clause.lowerBound,
           askVerbs.contains(t[doorStart - 1]) || leadingVerbTakesTheDoor,
           !statesAVolition(t, clause: clause),
           !(doorEnd + 1..<lexeme).contains(where: {
               askVerbs.contains(t[$0])
                   || (subjects.contains(t[$0]) && !determiners.contains(t[$0]))
           }) {
            return .silence
        }
        guard shaped else { return nil }

        // A NEGATOR REFUSING THE CEILING WRITES NO CEILING. `negators` was read
        // by the clearing rule and by nothing else, so "dont cap tiktok at 20",
        // "never limit tiktok to 20" and "i dont want tiktok capped at 20" wrote
        // the ceiling the sentence refuses — against a capped door a parked
        // RAISE, which is the forbidden direction, and against an uncapped one
        // an instant tighten out of a refusal. Symmetry with the clearing rule
        // is the point: a negator is a property of the clause that reverses one,
        // whichever rule it lands in.
        //
        // BELOW THE SHAPE TESTS, which is the repair. The scan used to sit
        // inside shape one's `if let lexeme` arm, so the habitual shape — which
        // by construction has no ceiling word — could never reach it: "dont give
        // me 30 a day on tiktok", "i cant do 30 minutes a day on tiktok" and
        // sixteen more wrote a ceiling out of a refusal, while the identical
        // sentence WITH a cap noun ("dont cap tiktok at 30 a day") was correctly
        // silent. Whether a ceiling word happens to be spelled is not what
        // decides whether a sentence is negated.
        //
        // The scan runs to whichever of the three the clause led with, so it
        // reads the words that stand before the proposal and no others: a
        // negator after it belongs to something else.
        //
        // "no more than 20 of tiktok a day" is the one carve-out, and it is the
        // same one `hasClosingVerb` already makes with its "no more than" strip:
        // there the "no" belongs to the quantifier and bounds the ask rather
        // than refusing it.
        //
        // `.silence` rather than a decline, because declining walks into SPEND
        // and buys the app the sentence was trying to restrict.
        let phraseStart = lexeme ?? numberAt ?? doorStart
        var refused = (clause.lowerBound..<phraseStart).contains { i in
            guard negators.contains(t[i]) else { return false }
            return !(t[i] == "no" && i + 2 < clause.upperBound
                     && t[i + 1] == "more" && t[i + 2] == "than")
        }
        // AND A NEGATOR STANDING ON THE NUMBER REFUSES THE NUMBER. The scan
        // above reads only what stands before the proposal, so "cap tiktok at
        // not 20 but 30" wrote the very ceiling the sentence NEGATES: "but"
        // opens a clause, "but 30" leaves the breath, and the cap clause held
        // exactly one number with its "not" invisible between lexeme and
        // number (FINDING 12). Adjacency, the shape of a determiner on its
        // noun — a negator further off is governing something else, and "no
        // more than 20" puts "than", not its negator, on the number.
        //
        // THROUGH ONE TRANSPARENT INTENSIFIER. "cap tiktok at not even 20"
        // put "even" in the numberAt-1 slot and its "not" one further back,
        // where the adjacency test never looked — and the 20 the sentence
        // negates was written (ROUND 3, n2). The adjacency doctrine's own
        // justification ("a negator further off is governing something
        // else") is false for exactly this word: "not even" governs the
        // number through it. One word ("even"), one token of reach, so "no
        // more than 20" still puts "than" on its number and a negator any
        // further off keeps its other-business reading.
        if let numberAt, numberAt > clause.lowerBound {
            if negators.contains(t[numberAt - 1]) {
                refused = true
            } else if t[numberAt - 1] == "even", numberAt - 1 > clause.lowerBound,
                      negators.contains(t[numberAt - 2]) {
                refused = true
            }
        }
        if refused { return .silence }

        // A REPORT IS NOT AN INSTRUCTION. See `reportsRatherThanSets` — the
        // mirror of the gate `capCleared` already had, and the one this rule
        // never got.
        //
        // WHAT IT COSTS, measured rather than discovered later: a report is
        // still a sentence naming a door and a number, so a mood refusal that
        // DECLINED would walk into SPEND and buy the app the sentence was only
        // describing. It terminates instead. Over a 1,942-sentence sweep the
        // gate turns 498 ceilings into silence, and 294 of those are sentences
        // `main` answered with a GRANT — that is the price, and it is the
        // doctrinally right one: silence reaches the widener, which per §5.7 can
        // produce neither a cap nor a deletion, and a grant out of a report
        // cannot be taken back. Zero of the 498 become grants.
        if reportsRatherThanSets(t, clause: clause, phraseStart: numberAt ?? doorStart,
                                 state: state) {
            return .silence
        }

        // A NUMBER THAT IS NOT A COUNT OF MINUTES WRITES NO CEILING. Per-app
        // schedules are out of scope, so "cap tiktok at 10 pm" has no
        // compilation — and it must not acquire one by falling through either.
        // As a guard in a condition list it did exactly that: the sentence
        // declined the rule and landed on SPEND, buying ten minutes of the app
        // it was trying to put on a schedule. Silence is the honest compilation
        // of a sentence with no compilation.
        if numberIsNotMinutes(t, in: clause) { return .silence }

        // A NUMBER AIMED BY "by" IS A DELTA, AND THIS GRAMMAR CANNOT DO
        // ARITHMETIC — the subtractive doctrine (`everyNumberLiesInside`'s
        // silence on "take 20 off the tiktok cap") already says so, and the
        // additive spellings need the same terminating refusal: "raise the
        // tiktok cap by 10" wrote the DELTA as an absolute ceiling — an
        // instant tighten to 10 out of a request to LOOSEN — and "lower the
        // tiktok cap by 5" landed 5 where the sentence meant 15 (FINDINGS
        // 13-14). "by" is deliberately absent from `ceilingPrepositions`
        // because it never aims an absolute; silence reaches the widener,
        // which per §5.7 can produce no cap out of this either.
        if let numberAt, numberAt > clause.lowerBound, t[numberAt - 1] == "by" {
            return .silence
        }

        guard case .one(let d) = doors(in: clause, of: index, state: state) else {
            // Two doors and one ceiling. Falling through answered it by debiting
            // the pool and unshielding whichever name was spelled first — a
            // grant, out of a sentence asking to tighten two doors. Silence
            // reaches the widener, which cannot produce a cap at all (§5.7) and
            // so cannot get the door wrong either.
            return .silence
        }
        // TWO numbers state no ceiling this rule can write. "drop the tiktok
        // limit from 30 to 20" is the natural way to say LOWER MY CAP and names
        // its ceiling twice; the honest answer is nothing, and it may not be a
        // grant, so the silence terminates.
        //
        // ZERO is unreachable and deliberately so: every shape above now
        // requires the clause to carry a number. It reached here before, and the
        // blanket silence it got was a veto over the whole utterance — a clause
        // that merely MENTIONS a ceiling proposed nothing, and killing the
        // sentence for it cost the spend in the next breath and the written-out sentence
        // in rule 8. The guard keeps the `count == 1` form rather than testing
        // `> 1`, so that a future shape which forgets to require a number fails
        // silent rather than crashing on `numbers.first`.
        guard numbers.count == 1, let n = numbers.first else { return .silence }
        // A QUESTION THE SENTENCE ITSELF ANSWERS "no" IS DECLINED. The
        // requestModals exemption admits "should i cap tiktok at 20" as a
        // setter — a request wrapped in politeness — and the answering "no"
        // is an invisible one-word clause, so a self-declined question wrote
        // standing policy with only a toast (FINDING 10). Scoped to the
        // question shape the exemption itself admits (a request modal in the
        // clause) and to a LATER clause that is nothing but a bare negator:
        // "no, cap tiktok at 20" leads with its sealed negator and still
        // sets, and a trailing "no" after a plain imperative is not a
        // question being answered. The answer clause speaks the decline's
        // own vocabulary too — `spokenDeclines`, because "should i cap
        // tiktok at 20? nah" declined the question one synonym over from
        // the fixed sentence and wrote the ceiling anyway (ROUND 3, n3).
        // AND THE DECLINE GOVERNS THROUGH A TRANSPARENT DISCOURSE ADVERB:
        // "should i cap tiktok at 20? actually no" answers no, and the
        // all-negator test broke on "actually" — the n2 "even" move one gate
        // over — so the veto lifted and the refused ceiling was written
        // (ROUND 3, n9). Admitted one word deep, the seam moved one adverb
        // over: "honestly no" and "probably not" answer the same no, and
        // both wrote the ceiling the asker refused (ROUND 4, n13). The
        // answer slot reads `answerSlotAdverbs` — a closed inventory, not a
        // single token — and the clause must still CONTAIN a decline, so a
        // bare trailing adverb answers nothing and vetoes nothing, and an
        // entry admitted there can only subtract a written ceiling — the
        // direction the family must fail in. The mechanics live in
        // `aLaterClauseDeclinesTheAsk`, which rule 3 now reads too: the
        // veto lived only here, so the pool family had no copy at all
        // (ROUND 6, n25).
        if aLaterClauseDeclinesTheAsk(index, clause: clause) {
            return .silence
        }
        return .command(.setDoorCap(door: d, minutes: n))
    }

    /// Whether the sentence itself declines the request-modal question this
    /// clause asks — a LATER clause that is nothing but the decline's own
    /// vocabulary. The declined-question veto's mechanics, extracted so both
    /// proposal families read ONE test: it grew up in `capSet` (FINDING 10;
    /// ROUND 3, n3/n9; ROUND 4, n13; ROUND 5, n18; ROUND 6, n21 — the
    /// history is on the call site), and the pool had no copy anywhere —
    /// `namesThePool`'s shortcut was gated on attribution alone — so "should
    /// i set my budget to 30? tbh no" wrote the refused allowance as
    /// standing policy with only a toast: FINDING 10 replayed one family
    /// over, failing on a bare "? no" as surely as on any inventory member
    /// (ROUND 6, n25). README rule 1 is this file's oldest principle, and
    /// the answer to a question is never a new rule.
    ///
    /// Scoped exactly as the cap-side veto always was: the asked clause must
    /// carry a request modal, the answer clause must come LATER, must
    /// CONTAIN a decline (`nounNegators` or `spokenDeclines` — a bare
    /// trailing adverb answers nothing), and may carry nothing beyond
    /// decline vocabulary and the transparent `answerSlotAdverbs`. "no, cap
    /// tiktok at 20" leads with its sealed negator and still sets; a
    /// trailing "no" after a plain imperative is not a question being
    /// answered, because a plain imperative carries no request modal. A read
    /// here can only subtract a written ceiling or an allowance move — the
    /// direction both families must fail in.
    private static func aLaterClauseDeclinesTheAsk(_ index: NumberParser.ClauseIndex,
                                                   clause: Range<Int>) -> Bool {
        let t = index.tokens
        guard clause.contains(where: { requestModals.contains(t[$0]) }) else { return false }
        return clauseRanges(index).contains { later in
            later.lowerBound >= clause.upperBound
                && later.contains(where: {
                    nounNegators.contains(t[$0]) || spokenDeclines.contains(t[$0])
                })
                && later.allSatisfy {
                    nounNegators.contains(t[$0]) || spokenDeclines.contains(t[$0])
                        || answerSlotAdverbs.contains(t[$0])
                }
        }
    }

    /// Where the ceiling word stands in a clause, or nil when the clause names
    /// none. "at most" is a pair rather than a token because neither word means
    /// anything alone — "at" is how the clock sentences state an hour ("cap
    /// tiktok at 9:30"), and "most" is not a quantity.
    private static func capLexemeIndex(_ t: [String], in clause: Range<Int>) -> Int? {
        clause.first { i in
            capNouns.contains(t[i]) || capQuantifiers.contains(t[i])
                || (t[i] == "at" && i + 1 < clause.upperBound && t[i + 1] == "most")
        }
    }

    private static func isQuantifier(_ t: [String], at i: Int) -> Bool {
        capQuantifiers.contains(t[i]) || t[i] == "at"
    }

    /// Whether a word is shaped like the head of a habit report — a gerund or
    /// a past participle. Morphology, used for the same narrow purpose
    /// `door(_:in:)` uses it (a suffix read off a token, never a substring),
    /// and fenced by the grammar's own verb lists so that "need" (an ask verb
    /// that happens to end in "ed") is never mistaken for one.
    private static func isHabitParticiple(_ w: String) -> Bool {
        guard !askVerbs.contains(w), !volitions.contains(w), !capNouns.contains(w),
              !capRemovers.contains(w) else { return false }
        if habitIrregulars.contains(w) { return true }
        return (w.count > 4 && w.hasSuffix("ing")) || (w.count > 3 && w.hasSuffix("ed"))
    }

    /// The irregular pasts of consuming — the verbs a report of screen time
    /// conjugates without the "ed" the suffix test reads: "spent 45 minutes on
    /// tiktok", "lost 2 hours to instagram", "took 45 minutes of my day". A list,
    /// and safe as one for the family's usual reason: each entry can only
    /// SUBTRACT a grant or a ceiling, and a subtraction is a silence that
    /// reaches the widener.
    ///
    /// EXTENDED WITH THE CONSUMING CLASS after "instagram stole 25 minutes from
    /// me" spent 25 real minutes: the door stood as SUBJECT of a finite past
    /// verb, and this list was the only thing that could know "stole" was
    /// one. The regular "ed" spellings (wasted, drained, killed…) ride along
    /// for the class's legibility even though the suffix test already reads
    /// them; the irregulars (stole, drank, threw…) are the entries doing the
    /// work. THE STRUCTURAL RULE IS THE EVENTUAL FIX: a door as subject
    /// followed by any finite past-tense verb that is not an ask verb is a
    /// report, list or no list — but finite past tense is exactly the thing
    /// English marks irregularly, so until a morphology can read "stole"
    /// without a list, the list is the honest spelling of the rule.
    private static let habitIrregulars: Set<String> = [
        "spent", "lost", "blew", "took", "went", "got", "ate", "gave",
        "stole", "steals", "stolen", "drank", "drunk", "burnt", "burned",
        "wasted", "killed", "drained", "sucked", "chewed", "swallowed",
        "robbed", "threw", "thrown", "dumped",
    ]

    /// Whether the door is named as a TOPIC rather than as the subject of a
    /// predicate — the habitual shape's own question. "tiktok 20 a day" puts a
    /// door and a daily quantity side by side and nothing else; "tiktok takes 30
    /// minutes a day" makes the door the subject of a verb and reports what the
    /// app does with her day.
    ///
    /// A TOPIC LEADS ITS CLAUSE, which is what scopes this question. A door
    /// standing anywhere else is the object of something — "20 a day on tiktok",
    /// "give me 60 a day max on tiktok and thats it" — and what follows it there
    /// is another phrase rather than its predicate. Asked of every door instead,
    /// a trailing coordinate clause read as a predicate and cost two pinned
    /// ceilings.
    ///
    /// Then adjacency, which is what a topic has, and the noun-phrase whitelist,
    /// which is what says the next word continues the phrase instead of
    /// predicating something of it. A door at the end of its clause predicates
    /// nothing by construction and answers yes.
    private static func doorIsATopic(_ t: [String], clause: Range<Int>, doorStart: Int,
                                     state: PolicyState) -> Bool {
        guard doorStart == clause.lowerBound else { return true }
        var after = doorStart + 1
        // The possessive's orphan. "tiktok's" reaches here as ["tiktok", "s"] —
        // the tokenizer splits on the apostrophe — and that "s" is the door's
        // own name continuing, not a predicate of it. Without this, "tiktok's 20
        // a day" declined while "tiktoks 20 a day" compiled, which is the
        // apostrophe disagreement `door(_:in:)` deinflects to prevent.
        if after < clause.upperBound, t[after] == "s" { after += 1 }
        guard after < clause.upperBound else { return true }
        return isNounPhraseWord(t, after, state: state)
            || capNouns.contains(t[after]) || capQuantifiers.contains(t[after])
    }

    /// Whether a number in this clause is something other than a count of
    /// minutes — a clock hour, or a duration stated in hours. Either way this
    /// rule cannot write it, and the answer is silence rather than a ceiling
    /// off by a factor of sixty or by half a day.
    ///
    /// A bare number after "at" is a DURATION — "cap tiktok at 20" is the
    /// canonical sentence and "at" is its preposition — so only a meridiem, a
    /// clock word or a boundary word makes an hour. The cost is disclosed rather
    /// than hidden: against a TikTok capped at 10, "cap tiktok at 11" is a
    /// parked raise with a row on Now and an Undo on the toast.
    ///
    /// THE MERIDIEM IS TESTED IN BOTH SPELLINGS THE TOKENIZER PRODUCES. "10 pm"
    /// is one token and "10 p.m." is the pair ["p", "m"] — the abbreviation's
    /// dots are separators — so a test written as `t[i + 1] == "pm"` missed the
    /// most common WRITTEN form and installed a ten-minute-a-day ceiling,
    /// instantly and permanently, from a sentence naming an hour of the evening.
    /// `NumberParser.statedTime` rewrites "p.m." to "pm" before it reads a clock
    /// for exactly this reason (NumberParser.swift); the clause index works in
    /// tokens, so the same fact is spelled here in tokens.
    ///
    /// HOURS ARE NOT MINUTES, and the cap rule declines them rather than
    /// reading them. `allNumbers` now scales an hours unit onto the number it
    /// stands on, so "give me 2 hours of tiktok" is 120 and the two-minute
    /// grant is gone — but the arm below stays, and the reason it stays is
    /// different from the reason it arrived.
    ///
    /// It arrived because 2 was read as 2 and the rule would have written a
    /// TWO-MINUTE daily ceiling: sixty times too tight, on the tightening side,
    /// and permanent. That reading is fixed. What is left is the DIRECTION.
    /// A ceiling is standing policy, and "cap tiktok at 2 hours" against a door
    /// already capped at ten is a two-hour ceiling — which is a LOOSENING, said
    /// in the vocabulary of restriction. `capHostileStringsNeverLoosen` and the
    /// disambiguation table both pin that no cap sentence may loosen, and they
    /// are right to: the sentence reads as a tighten to everyone who says it.
    /// Silence reaches the widener, which is structurally incapable of
    /// producing a cap at all (docs/design/per-app-caps.md §5.7), so it cannot
    /// get the direction wrong either. The other arms are about CLOCKS, which
    /// no unit can rescue: "cap tiktok at 10 in the evening" is a schedule, and
    /// per-app schedules are out of scope.
    private static func numberIsNotMinutes(_ t: [String], in clause: Range<Int>) -> Bool {
        let boundaries: Set<String> = ["after", "until", "untill", "till", "til"]
        let clockWords: Set<String> = ["am", "pm", "oclock", "clock", "noon", "midnight",
                                       "tonight", "morning", "evening", "afternoon"]
        for i in clause where NumberParser.readsAsNumber(t[i]) {
            if i > clause.lowerBound, boundaries.contains(t[i - 1]) { return true }
            // "N TIMES a day" is a COUNT of occurrences, not a count of
            // minutes — "checking tiktok 50 times a day" is a habit report,
            // and writing its 50 as a fifty-minute ceiling turned a
            // self-flagellating complaint into a parked five-fold RAISE
            // against the ten-minute cap in state. "times" is not a unit
            // anywhere in this grammar, so the number it modifies is a
            // quantity of nothing this rule can write.
            if i + 1 < clause.upperBound, t[i + 1] == "times" || t[i + 1] == "time" {
                return true
            }
            // A SECONDS unit is sixty times smaller than the domain's own
            // unit, and a ceiling of a fraction of a minute cannot be
            // written; "cap tiktok at 30 seconds" declines exactly as the
            // hours arm below declines, and for the same directional reason.
            // Through `statesSeconds`, which is the lexicon plus the glued
            // "s" the lexicon's own two unit lists disagree about: "cap
            // tiktok at 90s" wrote ninety MINUTES as standing policy.
            if statesSeconds(t, after: i, within: clause.upperBound) { return true }
            // The abbreviated meridiem, as its two tokens. "9 a day" is not one:
            // the "a" has to be followed by the "m".
            if i + 2 < clause.upperBound, t[i + 1] == "p" || t[i + 1] == "a", t[i + 2] == "m" {
                return true
            }
            // An hours unit must stand ON the number, and the question is asked
            // of `NumberParser` rather than answered again here — a guard that
            // reads a token differently from the reader it guards is a guard
            // with a hole in it, and this one had it twice. The inline set it
            // kept before lacked the spaced "h" that `allNumbers` reads, so
            // "cap tiktok at 2 h" was 120 to the reader and invisible to the
            // guard. (NOT the glued "2h", as an earlier draft of this comment
            // claimed — glued units are deliberately read by neither side; see
            // `hourUnits`.) And a one-token lookahead could not see through an
            // intensifier the reader now reads through: "cap tiktok at 2 whole
            // hours" was 120 to `allNumbers` and bare 2 to the guard, a
            // two-hour ceiling written in the vocabulary this arm declines.
            // Passing the following tokens — bounded by the clause, at most
            // the intensifier and the unit — keeps the pair one reading.
            if NumberParser.statesAnHour(
                following: t[min(i + 1, clause.upperBound)..<min(i + 3, clause.upperBound)]) {
                return true
            }
            // A clock word may hang off a preposition ("cap tiktok at 10 in the
            // evening"), so it is looked for anywhere after the number this
            // clause is about.
            if (i + 1..<clause.upperBound).contains(where: { clockWords.contains(t[$0]) }) {
                return true
            }
        }
        return false
    }

    /// Whether the clause a spend would read — the clause holding the
    /// sentence's first number, or, when the quantity is an idiom's and
    /// occupies no token, the clause holding the first door — funds the door
    /// being granted. Rule 7's ambiguity guard, and an IDENTITY test, not a
    /// head-count: `.several` is two doors competing for one grant, one door
    /// with another id is a clause paying for somebody else, and a doorless
    /// clause defers to the whole sentence, which must then be about exactly
    /// one door. None of those is a sentence this grammar may answer with a
    /// grant on `d`.
    /// Whether a negator stands in front of the door this sentence would spend
    /// on — "no tiktok for 2 hours", "not instagram today, 20 minutes".
    ///
    /// The cap rule has had this scan since the round that found "dont give me
    /// 30 a day on tiktok" writing a ceiling out of a refusal; SPEND, one rule
    /// below it, never got the same reading, and there the wrong answer is a
    /// GRANT — the door opened and the pool debited, in reply to a sentence
    /// asking for neither.
    ///
    /// **THE NEGATOR HAS TO STAND ON THE DOOR ITSELF**, and that is narrower
    /// than the cap rule's clause-wide scan on purpose. The first draft here
    /// was that scan, and it read four pinned sentences wrong in one direction:
    /// "dont give me more than 10 of tiktok" is a BOUNDED ASK, "dont close
    /// instagram, just give me 10" refuses the close and then asks — in both
    /// the negator governs a verb, not the door, and both went silent.
    ///
    /// So the test is `nounNegators` — the four words this file already
    /// separates out as the ones that can stand directly on a noun phrase — and
    /// adjacency, reading back over determiners only. "no tiktok" negates the
    /// door; "dont give me … tiktok" negates the giving. That distinction is
    /// already made once in this file for the clearing rule, and this is the
    /// same distinction, not a second theory of negation.
    ///
    /// Adjacency also retires the "no more than" carve-out the cap rule needs:
    /// in "no more than 20 of tiktok" the "no" is nowhere near the door, so
    /// nothing here can see it.
    ///
    /// It costs the sentences where a refusal and an ask share a breath, and
    /// those go to the widener, which is the safe direction: the Validator's
    /// provenance still bounds whatever comes back, and a grant out of a
    /// refusal cannot be taken back.
    ///
    /// **EVERY occurrence of the door is inspected, not the first.** The scan
    /// used to stop at `t.indices.first(where:)`, so any earlier un-negated
    /// mention shadowed the refusal standing on a later one: "im addicted to
    /// tiktok, no tiktok for 20 minutes" and "i love tiktok but no tiktok for
    /// 20 minutes" both opened the door and debited the pool — the grant out
    /// of a refusal this guard exists to close, reachable through the most
    /// natural spelling there is, a reason before the rule. A negator on ANY
    /// occurrence silences; the sentence where one mention is refused and
    /// another asked is a refusal and an ask sharing a sentence, which is the
    /// widener's by the paragraph above.
    private static func aRefusalNamesTheDoor(_ d: Door, _ index: NumberParser.ClauseIndex,
                                             state: PolicyState) -> Bool {
        let t = index.tokens
        for at in t.indices {
            guard doorAt(t, at, within: t.count, state: state)?.door.id == d.id,
                  let clause = index.clauseRange(containing: at) else { continue }
            var head = at
            while head > clause.lowerBound, determiners.contains(t[head - 1]) { head -= 1 }
            guard head > clause.lowerBound else { continue }
            if nounNegators.contains(t[head - 1]) { return true }
        }
        return false
    }

    /// Whether a negator stands on the OPENING VERB — the other spelling of a
    /// refusal, and the one `aRefusalNamesTheDoor` cannot see. "dont open
    /// tiktok for 20 minutes", "do not unlock reddit for 45 minutes" and
    /// "never let me open instagram for 30 minutes" are pure refusals; each
    /// opened the refused door and debited the pool, because the negated verb
    /// is an opener token, the close rule vetoes itself on it, and nothing
    /// else claimed the sentence.
    ///
    /// ADJACENCY, exactly as the noun scan reads its negator: "dont GIVE",
    /// "not UNLOCK", "never LET". A negator further off is governing something
    /// else — "dont close instagram, just give me 10" negates the CLOSE and
    /// still grants.
    ///
    /// The one carve-out is the bounded ask, and it is pinned: "dont give me
    /// MORE THAN 10 of tiktok" negates the exceeding, not the giving, and the
    /// "more than" standing between the verb and the end of its clause is
    /// what says so.
    private static let bareNegators: Set<String> = ["no", "not", "never", "none"]

    private static func aNegatorRefusesTheAsk(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        for i in t.indices where negators.contains(t[i]) {
            // "ever" is the one word English glues between the negator and the
            // verb it strengthens — "dont EVER open tiktok" — and skipping it
            // can only widen a refusal, never a grant.
            var verbAt = i + 1
            if verbAt < t.count, t[verbAt] == "ever" { verbAt += 1 }
            // THE LEXICON IS THE ONE THE MINT USES. `askVerbs` predates the
            // spend grammar's opening-verb authority and never learned its
            // last four stems, so "dont USE instagram for 10 minutes", "dont
            // SPEND 10 minutes on instagram", "dont GET on instagram for 10
            // minutes" and "no USE, instagram for 10" each bought ten minutes
            // of the app the sentence was refusing — while "dont OPEN
            // instagram for 10 minutes", the same sentence with a stem this
            // set already held, fell silent. The refusal has to read whatever
            // the grant reads or it is a guard with holes in the shape of the
            // newest verbs.
            //
            // STEMS ONLY, and only here: `askVerbs` is read by the cap family
            // too, and this is the spend path's own refusal, whose every
            // answer is a silence.
            guard verbAt < t.count,
                  askVerbs.contains(t[verbAt]) || openingVerbStems.contains(t[verbAt]),
                  let clause = index.clauseRange(containing: i), clause.contains(verbAt)
            else { continue }
            // AND THOSE TWO NEED THEIR PARTICLE. "go" and "get" mean the app
            // only as "go on"/"get on" — the same fact `particledGerunds`
            // reads on the commitment side. Without this the refusal claims
            // "dont get mad, give me 10 minutes of instagram", which is an ask
            // with a preamble, and a guard that eats asks is how a widening
            // pays for itself twice.
            if t[verbAt] == "go" || t[verbAt] == "get" {
                guard verbAt + 1 < t.count, t[verbAt + 1] == "on" else { continue }
            }
            // A DERIVED STEM REFUSES ONLY THE CLAUSE THAT CARRIES THE ASK.
            // "i dont use instagram much, unlock instagram for 10 min" opens
            // with a negated "use" in a clause that asks for nothing, and
            // then asks in the next one — with Silk's own hint sentence. The
            // ask-verb family keeps its whole-sentence reading, which its
            // rows were pinned against; the stems the tightening added
            // ("use", "spend", "go on", "get on") are ordinary verbs of
            // ordinary preambles, so their negation refuses the sentence only
            // when the number stands in the same clause as the negator.
            // The bare negators — "no", "not", "never", "none" — keep the whole-
            // sentence reading even on a derived stem: "no use, instagram for
            // 10" and "never use instagram for 10 minutes" are refusals wearing
            // the noun and the imperative, and neither has a preamble to
            // exempt. Only the verbal contractions ("dont", "shouldnt", …)
            // open a preamble a real ask can follow.
            if !askVerbs.contains(t[verbAt]), !bareNegators.contains(t[i]),
               !clause.contains(where: { NumberParser.readsAsNumber(t[$0]) }) { continue }
            // The bounded-ask carve is scoped to the immediate "dont": "dont
            // give me more than 10 of tiktok" negates the exceeding. "NEVER
            // open instagram for more than 20 minutes" is a standing rule, and
            // granting its 20 is the wrong answer twice over — so the durative
            // negators keep the refusal and the sentence goes to the widener.
            let immediate = t[i] == "dont" || t[i] == "don't"
                || (t[i] == "not" && i > t.startIndex && t[i - 1] == "do")
            let bounded = immediate && (i + 1..<clause.upperBound).dropLast().contains {
                t[$0] == "more" && t[$0 + 1] == "than"
            }
            if !bounded { return true }
        }
        return false
    }

    /// Whether the sentence's number is the object of "until"/"till"/"til" —
    /// a deadline, which the grant side has no way to honor. Rule 7 read
    /// "give me tiktok till 7" as a SEVEN-MINUTE grant while the close rule
    /// reads the identical words as a clock ("block tiktok until 9" closes
    /// until 9 PM): two directions of one idiom under two theories. The grant
    /// side stays silent instead — silence reaches the widener, and a
    /// misread deadline debits the pool twice (once for the seven minutes,
    /// once for the re-ask after them).
    private static func theNumberIsADeadline(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        let deadlineMarkers: Set<String> = ["until", "untill", "till", "til"]
        return t.indices.contains { i in
            i > t.startIndex && deadlineMarkers.contains(t[i - 1])
                && NumberParser.readsAsNumber(t[i])
        }
    }

    /// Whether a seconds unit stands on any number in the sentence. The unit
    /// lexicon and the intensifier walk both belong to `NumberParser`, so the
    /// question is asked there — see `statesSeconds` for why the guard and
    /// the reader must be one reading.
    private static func theNumberStatesSeconds(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        for i in t.indices where NumberParser.readsAsNumber(t[i]) {
            guard let clause = index.clauseRange(containing: i) else { continue }
            if statesSeconds(t, after: i, within: clause.upperBound) { return true }
        }
        return false
    }

    /// Whether a seconds unit stands on the number at `i` — the slice bounds
    /// for `NumberParser.statesSeconds`, hoisted out of the two guards that
    /// ask it. The lexicon is `NumberParser.secondUnits`, and it holds the
    /// bare "s" the tokenizer peels from "90s": between a `glueableUnits`
    /// that called "s" a seconds unit and a `secondUnits` that did not sat a
    /// SIXTY-TIMES grant — "unlock instagram for 90s" spent ninety minutes
    /// and "cap tiktok at 90s" wrote ninety as a ceiling, through the
    /// spelling a thumb types, while every spelled-out form was already
    /// declined. The two lists agree now. That widening cannot change what
    /// a number READS as, because `secondUnits` is read by `statesSeconds`
    /// and by nothing else, and both guards only REFUSE: `allNumbers` still
    /// reports 90, provenance is untouched, and the sentence reaches the
    /// widener instead of the mint.
    private static func statesSeconds(_ t: [String], after i: Int, within upper: Int) -> Bool {
        guard i + 1 < upper else { return false }
        return NumberParser.statesSeconds(following: t[(i + 1)..<min(i + 3, upper)])
    }

    /// Whether the clause a spend would read is a REPORT or incidental prose
    /// rather than an ask — rule 7's mood gate, anchored exactly where
    /// `spendClauseFunds` anchors (the sentence's first number token, or the
    /// first door for the token-less idiom quantities).
    ///
    /// The corpus dictates how lenient the ask side must stay, and the gate is
    /// built against its pinned rows rather than against a theory: "hey so i
    /// was thinking maybe like 10 minutes of reddit would be nice" grants (the
    /// request modal marks the ask), "my friend said give me an hour of
    /// tiktok" grants (an ask verb with no finite verb anywhere), and "reddit
    /// ten ok bye love you" grants (door and number adjacent, chatter
    /// trailing). What it refuses is the shapes with report evidence standing
    /// BEFORE the quantity or a finite verb in the clause:
    ///
    ///  - a spoken SUBJECT ahead of the number: "i watched tiktok for 45
    ///    minutes at lunch", "i wasted 2 hours on instagram today";
    ///  - a FINITE non-modal verb in the clause: "tiktok premium is like 9
    ///    dollars", "…give me 20 minutes of tiktok IS what i always type"
    ///    (the quoted-speech frame's own copula);
    ///  - a DETERMINER heading a clause with no ask verb whose opening is not
    ///    one noun phrase: "my screen time says 55 minutes of youtube";
    ///  - an AUXILIARY or wh-word heading the clause: a question is never a
    ///    grant;
    ///  - and a clause that names NO door funds the grant only as an ask verb
    ///    or a bare fragment — "just give me 10", "20 minutes tops", "ten" —
    ///    never as arbitrary prose: "meet me at 5, then we can doomscroll
    ///    tiktok" granted five minutes off a meeting time.
    private static func reportsRatherThanSpends(_ index: NumberParser.ClauseIndex,
                                                state: PolicyState, commitment: Bool) -> Bool {
        let t = index.tokens
        let numberAt = t.indices.first { NumberParser.readsAsNumber(t[$0]) }
        let anchor = numberAt
            ?? t.indices.first { i in
                door(t[i], in: state) != nil
                    || (i + 1 < t.count && door(t[i] + " " + t[i + 1], in: state) != nil)
            }
        guard let anchor, let clause = index.clauseRange(containing: anchor),
              let first = clause.first
        else { return false }
        let ahead = clause.lowerBound..<anchor
        // A request modal marks the ask, unless a wh-word ahead makes the
        // sentence a question — the same exemption `reportsRatherThanSets`
        // carries, read over the whole clause because the pinned ask puts its
        // "would" after the quantity ("…10 minutes of reddit would be nice").
        // "i'd" is "i would" and tokenizes as ["i", "d"]; the clitic is the
        // request modal in the spelling a thumb types.
        if !ahead.contains(where: { whWords.contains(t[$0]) }),
           clause.contains(where: { requestModals.contains(t[$0]) || contractedWould(t, at: $0) }) {
            return false
        }
        if statesAVolition(t, clause: clause) { return false }
        // AN INVERSION IS A REQUEST, not the question a fronted auxiliary
        // usually marks — see `anInversionOpensTheClause`. Beside the two
        // exemptions above because it is the same kind of fact: the mood is
        // marked by the clause's own opening, ahead of every scan.
        if anInversionOpensTheClause(t, clause: clause) { return false }
        let asks = clause.contains { askVerbs.contains(t[$0]) }
        // QUOTED SPEECH: a speech verb ahead of the quantity is somebody
        // else's sentence being reported — but only the RESUMING frame proves
        // it. "my friend said give me 20 minutes of tiktok is what i always
        // type" closes its quote with a copula and is silenced; "my friend
        // said give me an hour of tiktok" never resumes, reads as the user
        // adopting the ask, and stays the corpus's pinned grant.
        if ahead.contains(where: { speechVerbs.contains(t[$0]) }),
           clause.contains(where: { auxiliaries.contains(t[$0]) && !modals.contains(t[$0]) }) {
            return true
        }
        // A COMMITMENT IS AN ASK. "im using instagram for 5 minutes" speaks
        // its subject and conjugates a gerund, so the two arms below — the
        // spoken-subject arm and the habit-participle arm — each silenced it
        // twice over, and the sentence a person types when she is being
        // honest with the machine about what she is about to do got the same
        // answer as a report of yesterday's screen time.
        //
        // AFTER the quoted-speech arm, so an attributed commitment stays
        // somebody else's sentence, and behind four guards of its own
        // (`statesACommitment`) so a habit, a perfect, a past and a two-number
        // ambiguity are all still reports.
        if commitment { return false }
        // A spoken subject ahead of the quantity is a report — unless an ask
        // verb shares the clause: "ive hit my limit give me 20 of tiktok" is
        // commentary and then an ask, and the ask wins.
        if !asks, ahead.contains(where: { subjects.contains(t[$0]) }) { return true }
        // A subject standing DIRECTLY ON an ask verb has conjugated it: "she
        // LET me have tiktok for 30 minutes yesterday" reports somebody's
        // permission, and the ask-verb exemption above must not launder it.
        // The volitional asks ("i want", "i need") keep their own exemption,
        // and the first-person futures ("ill have 20 of tiktok") are asks by
        // construction.
        if ahead.contains(where: { i in
            subjects.contains(t[i]) && t[i] != "ill" && t[i] != "id"
                && i + 1 < clause.upperBound && askVerbs.contains(t[i + 1])
                && !volitions.contains(t[i + 1])
        }) { return true }
        // A PARTICIPLE ahead of the quantity with no ask verb ahead is a
        // habit report with its subject elided: "spent 45 minutes on tiktok
        // ugh", "wasted an hour on instagram again". An ask verb ahead re-marks
        // the mood ("just finished homework give me 20 of tiktok" grants).
        if !ahead.contains(where: { askVerbs.contains(t[$0]) }),
           ahead.contains(where: { isHabitParticiple(t[$0]) }) {
            return true
        }
        // A DOOR AS SUBJECT with its consuming verb standing directly on it
        // is the app reporting what it did with her day — and that shape can
        // reach here with an EMPTY `ahead`, because when the quantity lives
        // in no token ("instagram stole AN HOUR from me": the article idiom
        // carries the 60), no number anchors and the door itself is the
        // anchor, so the participle scan above has nothing to walk. The
        // structural rule — a door as subject followed by a finite non-ask
        // verb is a report — is asked of the one position English puts the
        // predicate: the token after the door's own name. A door followed by
        // anything else ("tiktok for an hour", "tiktok, 10 pls") predicates
        // nothing and still grants.
        if !asks, numberAt == nil, anchor == clause.lowerBound {
            var predicateAt = anchor + 1
            // A two-token door name keeps its second word: the predicate
            // stands after the whole name, not after its first token. Dead
            // against any shipping roster — see the invariant at `doorAt` —
            // and here for the day the catalogue carries a two-word entry.
            if predicateAt < clause.upperBound,
               door(t[anchor] + " " + t[predicateAt], in: state) != nil {
                predicateAt += 1
            }
            if predicateAt < clause.upperBound,
               isHabitParticiple(t[predicateAt])
                || (auxiliaries.contains(t[predicateAt]) && !modals.contains(t[predicateAt])) {
                return true
            }
        }
        // A finite verb ahead of the quantity with no ask verb ahead of it is
        // a description: "tiktok premium IS like 9 dollars", "the youtube ad
        // WAS 30 seconds long". An ask verb ahead re-marks the mood — "its
        // been a rough day GIMME fifteen minutes of instagram" grants.
        if ahead.contains(where: { auxiliaries.contains(t[$0]) && !modals.contains(t[$0]) }),
           !ahead.contains(where: { askVerbs.contains(t[$0]) }) {
            return true
        }
        if whWords.contains(t[first]) || auxiliaries.contains(t[first]) { return true }
        // A determiner heading an ask-less clause must open one noun phrase
        // running to the quantity ("The Gram ten") — "my screen time says 55
        // minutes of youtube" does not. Only asked when a NUMBER token
        // anchors: the article idioms ("an hour and a half of tiktok") hold
        // their quantity in no token and their own words are not phrase
        // vocabulary.
        if let numberAt, numberAt == anchor, determiners.contains(t[first]), !asks,
           !(min(clause.lowerBound + 1, anchor)..<anchor)
            .allSatisfy({ isNounPhraseWord(t, $0, state: state) }) {
            return true
        }
        if case .none = doors(in: clause, of: index, state: state) {
            if asks { return false }
            return !spendFragment(t, clause: clause, state: state)
        }
        return false
    }

    /// The verbs that report somebody's words. Read only by the quoted-speech
    /// arm above, and only to REFUSE a grant, so an entry can never widen what
    /// spends.
    ///
    /// The RECOMMEND family reports words as surely as "said": the set was
    /// the say/tell/type/text/write families only, so "my therapist suggested
    /// tiktok - 20 a day" found no frame, no attributed arm fired, and
    /// somebody's reported recommendation cut the shared pool — n15/n19/n22
    /// one verb over, the exact move that produced n14 on the quotative side
    /// (ROUND 7, n31). suggest/recommend/advise/mention are seated whole,
    /// each in its four forms, because an entry here is subtract-only by this
    /// class's own doc.
    private static let speechVerbs: Set<String> = [
        "say", "says", "said", "saying",
        "tell", "tells", "told", "telling",
        "type", "types", "typed", "typing",
        "text", "texts", "texted", "write", "writes", "wrote",
        "suggest", "suggests", "suggested", "suggesting",
        "recommend", "recommends", "recommended", "recommending",
        "advise", "advises", "advised", "advising",
        "mention", "mentions", "mentioned", "mentioning",
    ]

    /// Whether a doorless clause is a bare fragment an ask can stand on — a
    /// quantity and the words that dress one, nothing predicated. "ten",
    /// "20 minutes", "20 minutes tops", "10 more", "no more than 20" all
    /// qualify; "meet me at 5" and "my number ends in 88" do not. A leading
    /// connective ("but", "so") joins the clause to the last one and
    /// predicates nothing of its own.
    private static func spendFragment(_ t: [String], clause: Range<Int>,
                                      state: PolicyState) -> Bool {
        var start = clause.lowerBound
        if start < clause.upperBound,
           ["but", "so", "anyway", "though"].contains(t[start]) { start += 1 }
        return (start..<clause.upperBound).allSatisfy { i in
            if isNounPhraseWord(t, i, state: state) || capQuantifiers.contains(t[i])
                || t[i] == "more" { return true }
            // "no more than" bounds the ask rather than predicating anything —
            // the carve-out `capSet`'s negator scan already makes.
            if t[i] == "no", i + 2 < clause.upperBound,
               t[i + 1] == "more", t[i + 2] == "than" { return true }
            if t[i] == "than", i >= clause.lowerBound + 2,
               t[i - 1] == "more", t[i - 2] == "no" { return true }
            // The tokenizer keeps ":" inside a token so clocks survive, which
            // means "minutes:" reaches here wearing its colon. Strip it for
            // the lexicon lookups only — the hostile corpus pins that
            // "grant(door: instagram, minutes: 999)" is answered by the clamp,
            // not by a parse hole.
            if t[i].hasSuffix(":") {
                let bare = String(t[i].dropLast())
                return measureWords.contains(bare) || determiners.contains(bare)
                    || phrasePrepositions.contains(bare)
                    || NumberParser.readsAsNumber(bare)
            }
            return false
        }
    }

    private static func spendClauseFunds(_ d: Door, _ index: NumberParser.ClauseIndex,
                                         state: PolicyState) -> Bool {
        let t = index.tokens
        let anchor = t.indices.first { NumberParser.readsAsNumber(t[$0]) }
            ?? t.indices.first { i in
                door(t[i], in: state) != nil
                    || (i + 1 < t.count && door(t[i] + " " + t[i + 1], in: state) != nil)
            }
        let clause = anchor.flatMap { index.clauseRange(containing: $0) }
        switch clause.map({ doors(in: $0, of: index, state: state) }) ?? .none {
        case .several:
            return false
        case .one(let named):
            return named.id == d.id
        case .none:
            // A quantity in a doorless breath belongs to the sentence's one
            // door or to no door at all: two distinct ids and the grant would
            // leave on whichever name was spelled first.
            if case .one = doors(in: t.startIndex..<t.endIndex, of: index, state: state) {
                return true
            }
            return false
        }
    }

    /// Whether the clause carrying the sentence's first number also names a
    /// door. Rule 3's last guard, and the reason the pool does not move on a
    /// sentence about one app.
    ///
    /// A number with no token position — an idiom's — is anchored at the
    /// idiom's own "hour", exactly as `namesThePool` anchors it. This guard
    /// used to answer no for the idioms on the theory that their quantity
    /// cannot be placed, and the theory cost the sentence it was written for:
    /// "give me an hour of tiktok, im on a budget" lost the pool shortcut
    /// (rightly), fell here, was waved past the door guard, and the fallback
    /// set the shared allowance to 60 out of a spend ask. The idiom's hour
    /// stands in a clause like any other token, and the clause it stands in
    /// names TikTok.
    private static func numberClauseNamesADoor(_ index: NumberParser.ClauseIndex,
                                               state: PolicyState) -> Bool {
        let t = index.tokens
        let at = t.indices.first(where: { NumberParser.readsAsNumber(t[$0]) })
            ?? t.firstIndex(of: "hour")
        guard let at, let clause = index.clauseRange(containing: at)
        else { return false }
        if case .none = doors(in: clause, of: index, state: state) { return false }
        return true
    }

    /// Whether the sentence's number lives in a DOORLESS clause standing
    /// directly after a clause that is NOTHING BUT a door's name — rule 3's
    /// third door guard, for the topic a clause dash strands.
    ///
    /// "tiktok - 20 a day" is the dash spelling of the pinned habitual setter
    /// "tiktok 20 a day": the spaced hyphen after a non-quantity word is a
    /// clause dash (NumberParser's disclosed over-splitting trade), so the
    /// door and its quantity land in different breaths, every cap rule goes
    /// blind, both existing door guards miss — the number's clause names no
    /// door and no ceiling word leads one — and the doorless fallback CUT THE
    /// SHARED POOL to the per-app number, instantly (FINDING 8). A bare door
    /// name standing alone in the breath before the number is the stranded
    /// topic of the number's own sentence; the sentence is about that door,
    /// and the pool must not move on it. Silence reaches the widener, which
    /// per §5.7 cannot produce a cap and so cannot get the door wrong either.
    ///
    /// The PREVIOUS clause only, and only when it holds nothing beyond the
    /// door's own name — or an attribution frame ending in it ("my notes say
    /// tiktok", ROUND 4 n15 below; "she was like tiktok" and the quoted
    /// two-door list, ROUND 5 n19): a door with a predicate of its own
    /// ("tiktok is killing me, make it 30 a day") is commentary, and those
    /// pool moves are pinned. The number anchor falls back to the idiom's
    /// "hour" exactly as `namesThePool` and `numberClauseNamesADoor` anchor
    /// it.
    private static func aBareDoorTopicPrecedesTheNumberClause(_ index: NumberParser.ClauseIndex,
                                                              state: PolicyState) -> Bool {
        let t = index.tokens
        let at = t.indices.first(where: { NumberParser.readsAsNumber(t[$0]) })
            ?? t.firstIndex(of: "hour")
        guard let at, let clause = index.clauseRange(containing: at) else { return false }
        guard case .none = doors(in: clause, of: index, state: state) else { return false }
        guard clause.lowerBound > 0,
              let prev = index.clauseRange(containing: clause.lowerBound - 1)
        else { return false }
        let prevDoors = doors(in: prev, of: index, state: state)
        // A door's name STARTING here — the file's one door primitive — or a
        // two-token name ENDING here, which is a different question and the
        // reason this closure is not just `doorAt`: the test is whether every
        // token of the breath belongs to the door's name, so the second token
        // of a two-token name has to answer yes on its own account.
        func doorToken(_ i: Int) -> Bool {
            doorAt(t, i, within: prev.upperBound, state: state) != nil
                || (i > prev.lowerBound && door(t[i - 1] + " " + t[i], in: state) != nil)
        }
        if case .one = prevDoors, prev.allSatisfy(doorToken) { return true }
        // AND THE ATTRIBUTED SPELLING OF THE SAME STRANDED TOPIC. "my notes
        // say tiktok - 20 a day" wears an attribution the dash puts one
        // breath back, where no pool gate could see it:
        // `poolStatementIsAttributed` guards only rule 3's shortcut (no pool
        // noun here), the fallback's mood gate reads only the number's own
        // clause, and this veto required the prior breath to hold nothing
        // beyond the door's name — "my notes say" is three words more — so a
        // quoted per-app note CUT THE SHARED POOL to 20, instantly (ROUND 4,
        // n15). An attribution frame in the prior breath whose tail is
        // nothing but the door's name is that door being QUOTED as the topic
        // of the number's sentence — the veto's own shape with the
        // reporter's frame ahead of it — and the pool does not move on
        // somebody's reported note.
        //
        // THE FRAME IS THE `speechVerbs` CLASS *AND* THE n14 QUOTATIVE, AND
        // THE FRAME OWNS WHATEVER TAIL NAMES THE DOOR. Keyed to
        // `speechVerbs` alone, "she was like tiktok - 20 a day" stood
        // exactly where "my notes say" was fixed — the dominant spoken
        // quotative carries no speech verb, and the two inventories were
        // never joined; and the arm's `case .one` guard with an
        // all-door-token tail let "my notes say tiktok and reddit - 20 a
        // day" — MORE clearly a per-app list than the fixed sentence —
        // defeat it twice, once on .several and once on "and" (ROUND 5,
        // n19). The copula-particle quotatives and the bare "goes" mirror
        // `poolStatementIsAttributed`'s own inventory.
        //
        // The quoted tail was then a whitelist — door tokens and "and" —
        // and both of its remaining exits were walked in one round. The
        // DISJUNCTIVE spelling of the same quoted two-door note defeated it
        // on "or" ("my notes say tiktok or reddit - 20 a day" cut the
        // shared pool to 20 — ROUND 6, n22), and the PREDICATED tail rode
        // the release contract out of a speech frame: "she said tiktok was
        // brutal - 20 a day" glosses the reported brutality with its rate,
        // and the release — written for the UNATTRIBUTED twin ("tiktok is
        // brutal. 45 a day for everything", pinned, which speaks no speech
        // verb and no quotative) — cut the shared pool out of somebody's
        // quoted opinion (ROUND 6, n23). A frame ahead of the door makes
        // the breath reported words, and a quoted tail that NAMES the door
        // at all — one name, a list, a disjunction, or a gloss — is that
        // door being quoted as the topic of the number's sentence: the
        // n15/n19 doctrine is that the pool does not move on somebody's
        // reported note. The predicated door with NO frame keeps releasing
        // the pool move exactly as before — a read here can only subtract
        // a pool move, the direction the pool must fail in.
        if case .none = prevDoors { return false }
        let frame = prev.compactMap { i -> (start: Int, end: Int)? in
            if speechVerbs.contains(t[i]) { return (i, i + 1) }
            if t[i] == "goes" { return (i, i + 1) }
            if ["was", "were", "be"].contains(t[i]), i + 1 < prev.upperBound,
               ["like", "all"].contains(t[i + 1]) { return (i, i + 2) }
            return nil
        }.first
        guard let frame else { return false }
        if frame.end < prev.upperBound,
           (frame.end..<prev.upperBound).contains(where: doorToken) { return true }
        // AND THE POSTPOSED FRAME QUOTES THE DOOR AHEAD OF IT. "tiktok she
        // said - 20 a day" is the standard dictation of «"tiktok", she said»
        // — the speech verb stands clause-FINAL, so the frame's tail is
        // empty, the forward read above finds nothing, and the unattributed
        // arm needs the breath to be nothing but the door's name, which
        // "she said" defeats: the quoted per-app note cut the shared pool
        // through the gap between the veto's two arms (ROUND 7, n30). A
        // frame whose tail is empty owns the breath it CLOSES, so the door
        // is read ahead of it instead — while the frameless release twin
        // ("tiktok was brutal - 45 a day for everything", pinned) carries
        // no frame at all and keeps its pool move. One more read that can
        // only subtract a pool move, the direction the pool must fail in.
        return frame.end == prev.upperBound
            && (prev.lowerBound..<frame.start).contains(where: doorToken)
    }

    /// Whether some clause states a ceiling word LEADING a door and carries no
    /// number of its own — "cap tiktok" in "cap tiktok so i only get 20 a day",
    /// where the clause opener took the number into the next breath.
    ///
    /// Rule 3's second guard. It asks `capSet`'s own shape-one question, minus
    /// the number that rule needs, which is the point: a clause with that shape
    /// has proposed a ceiling nobody can resolve, and the pool is not what it
    /// proposed.
    ///
    /// AND THE CEILING WORD MUST BE THE CLAUSE'S OWN FIRST WORD. The one
    /// sentence justifying this guard is "cap tiktok so i only get 20 a day",
    /// where the ceiling word is the clause's imperative VERB — that is what
    /// proposes a ceiling the grammar cannot resolve. Written as "a ceiling word
    /// before a door in any clause" it also read commentary: "make it 30 a day,
    /// the limit on tiktok is killing me" states a budget in its first breath
    /// and names the ceiling as the reason in its second, and it lost the budget
    /// move that the near-identical "make it 30 a day, tiktok is my limit" — a
    /// pinned row — still gets. A ceiling word inside a noun phrase governs that
    /// phrase, not the sentence.
    private static func aCeilingLeadsADoorWithNoNumber(_ index: NumberParser.ClauseIndex,
                                                       state: PolicyState) -> Bool {
        let t = index.tokens
        return clauseRanges(index).contains { clause in
            guard let doorStart = doorIndex(in: clause, of: index, state: state),
                  let lexeme = capLexemeIndex(t, in: clause), lexeme < doorStart,
                  lexeme == clause.lowerBound
            else { return false }
            return NumberParser.allNumbers(in: t[clause].joined(separator: " ")).isEmpty
        }
    }

    /// Whether a ceiling NOUN stands in the same clause as a door — rule 5's
    /// guard, and the invariant suite's filter.
    ///
    /// `internal` for the same reason `hasClosingVerb` is: the property test
    /// asks the parser which sentences it considers cap-shaped rather than
    /// restating the lexicon, because a second copy drifts and then the property
    /// proved is not the property that ships.
    static func capNounSharesTheDoorsClause(_ text: String, state: PolicyState) -> Bool {
        capNounSharesTheDoorsClause(NumberParser.ClauseIndex(text), state: state)
    }

    /// The same question asked of ONE door — the door rule 5 matched, which is
    /// the only one whose deletion is at stake. See
    /// `doorsClauseStatesANewCeiling` for the sentence that forced the scoping.
    static func capNounSharesTheDoorsClause(_ text: String, state: PolicyState,
                                            door d: Door) -> Bool {
        capNounSharesTheDoorsClause(NumberParser.ClauseIndex(text), state: state, door: d)
    }

    private static func capNounSharesTheDoorsClause(_ index: NumberParser.ClauseIndex,
                                                    state: PolicyState) -> Bool {
        let t = index.tokens
        return clauseRanges(index).contains { clause in
            guard doorIndex(in: clause, of: index, state: state) != nil else { return false }
            return clause.contains { capNouns.contains(t[$0]) }
        }
    }

    private static func capNounSharesTheDoorsClause(_ index: NumberParser.ClauseIndex,
                                                    state: PolicyState, door d: Door) -> Bool {
        let t = index.tokens
        return clauseRanges(index).contains { clause in
            guard clauseNames(d, in: clause, of: index, state: state) else { return false }
            return clause.contains { capNouns.contains(t[$0]) }
        }
    }

    // MARK: - Phrases looked for in the whole sentence

    /// A phrase this file hunts for inside the raw utterance, carried with its
    /// own bytes.
    ///
    /// The whole-sentence substring tests are the grammar's second-largest cost
    /// after the number reader, and almost every one of them is looking for
    /// something that is not there: `hasPlaceBinding` runs fourteen searches on
    /// every doorful sentence, `isStatusAsk` five on every sentence at all,
    /// and the answer is nearly always no. Foundation's search decides
    /// canonical equivalence — the right question, and an expensive one.
    ///
    /// So the NEGATIVE is settled first and cheaply, and the positive is not
    /// settled here at all. `utf8Contains` asks whether the phrase's bytes are
    /// present; every phrase below is ASCII, and an ASCII letter has no second
    /// canonical spelling, so bytes that are absent cannot match under any
    /// reading. When they ARE present the question goes to `contains` exactly
    /// as it always did. Nothing this file reads has changed; the sentences
    /// that were going to say no now say it without bridging a string.
    private struct Phrase {
        let text: String
        let bytes: [UInt8]
        init(_ text: String) {
            self.text = text
            self.bytes = Array(text.utf8)
        }
    }

    private static func says(_ text: String, _ phrase: Phrase) -> Bool {
        NumberParser.utf8Contains(text, phrase.bytes) && text.contains(phrase.text)
    }

    private static func saysAny(_ text: String, _ phrases: [Phrase]) -> Bool {
        phrases.contains { says(text, $0) }
    }

    // MARK: - Recognizers

    /// Internal rather than private so the invariant suite can ask the parser
    /// which sentences it considers closes, instead of restating the list and
    /// drifting from it — the same reason `isStart` asks `readsAsHour` rather
    /// than repeating the number reader's rules.
    static func hasClosingVerb(_ text: String) -> Bool {
        // Exactly two closer phrases embed an opener word, and only those may
        // outrank the opener veto: "stop letting me OPEN instagram" is a
        // close the veto must not see first. The rest stay behind the veto,
        // or "im done after this, give me ten of instagram" would close the
        // very door being asked for.
        if saysAny(text, openerEmbeddedClosers) { return true }

        // Openers win: "unlock instagram" contains the substring "lock",
        // which is precisely the silent polarity flip the research warned
        // about. Token-boundary matching only; never bare substring for verbs.
        let tokens = Set(NumberParser.tokenize(text))
        if !tokens.isDisjoint(with: openerTokens) { return false }
        if !tokens.isDisjoint(with: closerTokens) { return true }

        // "no more THAN ten" is a quantifier on an ask, not a close; the word
        // boundary keeps "no more thanksgiving football" a close.
        //
        // The regex runs only over a sentence that spells the quantifier. It
        // is a literal with a zero-width boundary on the end, so bytes it
        // cannot find are a match it cannot make, and a sentence without them
        // is left exactly as it stood — which is what the substitution would
        // have produced anyway, after building a regex and a second copy of
        // the string for every close-shaped sentence in the product.
        let phraseText = says(text, noMoreThan)
            ? text.replacingOccurrences(of: "no more than\\b", with: " ",
                                        options: .regularExpression)
            : text
        return saysAny(phraseText, closerPhrases)
    }

    /// The two closer phrases that embed an opener word, the token lists the
    /// opener veto and the close test read, and the phrases that close without
    /// a verb of their own. Every one of them used to be built from a literal
    /// on each call — four collections per sentence, on a function every
    /// sentence in the product reaches.
    private static let openerEmbeddedClosers: [Phrase] =
        ["stop letting", "stop opening"].map(Phrase.init)
    private static let openerTokens: Set<String> = ["unlock", "open", "give", "let"]
    private static let closerTokens: Set<String> = ["block", "close", "lock", "shut"]
    private static let closerPhrases: [Phrase] =
        ["no more", "im done", "i'm done", "done with", "cut off"].map(Phrase.init)
    private static let noMoreThan = Phrase("no more than")

    /// The stated hour of a close — whatever parses as a clock time after
    /// "until"/"till". Bare hours read as evenings ("until 9" is 9 PM): a close
    /// is a promise about the rest of today, and today's mornings are behind
    /// her. An explicit "9 am" still wins, exactly as it does for down hours —
    /// and so does a spelled half of the day: "until 6 in the morning" states
    /// its morning, and reading it as 18:00 would LIFT the close twelve hours
    /// early against the sentence's own words.
    private static func restUntil(in text: String) -> TimeOfDay? {
        for marker in [" until ", " till ", " til "] {
            guard let r = text.range(of: marker) else { continue }
            let rest = String(text[r.upperBound...])
            return NumberParser.timeOfDay(in: rest, assumeEvening: statedDayHalf(rest) ?? true)
        }
        return nil
    }

    private static func hasPlaceBinding(_ text: String) -> Bool {
        saysAny(text, placeBindings)
    }

    private static let placeBindings: [Phrase] = [
        "until i leave", "til i leave", "till i leave", "while im at", "while i'm at",
        "while im", "while i'm", "as long as im", "as long as i'm", "when im at", "when i'm at",
        "at the gym", "at work", "at the office",
    ].map(Phrase.init)

    /// THE OPENING VERBS. One authority, read by rule 2's window guard, by
    /// rule 8's elliptical ask, and — since the spend grammar was tightened —
    /// by the one point in this file that mints a grant.
    ///
    /// Words that mean "let me in". Without one of these a door and a number
    /// are a MENTION of an app and a quantity, not a request for either, and
    /// "instagram 10" no longer buys ten minutes of Instagram: it is answered
    /// with the sentence that would ("Write it out: unlock Instagram for 10
    /// min."). The grammar's whole hot path now hangs off this list, so it is
    /// written once here and nowhere else.
    ///
    /// TOKEN-BOUNDED, and that is not a detail. The old test was
    /// `text.contains("open")`, a substring over the raw utterance, which said
    /// yes to "opening", "reopen", "openly" and to the "i want" inside "hi
    /// wanted". A verb has to occupy whole tokens or the list quietly means
    /// something wider than it says, and this list now decides whether minutes
    /// leave the pool.
    ///
    /// The multi-word entries match CONSECUTIVE tokens, which is the same
    /// rule: "can i" is two tokens side by side, never "can" somewhere and "i"
    /// somewhere else.
    ///
    /// "give" stands alone as well as in "give me": "give tiktok 20 minutes"
    /// is the ordinary ditransitive ask and was refused while "gimme tiktok
    /// 20" granted. "using" is NOT here: on its own it is a participle, and
    /// the one frame in which it asks — "i'm using instagram for 5 minutes" —
    /// is read by `statesACommitment`, behind its guards, so that a bare
    /// "using instagram for 10 minutes" is answered with the sentence to
    /// write rather than minted by a list entry no guard stands on. "i'd
    /// like" is the polite ask in the three spellings the tokenizer produces.
    private static let openingVerbs: [String] = [
        "give me", "give", "gimme", "open", "let me", "lemme", "unlock",
        "i want", "i need", "can i", "could i", "may i",
        "i d like", "id like", "i would like",
        "spend", "use", "go on", "get on",
    ]

    /// The asks rule 2's window setter refuses to be: the frames that mean
    /// "let me in", and only those. Rule 2 guards "give me 20 minutes before
    /// bedtime" — a doorless ask that must not move the night — and it used
    /// to read `openingVerbs` for that, which was six phrases when the guard
    /// was written and is nineteen now. Every stem the tightening added is one
    /// a WINDOW sentence carries too: "i need down hours to start at 11",
    /// "i spend too long on my phone at night, bedtime at 10" — and the
    /// setter went quiet on all of them, reading the window back instead of
    /// moving it. So the guard keeps the list it was measured against.
    private static let askFrames: [String] = [
        "give me", "open", "let me", "unlock", "i want", "can i",
    ]
    private static let askFramePhrases: [[String]] =
        askFrames.map { $0.split(separator: " ").map(String.init) }
    private static let askFrameHeads: Set<String> = Set(askFramePhrases.compactMap(\.first))

    private static func hasAskFrame(_ tokens: [String]) -> Bool {
        carries(askFramePhrases, heads: askFrameHeads, in: tokens)
    }

    /// Whether the sentence asks for LESS of the app. A refusal-only list read
    /// by the two elliptical-ask rules: with an opening verb and a door and
    /// no number, "i need to use instagram less" is otherwise the shape of a
    /// request to be let in.
    private static func asksForLess(_ tokens: [String]) -> Bool {
        tokens.contains { lessWords.contains($0) }
    }

    /// EVERY CLOSING VERB IS ONE OF THESE, by meaning and not by coincidence: a
    /// verb that shuts the door is a request for less of the app, so the list
    /// is written as `closerTokens` plus the words that ask for less without
    /// closing anything. Spelled out twice it was two literals that happened to
    /// overlap on four words, and a closing verb added to one and forgotten in
    /// the other would leave a refusal reading as an ask.
    private static let lessWords: Set<String> = closerTokens.union([
        "less", "fewer", "cut", "reduce", "reduced", "limit", "limited", "lower", "stop", "quit",
        "blocked", "locked", "closed", "off", "away", "without",
        "capped", "restricted", "removed", "gone", "deleted", "cap", "ceiling",
    ])

    /// `openingVerbs`, cut into tokens once. The lookup below walks the
    /// sentence a single time, so a ten-thousand-word paste pays one set
    /// membership test per token and not nineteen substring searches.
    private static let openingVerbPhrases: [[String]] =
        openingVerbs.map { $0.split(separator: " ").map(String.init) }
    private static let openingVerbHeads: Set<String> =
        Set(openingVerbPhrases.compactMap(\.first))

    /// Whether the sentence carries an opening verb.
    ///
    /// Takes TOKENS and not text: `parse` has already tokenized, and a second
    /// tokenization here is both wasted work on the hot path and a second
    /// answer to "what are the words of this sentence" — the mistake this
    /// file's clause index exists to refuse.
    private static func hasOpeningVerb(_ tokens: [String]) -> Bool {
        carries(openingVerbPhrases, heads: openingVerbHeads, in: tokens, skippingNounReadings: true)
    }

    /// One walk over the tokens for a phrase list: `heads` says whether a
    /// token can start any phrase, and only then are the phrases beginning
    /// with it tried against the tokens that follow. `skippingNounReadings`
    /// is the receipt guard below, wanted by the opening verbs and by nothing
    /// else.
    private static func carries(_ phrases: [[String]], heads: Set<String>, in tokens: [String],
                                skippingNounReadings: Bool = false) -> Bool {
        for i in tokens.indices where heads.contains(tokens[i]) {
            if skippingNounReadings, nounReading(tokens, at: i) { continue }
            for phrase in phrases where phrase[0] == tokens[i] {
                guard i + phrase.count <= tokens.count else { continue }
                if (1..<phrase.count).allSatisfy({ tokens[i + $0] == phrase[$0] }) { return true }
            }
        }
        return false
    }

    /// The receipt guard, as a predicate on one position.
    private static func nounReading(_ tokens: [String], at i: Int) -> Bool {
        // "no" stands with the determiners here and not on their list: "no
        // use, instagram for 10" is a noun phrase, but "no" elsewhere in this
        // file is a negator, and the cap rules read the list.
        i > tokens.startIndex && ambiguousOpeningVerbs.contains(tokens[i])
            && (copulas.contains(tokens[i - 1]) || determiners.contains(tokens[i - 1])
                || tokens[i - 1] == "no")
    }

    /// The copula, in the spellings the tokenizer produces — "instagram's open
    /// for 10" reaches here as ["instagram", "s", "open"], because an
    /// apostrophe splits. Read ONLY by the guard above, where every entry can
    /// do one thing: take a word back off the opening-verb list, which is the
    /// direction that costs a sentence rather than a debit.
    private static let copulas: Set<String> = [
        "is", "isnt", "are", "arent", "was", "wasnt", "were", "werent",
        "am", "be", "been", "being", "s",
    ]

    /// The opening verbs that are also ordinary nouns and adjectives — "the
    /// open tab", "my instagram spend", "no use". The only entries the guard
    /// above may take back off the list, because they are the only ones whose
    /// second reading exists.
    private static let ambiguousOpeningVerbs: Set<String> = ["open", "use", "spend"]

    /// The opening verbs the user's own COMMITMENT conjugates, one row per
    /// verb: the progressive spelling, the base spelling, and whether the verb
    /// is phrasal. "im USING instagram for 5 minutes", "i'm GOING ON instagram
    /// for 10", "i'm SPENDING 10 on instagram", "i'll USE instagram for 10" are
    /// asks — she is telling Silk what she is about to do — and the mood gate
    /// silenced every one of them as a habit report.
    ///
    /// ONE TABLE AND NOT FOUR SETS. The gerunds, the stems, and the two
    /// particled subsets are four views of one six-row fact, and as four
    /// literals they could disagree: a verb added to the gerunds and forgotten
    /// in the stems reads the progressive sentence and drops the intention one,
    /// and a verb marked phrasal on one side and not the other loses its
    /// particle guard in exactly one mood. The rows state the fact once; the
    /// sets below are derived from it, and stay sets so the lookups inside the
    /// scan stay O(1).
    ///
    /// The gerunds are SPELLED OUT rather than derived from the stems, because
    /// English drops and doubles letters on the way to one (use → using, get →
    /// getting) and a derivation that gets one of those wrong is a grant that
    /// does not land.
    ///
    /// `particled` marks the verbs that mean the app only with their particle
    /// — "go on", "get on". "im going to bed" and "im getting instagram off my
    /// phone" are not asks.
    ///
    /// Read ONLY inside `statesACommitment`, whose frame is narrow enough that
    /// a row here cannot widen anything else.
    private static let commitmentVerbs: [(stem: String, gerund: String, particled: Bool)] = [
        (stem: "use",    gerund: "using",     particled: false),
        (stem: "spend",  gerund: "spending",  particled: false),
        (stem: "open",   gerund: "opening",   particled: false),
        (stem: "unlock", gerund: "unlocking", particled: false),
        (stem: "go",     gerund: "going",     particled: true),
        (stem: "get",    gerund: "getting",   particled: true),
    ]

    /// The four views `statesACommitment` actually asks, as sets: the scan runs
    /// once per token of the utterance, and a linear walk of the table there
    /// would put the paste path's cost back.
    private static let commitmentGerunds: Set<String> = Set(commitmentVerbs.map(\.gerund))
    private static let commitmentStems: Set<String> = Set(commitmentVerbs.map(\.stem))
    private static let particledGerunds: Set<String> =
        Set(commitmentVerbs.filter(\.particled).map(\.gerund))
    private static let particledStems: Set<String> =
        Set(commitmentVerbs.filter(\.particled).map(\.stem))

    /// THE USER'S OWN COMMITMENT — a first-person present-progressive sentence
    /// whose verb is an opening verb, carrying exactly one number and no
    /// period. "im using instagram for 5 minutes", "i'm going on instagram for
    /// 10", "i'm spending 10 on instagram".
    ///
    /// It is an ASK, and it reads as one nowhere else in this file: the
    /// sentence speaks its subject, which `reportsRatherThanSpends` reads as a
    /// report, and its verb is a gerund, which the same gate reads as a habit
    /// participle. Both are right about the shapes they were written for ("i
    /// was on instagram for 20 minutes", "spent 45 minutes on tiktok ugh") and
    /// both are wrong about this one, because a person announcing what she is
    /// about to do is asking for it.
    ///
    /// Read TWICE, and the same answer both times: once to stand the mood gate
    /// down, and once at the mint, where "im using instagram for 5 minutes"
    /// has to count as carrying an opening verb even though its verb is spelled
    /// "using" and its particle-taking siblings are spelled "going on".
    ///
    /// Four guards, and each one is a sentence that must stay silent:
    ///
    ///  - FIRST PERSON PRESENT. "i'm"/"im"/"i am", and nothing else. "i've
    ///    been using tiktok for 3 hours" reports three hours already spent;
    ///    "she was using instagram for 20 minutes" is somebody else's day.
    ///  - THE PARTICLE, AND ITS OBJECT. "going"/"getting" need their "on", and
    ///    the "on" needs the DOOR standing on it. "go on" is only the phrasal
    ///    verb that means the app when the app is what follows it: "im going
    ///    ON ABOUT instagram for 10 minutes" is complaining about the app and
    ///    granted ten minutes of it, and "i'm going on the tiktok train for 10
    ///    minutes" granted ten of TikTok off an idiom. The particle test read
    ///    the particle and never the object.
    ///  - NOT A PERIOD. "i'm using instagram 2 hours a day" is a habit, and a
    ///    habit is rule 3's sentence, never a grant.
    ///  - NOT ANOTHER TIME. A commitment is a commitment to NOW — that is the
    ///    whole of why it counts as an ask. "i'm going on instagram for 10
    ///    minutes tomorrow" states a plan, and minting it opens the door and
    ///    debits the pool today for minutes the sentence placed elsewhere.
    ///  - NOBODY ELSE'S SENTENCE. A speech verb ahead of the frame reports it:
    ///    "she said i'm using instagram for 10 minutes". The quoted-speech arm
    ///    above was supposed to have caught this before the exemption was ever
    ///    consulted, and it catches "she said i AM using…" — its proof is a
    ///    non-modal auxiliary in the clause, and the contraction's "m" is not
    ///    one, so the ordinary spelling walked straight through it.
    ///  - EXACTLY ONE NUMBER. Two numbers is the ambiguity `parse`'s `number`
    ///    binding has refused since the parser shipped (`numbers.count == 1`,
    ///    else nil), asked here so the exemption cannot launder it.
    ///
    /// The exactly-one-number guard is the CALLER'S: rule 7 binds `number`
    /// before it asks, and this is read from nowhere else, so the sentence's
    /// numbers are not counted a second time here.
    ///
    /// TWO FRAMES, one shape. The present progressive — "i'm USING", "i'm
    /// GOING ON" — and the intention — "i'll USE", "i will SPEND", "i'm
    /// going to GO ON", "i'm gonna OPEN". The intention frame is the sentence
    /// a person types when she is promising rather than announcing, and it
    /// was silent: `will` is a modal the report gate reads as commentary, and
    /// the widener, asked, did not read it either. The verb after the frame
    /// has to be a base opening verb, directly — "i'll never use", "i won't
    /// open" put a negator or a contraction where the verb must stand, and
    /// stay reports.
    ///
    /// EVERY candidate position is tried, not the first: "im getting ready,
    /// im going on instagram for 10 minutes" has a gerund that fails the
    /// particle guard before the one that passes it.
    private static func statesACommitment(_ index: NumberParser.ClauseIndex,
                                          state: PolicyState) -> Bool {
        let t = index.tokens
        for j in t.indices {
            let gerund = commitmentGerunds.contains(t[j]) && firstPersonPresent(t, before: j)
            let intention = commitmentStems.contains(t[j]) && firstPersonIntention(t, before: j)
            guard gerund || intention,
                  let clause = index.clauseRange(containing: j),
                  !aboutAPeriod(t, clause: clause),
                  !clause.contains(where: { laterMarkers.contains(t[$0]) }),
                  !(clause.lowerBound..<j).contains(where: { speechVerbs.contains(t[$0]) }),
                  !aLaterClauseRetractsIt(index, after: clause)
            else { continue }
            if particledGerunds.contains(t[j]) || particledStems.contains(t[j]) {
                // The particle has to govern the DOOR. The question here is not
                // "does the sentence name a door" — rule 7 already holds one —
                // but "is the door what this 'on' points at", so the door's
                // name must begin on the token right after it. The whole
                // utterance is the bound: a commitment's particle and its
                // object are one breath by construction, and `t.count` is what
                // `doorAt` needs to know the token exists at all.
                guard j + 1 < t.count, t[j + 1] == "on",
                      doorAt(t, j + 2, within: t.count, state: state) != nil else { continue }
            }
            return true
        }
        return false
    }

    /// Whether a LATER clause takes the intention back. "i'll use instagram
    /// for 10 minutes, no i wont" states an intention and then withdraws it in
    /// the next breath, and the frame minted the ten minutes anyway — the door
    /// opened and the pool was debited for a plan the sentence itself cancels.
    /// Without the frame that sentence is a report (its subject is spoken and
    /// "use" is no ask verb) and was silent; the intention frame is what made
    /// it a grant, so the retraction is this widening's own to refuse.
    ///
    /// THE SHAPE IS `aLaterClauseDeclinesTheAsk`'S, one family over: a clause
    /// standing AFTER the frame's own, which must CONTAIN a negation or a
    /// spoken decline and may carry nothing else beyond that vocabulary, the
    /// transparent `answerSlotAdverbs`, and the first-person words a person
    /// takes an intention back with ("no i wont", "no wait", "nah", "actually
    /// no", "nvm"). Anything else in the clause is a second thought about
    /// something other than the ask — "i'll use instagram for 10 minutes, not
    /// tiktok" names the door it does mean and still spends, and "…, no more
    /// than that" bounds the ask rather than cancelling it.
    ///
    /// SCOPED TO THE INTENTION, exactly as the cap family scopes its own
    /// veto to a clause carrying a request modal: a plain imperative is not
    /// retracted by a trailing decline, so "unlock instagram for 10 min, no"
    /// and "give me 10 minutes of instagram, no i wont" keep granting. What
    /// can be taken back is what was only ever promised.
    ///
    /// Read ONLY from `statesACommitment`'s guard chain, so a word seated in
    /// the filler set can do exactly one thing: turn a commitment-framed grant
    /// into the silence it was before the frame existed.
    /// AND A COMMA IS NOT A RULE. "i'll use instagram for 10 minutes no i
    /// wont" is the same sentence typed without the pause, and a veto that
    /// reads only whole clauses would leave it granting — the punctuation
    /// dependency `door(_:in:)` already records paying for once. So the same
    /// vocabulary is read a second way: as the TRAILING RUN of the frame's own
    /// clause. The run is taken from the end backwards and stops at the first
    /// word that is not retraction vocabulary, so it can never reach past the
    /// ask it is cancelling ("…for 10 minutes no more" stops on "more",
    /// "…and no i wont stop" stops on "stop").
    private static func aLaterClauseRetractsIt(_ index: NumberParser.ClauseIndex,
                                               after clause: Range<Int>) -> Bool {
        let t = index.tokens
        if clauseRanges(index).contains(where: { later in
            later.lowerBound >= clause.upperBound && isARetraction(t, later)
        }) { return true }
        var start = clause.upperBound
        while start > clause.lowerBound, isARetractionWord(t[start - 1]) { start -= 1 }
        return start < clause.upperBound && isARetraction(t, start..<clause.upperBound)
    }

    private static func isARetraction(_ t: [String], _ range: Range<Int>) -> Bool {
        range.contains { negators.contains(t[$0]) || spokenDeclines.contains(t[$0]) }
            && range.allSatisfy { isARetractionWord(t[$0]) }
    }

    private static func isARetractionWord(_ w: String) -> Bool {
        negators.contains(w) || spokenDeclines.contains(w)
            || answerSlotAdverbs.contains(w) || retractionWords.contains(w)
    }

    /// The words a retraction carries besides its own negation: the speaker,
    /// the contractions the tokenizer splits off her ("i'll" is ["i", "ll"]),
    /// the intention's own tail, and the two words English cancels with
    /// ("wait", "mind"). Read only by the scan above, where an entry admits
    /// one more clause as a retraction and can therefore only subtract a
    /// grant.
    private static let retractionWords: Set<String> = [
        "i", "im", "m", "ill", "ll", "id", "d", "ive", "ve", "am",
        "gonna", "going", "to", "wait", "mind",
    ]

    /// The first-person intention frame standing directly on `j`: "i'll" /
    /// "ill" / "i will" / "i'm going to" / "im going to" / "i am going to" /
    /// "i'm gonna" / "im gonna". Contractions arrive split ("i'll" is
    /// ["i", "ll"]) or whole ("ill", which the tokenizer cannot tell from the
    /// adjective, and reads as the frame only when a commitment verb stands
    /// right after it).
    private static func firstPersonIntention(_ t: [String], before j: Int) -> Bool {
        guard j > 0 else { return false }
        if t[j - 1] == "ill" { return true }
        if j > 1, t[j - 2] == "i", t[j - 1] == "ll" || t[j - 1] == "will" { return true }
        if j > 1, t[j - 2] == "im", t[j - 1] == "gonna" { return true }
        if j > 2, t[j - 3] == "i", t[j - 2] == "m", t[j - 1] == "gonna" { return true }
        // "going to" is the present progressive of "go" with an infinitive
        // hanging off it, so the frame in front of it is the ordinary
        // first-person present — the same three spellings `firstPersonPresent`
        // already reads, asked at the "going". Spelling them out a second time
        // here is how "i am going to" and "i'm going to" came to be answered by
        // two pieces of code that could drift apart.
        //
        // The "gonna" arms above stay separate on purpose: they admit "im
        // gonna" and "i'm gonna" and NOT "i am gonna", which is not English
        // anyone types, and folding them into this call would newly claim it.
        guard j > 2, t[j - 2] == "going", t[j - 1] == "to" else { return false }
        return firstPersonPresent(t, before: j - 2)
    }

    /// "i'd" as the tokenizer spells it: the clitic "d" standing on "i", or
    /// the bare "id" a thumb types without the apostrophe.
    ///
    /// AND "ID" IS ALSO A NOUN. The bare spelling was read as the modal
    /// wherever it stood, and the request-modal exemption it buys is the one
    /// thing standing between an ordinary REPORT and rule 7's mint: "my id is
    /// 250, open instagram" handed the identity document's number to the ask
    /// beside it and granted 250 minutes — the whole day's pool and an open
    /// door — where "my code is 250, open instagram" is correctly silent.
    ///
    /// The test is the one `nounReading` already makes for "open", "use" and
    /// "spend": a determiner standing on the word makes it a noun. Two more
    /// closed-class tells come with it, because "i would" can be followed by
    /// neither — a finite auxiliary ("my id IS 250") and a number ("id 250").
    /// Each is a refusal only, so a spelling nobody thought of leaves the
    /// exemption exactly where it was.
    ///
    /// The apostrophe spelling keeps its unconditional reading: "i'd is 250"
    /// is not English, and the two spellings must compile alike wherever both
    /// are English — which is why the counterfactual "i'd use instagram for 10
    /// minutes if i could" still grants, exactly as "i would use…" does. That
    /// hole belongs to `requestModals` and to the conditional mood, not to the
    /// clitic.
    private static func contractedWould(_ t: [String], at i: Int) -> Bool {
        if t[i] == "d" { return i > 0 && t[i - 1] == "i" }
        guard t[i] == "id" else { return false }
        if i > t.startIndex,
           determiners.contains(t[i - 1]) || possessiveDeterminers.contains(t[i - 1]) {
            return false
        }
        guard i + 1 < t.count else { return true }
        return !auxiliaries.contains(t[i + 1]) && !NumberParser.readsAsNumber(t[i + 1])
    }

    /// The possessives `determiners` does not carry — that set is read by the
    /// cap family's phrase scans, where a word added changes what counts as a
    /// ceiling's own noun phrase, and these have no business there. Read only
    /// by the noun test above, and only to REFUSE an exemption.
    private static let possessiveDeterminers: Set<String> = ["your", "his", "her", "their", "its"]

    /// The words that place a clause somewhere other than now. Read ONLY to
    /// REFUSE the commitment exemption, beside `aboutAPeriod` and for the same
    /// reason: a word nobody thought of costs a sentence, never a debit.
    private static let laterMarkers: Set<String> = [
        "tomorrow", "tmrw", "tmw", "tonight", "later", "afterwards",
    ]

    /// The first-person present frame standing directly on `j`. Three
    /// spellings and one shape: "im" is one token, "i'm" tokenizes as
    /// ["i", "m"] (an apostrophe splits — NumberParser.foldingApostrophes),
    /// and "i am" is the uncontracted form.
    private static func firstPersonPresent(_ t: [String], before j: Int) -> Bool {
        guard j > 0 else { return false }
        if t[j - 1] == "im" { return true }
        guard j > 1, t[j - 2] == "i" else { return false }
        return t[j - 1] == "m" || t[j - 1] == "am"
    }

    /// Whether the clause is about a PERIOD rather than about now — rule 3's
    /// own question, asked over tokens because that is the shape this gate
    /// has. `periodPhrase` is the shared reader ("a day", "per day", "daily");
    /// the adverbs and the "every/each/these + day/week" frames beside it are
    /// the habitual spellings it does not carry.
    ///
    /// Read ONLY to REFUSE the commitment exemption above, so every entry can
    /// do one thing: turn a grant back into the silence it was before. A word
    /// nobody thought of costs a sentence, never a debit.
    private static func aboutAPeriod(_ t: [String], clause: Range<Int>) -> Bool {
        if periodPhrase(t, in: clause) { return true }
        return clause.contains { i in
            if habitAdverbs.contains(t[i]) { return true }
            guard i > clause.lowerBound, periodNouns.contains(t[i]) else { return false }
            return periodDeterminers.contains(t[i - 1])
        }
    }

    /// Whether the clause OPENS with one of the authority's inversions — "can
    /// i", "could i", "may i", the shape English fronts a modal to ask with.
    ///
    /// Read only by the spend gate, and only to let an ask through. That gate
    /// reads a fronted auxiliary as a question ("a question is never a grant")
    /// and it is right about every fronted auxiliary but these: two of the
    /// three escaped it only because their modals sit on `requestModals` and
    /// that exemption fires first, while "may" was deliberately left off
    /// `requestModals` as an epistemic ("i MUST have capped tiktok at 60").
    /// So "may i have 10 minutes of instagram" — a request this file's own
    /// opening-verb list NAMES — was the one spelling of the ask the gate
    /// could not see.
    ///
    /// Read off `openingVerbs` rather than off a modal test, which is what
    /// keeps it narrow: the only two-token opening verbs with a pronoun in
    /// second position are those three inversions.
    private static func anInversionOpensTheClause(_ t: [String], clause: Range<Int>) -> Bool {
        let i = clause.lowerBound
        guard i + 1 < clause.upperBound else { return false }
        return openingVerbPhrases.contains {
            $0.count == 2 && $0[0] == t[i] && $0[1] == t[i + 1] && subjects.contains($0[1])
        }
    }

    private static let habitAdverbs: Set<String> = [
        "usually", "always", "normally", "typically", "everyday", "weekly",
    ]
    private static let periodNouns: Set<String> = ["day", "days", "week", "weeks"]
    private static let periodDeterminers: Set<String> = ["a", "per", "every", "each", "these"]

    private static func isStatusAsk(_ text: String, hasDoor: Bool) -> Bool {
        // The bare word is the design's first listed example, and "left today"
        // its fourth. (docs/design/handoff/Silk Mockup.dc.html:318) The word
        // matches as a token so "status?" and "check status" read too — but
        // only doorless: "block instagram and give me my status" must not
        // swallow the close into a balance readback.
        if !hasDoor, NumberParser.tokenize(text).contains("status") { return true }
        if says(text, leftToday) { return true }
        return saysAny(text, statusAsks)
    }

    private static let leftToday = Phrase("left today")
    private static let statusAsks: [Phrase] =
        ["how many", "how much", "whats left", "what's left", "balance"].map(Phrase.init)

    /// Which edge of the window a stated time belongs to: "down hours start at
    /// ten" vs "…end at seven"/"…till seven".
    ///
    /// The markers match as whole words for the reason the closing verbs do —
    /// "end" lives inside "weekend", and the substring test heard "down hours
    /// start at 10 on weekends" as a 10 AM end, a twelve-hour night that lands
    /// instantly because a longer window tightens. Missing a marker costs the
    /// same in reverse: "till" was absent, so "down hours till 7" became a 7 PM
    /// start. Whole words are only safe if the set is complete, so every
    /// inflection the substring caught for free is spelled out; a dropped word
    /// hands the time to the wrong edge, and both directions of that mistake
    /// buy hours of lockdown under a reply that never mentions the window.
    private static func isStart(_ text: String) -> Bool {
        let tokens = NumberParser.tokenize(text)
        let startWords: Set<String> = ["start", "starts", "started", "starting"]
        let endWords: Set<String> = ["end", "ends", "ended", "ending",
                                     "finish", "finishes", "finished", "finishing",
                                     "until", "untill", "till", "til"]
        // The setter moves one edge and the reader takes one time — the first
        // one in the sentence — so the word that owns it is the last marker
        // BEFORE it, not the first in the sentence. "until further notice down
        // hours start at 11" opens with an end marker governing no hour, and
        // letting that win reads the 11 as a morning end: a thirteen-hour
        // night, instant, from a sentence whose only slot word said "start".
        let statedTime = tokens.firstIndex(where: readsAsHour) ?? tokens.endIndex
        guard let slot = tokens[..<statedTime].lastIndex(where: {
            startWords.contains($0) || endWords.contains($0)
        }) else { return true }
        return startWords.contains(tokens[slot])
    }

    /// Whether the clause holding the sentence's stated hour is itself about
    /// the window — rule 2's setter gate. The setter fires on a window word
    /// ANYWHERE plus an hour ANYWHERE, and those are two different places in
    /// ordinary prose: the gate requires the window's own name in the HOUR'S
    /// clause, and no spoken subject standing ahead of the hour (a clause with
    /// a subject is describing somebody's evening, not instructing Silk's —
    /// "i was quiet at work until 4" moves nothing). The one command that
    /// speaks its subject keeps its exemption: "i want my bedtime at 10" is a
    /// volition.
    ///
    /// The hour is located with `readsAsHour` — the same question `isStart`
    /// asks — so the gate and the setter cannot disagree about which token is
    /// the stated time.
    private static func windowOwnsTheStatedHour(_ index: NumberParser.ClauseIndex) -> Bool {
        let t = index.tokens
        guard let hourAt = t.indices.first(where: { readsAsHour(t[$0]) }),
              let clause = index.clauseRange(containing: hourAt) else { return false }
        let mentionsWindow = clause.contains { i in
            t[i] == "bedtime" || t[i] == "quiet" || t[i] == "night"
                || (t[i] == "down" && i + 1 < clause.upperBound && t[i + 1].hasPrefix("hour"))
        }
        guard mentionsWindow else { return false }
        if statesAVolition(t, clause: clause) { return true }
        // AN INTENSIFIER'S "so" OPENS NO FRESH BREATH. The clause splitter
        // cuts at "so" for what a purpose clause prevents (NumberParser's
        // clauseOpeners disclose the cost), and the cut strands "was so quiet
        // at 3 in the morning" as a subject-less clause the scan below cannot
        // refuse — the "it was" that owns it stands on the far side of the
        // boundary. When the token directly before the boundary is a copula
        // or linking verb ("it WAS so quiet", "it GETS so quiet", "the house
        // GOT so quiet"), the "so" is a degree word and this clause is that
        // verb's own predicate: a description of somebody's night, never an
        // instruction to Silk's — the description in the previous clause owns
        // this one. The subject/past-auxiliary refusal scan is extended
        // across the boundary by construction: the licensing verb IS the
        // finite verb such a scan exists to find, so the answer is foregone
        // and stated directly. A discourse "so" ("ok so bedtime at 10") has
        // no copula in front of it and still sets.
        if t[clause.lowerBound] == "so", clause.lowerBound > 0,
           intensifierHosts.contains(t[clause.lowerBound - 1]) {
            return false
        }
        return !(clause.lowerBound..<hourAt).contains { i in
            // A subject describes somebody's evening; a PAST-tense auxiliary
            // describes a former one ("bedtime WAS 9 when i was a kid" must
            // not tighten tonight's, while the pinned "bedtime IS 10 tonight"
            // still sets); and a participle that is not one of the window's
            // own edge markers is the same recollection ("my bedtime USED to
            // be 10" — "starting"/"ending" stay commands).
            subjects.contains(t[i]) || pastAuxiliaries.contains(t[i])
                || (isHabitParticiple(t[i]) && !t[i].hasPrefix("start")
                    && !t[i].hasPrefix("end") && !t[i].hasPrefix("finish"))
        }
    }

    /// The auxiliaries that put a clause in the past — the tense that turns a
    /// window sentence into a recollection. A subset of `auxiliaries` so the
    /// two lists cannot disagree about what a word is.
    private static let pastAuxiliaries: Set<String> = [
        "was", "wasnt", "wasn't", "were", "werent", "weren't",
        "had", "hadnt", "hadn't", "did", "didnt", "didn't", "been",
    ]

    /// The copulas and linking verbs that host an intensifier "so" — the word
    /// standing directly before the "so" boundary when "so quiet" is a degree
    /// phrase rather than a purpose clause. Read only by the window gate above,
    /// and only to REFUSE a setter, so an entry can never move an edge; a wrong
    /// entry costs a silence that falls to the query arms, which read the
    /// window back. "s" is the contracted copula the tokenizer orphans from
    /// "it's"; the negative contractions ride along because "it wasnt so quiet
    /// at 3" is the same recollection with the polarity flipped.
    private static let intensifierHosts: Set<String> = [
        "is", "isnt", "isn't", "was", "wasnt", "wasn't",
        "are", "arent", "aren't", "were", "werent", "weren't",
        "am", "be", "been", "being", "s",
        // The subject+copula contractions the tokenizer leaves whole when
        // typed without their apostrophe: "its so quiet at 3".
        "its", "thats", "im", "hes", "shes", "youre", "theyre",
        "get", "gets", "got", "getting", "gotten",
        "feel", "feels", "felt", "feeling",
        "seem", "seems", "seemed", "sound", "sounds", "sounded",
        "look", "looks", "looked", "stay", "stays", "stayed",
        "goes", "went", "grew", "turned",
    ]

    /// A spelled half of the day STANDING ON AN HOUR, or nil when the sentence
    /// ties none to one. "at 3 in the morning" states its meridiem as surely
    /// as "3 am" does, and the evening assumption — a guess that exists only
    /// for hours that named no half — must never override it. true is the
    /// evening half, false the morning, matching the `assumeEvening` flag
    /// this feeds.
    ///
    /// THE PHRASE MUST FOLLOW THE HOUR IT NAMES, which is why this reads
    /// tokens rather than testing a substring anywhere in the sentence. A
    /// substring test tied "bedtime at 10, i walked in the morning" to the
    /// 10 — a 10 AM start, a twenty-one-hour night, out of a remark about a
    /// walk. English puts the phrase directly after its hour ("3 in the
    /// morning", "half past 9 in the morning"), so the tie is adjacency:
    /// the token before the phrase must itself read as a clock hour.
    private static func statedDayHalf(_ text: String) -> Bool? {
        let t = NumberParser.tokenize(text)
        for i in t.indices where i > 0 && readsAsHour(t[i - 1]) {
            if t[i] == "in", i + 2 < t.count, t[i + 1] == "the" {
                if t[i + 2].hasPrefix("morning") { return false }
                if t[i + 2].hasPrefix("afternoon") || t[i + 2].hasPrefix("evening") {
                    return true
                }
            }
            if t[i] == "at", i + 1 < t.count, t[i + 1] == "night" { return true }
        }
        return nil
    }

    /// Whether a token is one NumberParser would read as a clock hour. isStart
    /// asks the reader itself instead of restating its rules, because the two
    /// have to agree on which time is the stated one — disagree, and the marker
    /// chosen governs a different hour than the one that lands.
    private static func readsAsHour(_ token: String) -> Bool {
        NumberParser.timeOfDay(in: token, assumeEvening: false) != nil
    }

    private static func strip(_ text: String, of phrase: String) -> String {
        text.replacingOccurrences(of: phrase, with: " ")
    }
}
