// The Round-3 conversation-reality corpus, authored in the August 2026
// campaign. This Swift file is the source
// of truth — the JSON corpus and generator script it was first mechanized
// from were never checked in. Edit rows in place.
// Rows reuse the FuzzCorpusRow struct declared in FuzzCorpusR1Data.swift and
// are interpreted at test runtime by the runner in FuzzCorpusR2.swift.
import Foundation

enum FuzzCorpusR3Data {

    static let rows_conversation: [FuzzCorpusRow] = [
        FuzzCorpusRow(source: "conversation", index: 0, utterance: "ok so i just got home and i want to relax can i get twenty minutes of youtube before dinner", stateSpec: nil, expect: "VERDICT GRANT door=youtube minutes=20"),
        FuzzCorpusRow(source: "conversation", index: 1, utterance: "hey silk its been a rough day gimme fifteen minutes of insta and then ill stop i promise", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 2, utterance: "not gonna lie i already doomscrolled all morning but give me fifteen of tiktok anyway", stateSpec: nil, expect: "VERDICT GRANT door=tiktok minutes=15"),
        FuzzCorpusRow(source: "conversation", index: 3, utterance: "so anyway long story short i need like 10 minutes of insta to check something", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 4, utterance: "i know i said i was done earlier but tiktok for ten please", stateSpec: nil, expect: "VERDICT WRITE_IT_OUT door=tiktok minutes=10"),
        FuzzCorpusRow(source: "conversation", index: 5, utterance: "give me 20 of tiktok and cap it at 30 and close instagram", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 6, utterance: "give me 20 of tiktok, cap instagram at 30, close youtube", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 7, utterance: "cap tiktok at 20, close instagram", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 8, utterance: "ok twenty of tiktok then cap it at twenty and close insta after dinner", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 9, utterance: "im done with tiktok, give me reddit for 15", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 10, utterance: "im done with tiktok give me reddit for 15", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 11, utterance: "shut youtube until 9 and then bedtime at 10", stateSpec: nil, expect: "VERDICT CLOSE door=youtube until=21:00"),
        FuzzCorpusRow(source: "conversation", index: 12, utterance: "bedtime at 10 and no more tiktok tonight", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 13, utterance: "block youtube and set my budget to 30 a day", stateSpec: nil, expect: "VERDICT CLOSE door=youtube until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 14, utterance: "give me ten of insta then close it after", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 15, utterance: "give me 20 of tiktok no wait instagram", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 16, utterance: "give me 20 of tiktok, no wait, instagram", stateSpec: nil, expect: "VERDICT GRANT door=tiktok minutes=20"),
        FuzzCorpusRow(source: "conversation", index: 17, utterance: "instagram for ten actually make it twenty", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 18, utterance: "cap tiktok at 20 actually no 15", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 19, utterance: "cap tiktok at 15 no wait just close it", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 20, utterance: "close tiktok no wait just cap it at 15", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 21, utterance: "block tiktok wait no dont", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 22, utterance: "close tiktok actually no keep it open", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 23, utterance: "actually make it 45 a day", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=loosen budget=45"),
        FuzzCorpusRow(source: "conversation", index: 24, utterance: "lets try 35 a day and see how it goes", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten budget=35"),
        FuzzCorpusRow(source: "conversation", index: 25, utterance: "hi could you please give me twenty minutes of instagram thank you so much", stateSpec: nil, expect: "VERDICT GRANT door=instagram minutes=20"),
        FuzzCorpusRow(source: "conversation", index: 26, utterance: "hello silk please close tiktok for the rest of the day thanks bye", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 27, utterance: "would you kindly cap youtube at 25 please and thank you", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten cap[youtube]=25"),
        FuzzCorpusRow(source: "conversation", index: 28, utterance: "reddit ten ok bye love you", stateSpec: nil, expect: "VERDICT WRITE_IT_OUT door=reddit minutes=10"),
        FuzzCorpusRow(source: "conversation", index: 29, utterance: "ok done with insta for tonight goodnight", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 30, utterance: "good night silk close everything", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 31, utterance: "thats all for today thanks silk", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 32, utterance: "ok im done for today", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 33, utterance: "im done with everything today", stateSpec: nil, expect: "VERDICT CLOSE_ALL until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 34, utterance: "sorry to bother you but how much time is left", stateSpec: "state: spent={youtube:30}", expect: "VERDICT STATUS remaining=10"),
        FuzzCorpusRow(source: "conversation", index: 35, utterance: "how much do i have left", stateSpec: nil, expect: "VERDICT STATUS remaining=40"),
        FuzzCorpusRow(source: "conversation", index: 36, utterance: "is tiktok closed", stateSpec: "state: closed={tiktok}", expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 37, utterance: "did you close tiktok", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 38, utterance: "do i have any time left today", stateSpec: nil, expect: "VERDICT STATUS remaining=40"),
        FuzzCorpusRow(source: "conversation", index: 39, utterance: "hey whats left on tiktok today", stateSpec: "state: spent={tiktok:12}", expect: "VERDICT STATUS remaining=28"),
        FuzzCorpusRow(source: "conversation", index: 40, utterance: "how much of my budget is left", stateSpec: "state: spent={reddit:10}", expect: "VERDICT STATUS remaining=30"),
        FuzzCorpusRow(source: "conversation", index: 41, utterance: "how many minutes do i get on tiktok", stateSpec: nil, expect: "VERDICT STATUS remaining=40"),
        FuzzCorpusRow(source: "conversation", index: 42, utterance: "is my cap on tiktok still 10", stateSpec: "state: caps={tiktok:10}", expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 43, utterance: "hey quick question is there still a cap on tiktok", stateSpec: "state: caps={tiktok:10}", expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 44, utterance: "is tiktok capped", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 45, utterance: "how long until my down hours", stateSpec: nil, expect: "VERDICT DOWN_HOURS 22:00-7:00"),
        FuzzCorpusRow(source: "conversation", index: 46, utterance: "when does my bedtime start again", stateSpec: nil, expect: "VERDICT DOWN_HOURS 22:00-7:00"),
        FuzzCorpusRow(source: "conversation", index: 47, utterance: "do my down hours still start at 9", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten downStart=21:00"),
        FuzzCorpusRow(source: "conversation", index: 48, utterance: "how much is left and can i have ten of reddit", stateSpec: nil, expect: "VERDICT STATUS remaining=40"),
        FuzzCorpusRow(source: "conversation", index: 49, utterance: "am i out of time", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 50, utterance: "did i already use my forty minutes", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 51, utterance: "dont give me tiktok", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 52, utterance: "whatever you do do not open instagram tonight", stateSpec: nil, expect: "VERDICT SILENCE"),
        FuzzCorpusRow(source: "conversation", index: 53, utterance: "i dont want tiktok today", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 54, utterance: "no tiktok for me today", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 55, utterance: "please dont block instagram", stateSpec: nil, expect: "VERDICT CLOSE door=instagram until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 56, utterance: "dont cap tiktok", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 57, utterance: "i dont think you should cap tiktok at 20", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 58, utterance: "dont give me more than 10 of tiktok", stateSpec: nil, expect: "VERDICT GRANT door=tiktok minutes=10"),
        FuzzCorpusRow(source: "conversation", index: 59, utterance: "seriously no more reddit today i mean it", stateSpec: nil, expect: "VERDICT CLOSE door=reddit until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 60, utterance: "my friend said give me an hour", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        // ROUND 3 (D5): a quoted ask is not an ask. The frame — "my friend
        // said" — stands in front of the ask's own verb in the ask's own
        // breath, and the door being inside the quote does not make the
        // quote the user's sentence. Re-pinned to the silence its doorless
        // twin above already had, not dropped.
        FuzzCorpusRow(source: "conversation", index: 61, utterance: "my friend said give me an hour of tiktok", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 62, utterance: "my mom says i should block tiktok", stateSpec: nil, expect: "VERDICT CLOSE door=tiktok until=day-boundary"),
        FuzzCorpusRow(source: "conversation", index: 63, utterance: "shes always telling me to limit tiktok to 20", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten cap[tiktok]=20"),
        FuzzCorpusRow(source: "conversation", index: 64, utterance: "everyone says i should cap tiktok at 20", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten cap[tiktok]=20"),
        FuzzCorpusRow(source: "conversation", index: 65, utterance: "my therapist thinks a limit on instagram would help", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        // A reported refusal is not an ask, and this row pinned it granting NINE
        // MINUTES of the app being refused — the clock hour read as a duration,
        // out of a sentence whose only verb belongs to somebody else. SPEND now
        // declines a door with a negator standing on it, so the sentence goes to
        // the widener, which is the same answer conversation#54 already gets for
        // the same shape.
        FuzzCorpusRow(source: "conversation", index: 66, utterance: "my mom said no tiktok after 9", stateSpec: nil, expect: "PARSE UNPARSED-to-widener"),
        FuzzCorpusRow(source: "conversation", index: 67, utterance: "i told my friends id do 30 a day", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten budget=30"),
        FuzzCorpusRow(source: "conversation", index: 68, utterance: "put a cap on tiktok maybe 25 i think", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=tighten cap[tiktok]=25"),
        FuzzCorpusRow(source: "conversation", index: 69, utterance: "put it back to 40 a day please", stateSpec: nil, expect: "VERDICT RULE_CHANGE polarity=unchanged budget=40"),
    ]

    static let rows: [FuzzCorpusRow] = rows_conversation
}
