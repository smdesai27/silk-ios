# Silk

[![CI](https://github.com/smdesai27/silk-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/smdesai27/silk-ios/actions/workflows/ci.yml)

An iOS Screen Time app. Your distracting apps live behind one door; you ask in your own words,
spend from one daily budget, and the door locks behind you. *The app you open instead.*

<p align="center">
  <img src="assets/screenshots/raw/shot-02.png" width="230" alt="Now: minutes left today, and which doors are open">
  &nbsp;&nbsp;
  <img src="assets/screenshots/raw/shot-03-thread.png" width="230" alt="The bar: unlock Instagram for 10 min, and the reply: Instagram is open for 10 min.">
  &nbsp;&nbsp;
  <img src="assets/screenshots/raw/shot-04.png" width="230" alt="Mirror: the score for the last full day, and the week below it">
</p>

## What it does

- **One door.** The apps you pick are shielded together and opened one grant at a time from a
  single daily budget. A per-app ceiling is a lid on that pool, never a second budget: one number
  on the screen, one pool to spend from.
- **Rules in plain language.** "Unlock Instagram for 10 min." A spend is a whole sentence — an
  opening verb, the app's exact name, and the minutes — and a fragment gets back the one sentence
  to write instead. Within budget the grant lands after a short wait that passes only while Silk
  is on screen; the balance reads back, the app opens, and the door locks again when the minutes
  run out. Refusals are three words and a time.
- **Tighten now, loosen tomorrow.** Anything that makes the day stricter takes effect at once.
  Anything that loosens it waits for tomorrow, unless the held rule's one button, "Apply now.", is
  tapped. Polarity is computed by state diff, never parsed from words.
- **A wall that fails closed.** Four re-lock layers stand behind every grant: a one-shot
  DeviceActivity schedule at expiry, a staggered backup two minutes later, a usage-threshold event
  on the door's own tokens, and a reconcile on every app foreground, shield render and shield tap.
  The ledger is the truth. If every layer fails, the door closes at the next wake: late, never never.
- **The model proposes; the validator disposes.** A deterministic parser answers first. An
  on-device model may widen what the grammar did not claim, and a deterministic validator has the
  last word on anything it proposes. No notification permission, ever.

## The rules the code enforces

The comments in `Silk/`, `Shared/` and the extensions cite these by number. `SilkCore` has its own
numbered grammar — the ladder of readings in `DeterministicParser`, 1 through 10 with two
half-steps — so a bare "rule 7" inside the spine means that list, not this one.

1. **Spend by asking.** Within budget a grant is granted, the balance read back, the app opened —
   after a wait priced in seconds of watching, which passes only while Silk is on screen and stops
   the moment it is not. Nothing is debited, unshielded or armed until the wait is paid, so leaving
   costs nothing and the wall never comes down early. A spend is a whole sentence — an opening verb,
   the app name, and the minutes — and a fragment gets back the one sentence to write instead.
2. **Edges never yield.** Budget gone, a door's own ceiling spent, or down hours means no. Refusals
   are three words and a time — "TikTok closed until 9:00.", "Down hours. Opens 7:00 AM." — and they
   name the door when the door is what ran out: "0 left today." beside a hero reading 30 is a lie.
3. **Loosening waits for tomorrow** — unless the held rule's one button, "Apply now.", is tapped.
   Tightening is instant. Polarity is computed by state diff, never parsed from words.
4. **The wall fails closed.** The ledger is the truth; a dead extension closes doors late, never
   leaves them open. The model proposes; the validator disposes.
5. **No notification permission, ever.** Every word the app says comes from
   `SilkCore/Sources/SilkCore/Strings.swift` — 76 of them today, 66 constants and 10 that compose.
   The file is the vocabulary, and nothing outside it may speak.

## Architecture

| Path | What it is |
|---|---|
| `SilkCore/` | The spine as a pure-Swift package: parser, number tokenizer, clause index, validator, polarity engine, grant ledger, per-app ceilings, the wait's clock and price, the launch catalogue's data. `swift test` runs on macOS **and on Linux** — 1,061 tests across 193 suites (three generations of fuzz corpora, a seeded 20k-input fuzzer, the wait's frame-budget bounds, and the re-lock's lateness bounds), no simulator needed. The sources import Foundation and nothing else and carry no conditional compilation at all, which is what lets 1,060 of the repo's 1,200 tests answer in a container; CI's `spine-linux` job is what keeps that true. |
| `Silk/` | The app: Now, Mirror + Settings, the bar and its conversation, the compile pipeline, wall controller, the launch catalogue's app half — where the spine's catalogue reaches `UIApplication` — the `Spend` App Intent, the on-device model widener. |
| `Shared/` | The App Group bridge (`SharedStore`) and the single wall (`Wall.reconcile()`), shared with all three extensions. |
| `SilkMonitor/` · `SilkShield/` · `SilkShieldAction/` | The Screen Time extensions: re-lock layers, the statement-only shield, the one OK button. |
| `project.yml` | XcodeGen spec — regenerate `Silk.xcodeproj` with `xcodegen generate`. All four bundle IDs, the App Group and the log subsystem derive from one setting, `SILK_BUNDLE_PREFIX`. |
| `SilkTests/` | The app's own logic, hosted by the app so it reaches `AppModel` without a simulator walk: the wait's state machine, its ledger transaction, undo on the far side of it, and the frame budget the mark's geometry and the landing are held to. |
| `SilkUITests/` | The simulator walks, including the one that captures the screenshots. |
| `scripts/ci.sh` · `.githooks/` | Every suite, and the pre-push hook that runs the cheap one. See **Tests**. |
| `silk-ds/` · `ds-bundle/` · `.design-sync/` | The design language: warm paper, ink, the ensō, and a deliberately small vocabulary — the mockups, the CSS bundle extracted from them, and the notes that keep the two in step. |
| `assets/screenshots/` | Device captures, and the App Store set composed from them. |

## Build

Xcode 26.6 on macOS 26, the versions `project.yml` and CI pin. The app targets iOS 26.5, and
`SilkCore`'s package asks for macOS 26.0, so on anything older `swift test` compiles and then
refuses to launch the test binary.

```bash
xcodebuild -project Silk.xcodeproj -scheme Silk \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`Silk.xcodeproj` is committed, so that works straight from a clone. XcodeGen is needed only after
editing `project.yml` — `brew install xcodegen && xcodegen generate` — and regenerating must leave
the project file unchanged, which is what `scripts/release.sh` refuses to archive without.

Before running on a device, make the identity yours: set `DEVELOPMENT_TEAM` in `project.yml` to
your own team and `SILK_BUNDLE_PREFIX` to a prefix you own — all four bundle IDs, the two test
bundles and the App Group derive from it — then `xcodegen generate`. Nothing else is needed;
FamilyControls is available to every team for development.

## Tests

```bash
scripts/ci.sh                    # all three suites and the Release build, ~25 min
scripts/ci.sh spine              # SilkCore only, seconds, no simulator
scripts/ci.sh unit               # SilkTests only — the app's logic, ~1 min
scripts/ci.sh ui                 # SilkUITests only, ~5 min
scripts/ci.sh release            # Release compiles at all, ~4 min, no simulator
```

`cd SilkCore && swift test` is the spine on its own, and it answers on Linux as well as on macOS.

`.github/workflows/ci.yml` runs the same lanes on every pull request and every push to `main`, a
`release/**` branch, or a working branch named `fable-*` or `claude/**`. That is the authority,
and the badge at the top of this file is its live state. `scripts/ci.sh all` is the same set of
lanes on your own machine, and `scripts/release.sh` runs it before it will archive.

The hook is the fast half. Turn it on once per clone:

```bash
git config core.hooksPath .githooks
```

`.githooks/pre-push` then runs the spine only. `SILK_RUN_UI=1 git push` runs every lane instead;
`git push --no-verify` skips the hook entirely.

## Status

1.0.0 (build 3) is with App Review, resubmitted on 2026-09-19 with the Family Controls
distribution entitlement on all four bundles. Release is set to Manual, so it is not on the App
Store yet. *Status as of 2026-09-19.*

## Links

[Privacy policy](https://smdesai27.github.io/silk-ios/privacy.html) ·
[Support](https://smdesai27.github.io/silk-ios/support.html) — the two pages the app itself links
to (`Silk/Links.swift`), served from the `gh-pages` branch. Anything security- or privacy-relevant
goes to the address on the support page rather than to a public issue; see
[SECURITY.md](.github/SECURITY.md).

## License

All rights reserved. The source is published for reference; see [LICENSE](LICENSE). Questions are
welcome as issues; pull requests are not accepted, because the licence grants no right to modify
or redistribute the code.
