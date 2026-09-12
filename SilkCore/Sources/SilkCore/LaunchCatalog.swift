import Foundation

/// The curated door catalogue: name → how to open it. Keyed on the word the
/// user chose, never on Apple's opaque token — that inversion is what makes
/// "and it opens" possible at all.
///
/// THE DATA IS HERE AND THE OPENING IS NOT. `LaunchCatalog.open(doorName:)`
/// lives in the app target beside `UIApplication`; everything above it — the
/// display names, the spoken names, the scheme and the link — is plain data and
/// lives in the spine. The split is not tidiness. This file states the
/// invariants that turn "and it opens" from a courtesy into a guarantee: a
/// display name whose lowercased form is missing from `names` is a chip that
/// cannot be tapped into a door; an entry with neither scheme nor link is a
/// door that opens nothing; one name on two entries is a word that means two
/// apps; a name the tokenizer would split, or one carrying a capital, is a name
/// the parser can never match; and a scheme or link `URL(string:)` refuses is a
/// way in that fails before it reaches iOS. Every one of those compiles. While
/// the catalogue imported UIKit no headless suite could see it, so none of them
/// could be asserted — see `LaunchCatalogTests`, which now asserts all five in
/// the same three seconds as the parser.
///
/// DISPLAY NAMES ARE THE ONE DELIBERATE EXCEPTION to "everything the app says
/// comes from Strings.swift". A brand name is user data, not Silk's voice:
/// Silk does not choose it, does not translate it, and would be wrong to. The
/// rule's edge is written down here rather than left implicit, because a chip
/// reading "Instagram" is the one string on screen that Strings.swift will
/// never own.
///
/// From Silk's own foreground, `UIApplication.open` takes custom schemes and is
/// explicitly NOT constrained by LSApplicationQueriesSchemes — Silk never calls
/// `canOpenURL`, so the app's Info.plist needs no entry for any name below.
///
/// THE FALLBACK IS NARROWER THAN IT LOOKS, and this is the sentence to read
/// before adding an entry. `open` sends the universal link with
/// `[.universalLinksOnly: true]`, so iOS matches the URL against the domain's
/// apple-app-site-association components and opens NOTHING when the path is
/// unmatched. A root URL is therefore only a fallback if the domain's AASA
/// actually covers "/" — for some brands it does, for others the root is
/// decoration that can never fire. Each entry below states which it is. This
/// fails closed (no Safari, no shield bypass), so a wrong link is never a
/// security problem; it is a promise the file would be making and not keeping.
public enum LaunchCatalog {

    public struct Entry: Hashable, Sendable {
        public let display: String          // brand casing, shown in setup
        public let names: [String]          // matchable names, lowercased
        public let scheme: String?          // custom scheme, tried first
        public let universalLink: String?   // https fallback, AASA-matched or nil
    }

    public static let entries: [Entry] = [
        .init(display: "Instagram", names: ["instagram", "ig", "insta"], scheme: "instagram://", universalLink: "https://www.instagram.com/"),
        .init(display: "TikTok", names: ["tiktok"], scheme: "snssdk1233://", universalLink: "https://www.tiktok.com/"),
        .init(display: "YouTube", names: ["youtube", "yt"], scheme: "youtube://", universalLink: "https://www.youtube.com/"),
        .init(display: "X", names: ["twitter", "x"], scheme: "twitter://", universalLink: "https://x.com/"),
        .init(display: "Reddit", names: ["reddit"], scheme: "reddit://", universalLink: "https://www.reddit.com/"),
        .init(display: "Snapchat", names: ["snapchat", "snap"], scheme: "snapchat://", universalLink: "https://www.snapchat.com/"),
        .init(display: "Facebook", names: ["facebook", "fb"], scheme: "fb://", universalLink: "https://www.facebook.com/"),
        .init(display: "Threads", names: ["threads"], scheme: "barcelona://", universalLink: "https://www.threads.net/"),
        .init(display: "Pinterest", names: ["pinterest"], scheme: "pinterest://", universalLink: "https://www.pinterest.com/"),
        .init(display: "Twitch", names: ["twitch"], scheme: "twitch://", universalLink: "https://www.twitch.tv/"),
        // The link is /browse and not the root on purpose, and Netflix is the
        // one door in the twelve above that needed it. Its AASA ends each app
        // entry's components list in {"/": "/?*"} — a catch-all that claims
        // every path EXCEPT the bare root, because "?" demands a character
        // after the slash. A bare https://www.netflix.com/ therefore matched
        // nothing and this fallback could never have fired. /browse is the
        // app's home grid and clears the exclusions stacked above that
        // catch-all. The other eleven cover "/" and are left as they are.
        .init(display: "Netflix", names: ["netflix"], scheme: "nflx://", universalLink: "https://www.netflix.com/browse"),
        .init(display: "LinkedIn", names: ["linkedin"], scheme: "linkedin://", universalLink: "https://www.linkedin.com/"),

        // The five the owner chose to widen the setup list with. Grouped and
        // annotated rather than folded in above, because two of them ship on a
        // scheme nobody has been able to verify and the reader has to be able
        // to see which two.

        // Discord is BACK, and the line that kept it out was wrong. This file
        // said "Discord and WhatsApp are deliberately absent — no reliable
        // public scheme; absent even from Opener's 244-app catalogue." The
        // shipping app's own Info.plist registers CFBundleURLSchemes
        // ["com.hammerandchisel.discord", "discord"] under the URL name
        // "discord://", and Amazon's iOS app declares `discord` in its
        // LSApplicationQueriesSchemes — two parties, one of them Discord.
        // WhatsApp's half of that sentence did not survive either: WhatsApp
        // registers `whatsapp` (net.whatsapp.WhatsApp), and Telegram and
        // Discord both query it. WhatsApp is absent because nobody has asked
        // for it, not because it cannot be opened — if it is ever wanted it is
        // one line, on the same evidence as Discord's.
        //
        // The link is /app and not the root on purpose: discord.com's AASA
        // lists /app, /invite/*, /channels/* and eighteen more, and no "/". A
        // bare https://discord.com/ would match nothing and open nothing.
        .init(display: "Discord", names: ["discord"], scheme: "discord://", universalLink: "https://discord.com/app"),

        // Tinder's scheme is `tinder` in com.cardify.tinder's own URL types,
        // and Snapchat queries the same word — the App Store app is
        // com.cardify.tinder, which is the bundle id tinder.com's AASA names.
        //
        // NO FALLBACK, deliberately. That AASA covers exactly /deeplink/*: the
        // root is not in it, so a https://tinder.com/ fallback could never
        // fire, and writing one down would be this file claiming a second way
        // in that does not exist. nil says the truth — the scheme is the whole
        // of it.
        .init(display: "Tinder", names: ["tinder"], scheme: "tinder://", universalLink: nil),

        // DEVICE-UNVERIFIED (1 of 2). `hinge://` is a guess. Hinge publishes no
        // scheme, no third-party app queries one, and the App Store binary
        // (co.hinge.mobile.ios) could not be read. The owner chose to ship it
        // and check it on the next physical-device session.
        //   WHAT TO CHECK: tap the Hinge door and see whether Hinge comes to
        //   the front.
        //   IF IT IS WRONG: `open` gets `false` from the scheme, the fallback
        //   below is nil, and NOTHING happens — the grant still landed and the
        //   wall is still down, so the read-back is correct and she taps the
        //   icon. It fails closed and costs the launch, not the minutes.
        //   THE FALLBACK IS NIL FOR A MEASURED REASON: hinge.co's AASA gives
        //   co.hinge.mobile.ios only /uni/* and /app/*. A third entry does
        //   carry "*", but under co.hinge.ios.Hinge, which is not an app the
        //   App Store serves — so on a real phone the root is uncovered.
        .init(display: "Hinge", names: ["hinge"], scheme: "hinge://", universalLink: nil),

        // DEVICE-UNVERIFIED (2 of 2). `temu://` is the same kind of guess, with
        // the same check and the same failure.
        //   WHAT TO CHECK / IF IT IS WRONG: as Hinge — except Temu has a real
        //   fallback, so a wrong scheme here should still open the app.
        //   THE LINK IS REAL AND ITS QUERY IS LOAD-BEARING. temu.com's AASA
        //   carries a component with no path and `_p_dp=1` in its query, and a
        //   component that omits "/" matches every path — so this exact URL is
        //   AASA-matched where a bare https://www.temu.com/ is not. Drop the
        //   query and the fallback stops firing. It rests on a component broad
        //   enough that a researcher has published it as a misconfiguration; if
        //   Temu tightens it this link goes quiet, which is the closed
        //   direction.
        .init(display: "Temu", names: ["temu"], scheme: "temu://", universalLink: "https://www.temu.com/?_p_dp=1"),

        // Amazon's scheme is not `amzn`. The shipping app registers
        // com.amazon.mobile.shopping, com.amazon.mobile.shopping.web,
        // com.amazon.mobile.sso and com.amazon.mobile.share, and the first is
        // the native one — a dot is legal in a URI scheme, so this parses.
        // Amazon is also the one brand here whose root IS in its AASA
        // ({"/": "/"} under com.amazon.Amazon), so this fallback genuinely
        // fires.
        .init(display: "Amazon", names: ["amazon"], scheme: "com.amazon.mobile.shopping://", universalLink: "https://www.amazon.com/"),
    ]

    /// The entry a spoken name belongs to, and the ONE lookup in this file —
    /// the app's `open`, setup's display lookup and the tests all come through
    /// here, so they cannot disagree about what a name is. A `knows(_:)`
    /// spelling of the same question stood beside it, read by nothing but the
    /// tests that were written for it; the question is `entry(named:) != nil`
    /// and now that is how it is asked.
    public static func entry(named name: String) -> Entry? {
        let key = name.lowercased()
        return entries.first { $0.names.contains(key) }
    }


}
