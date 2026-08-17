# Silk

Your distracting apps live behind one door. You say what you want in your own words; Silk grants it
from one daily budget, opens the app, and locks the door behind you. Deterministic hard blocking,
three pages, nothing to scroll. *The app you open instead.*

One budget, and — if you want it — a ceiling on how much of it any one app may take. Still one
number on the screen and one pool to spend from: a cap is a lid on the pool, never a second budget.
See [`docs/design/per-app-caps.md`](docs/design/per-app-caps.md).

## Layout

| Path | What it is |
|---|---|
| `SilkCore/` | The spine as a pure-Swift package: parser, number tokenizer, clause index, validator, polarity engine, grant ledger, per-app ceilings, the wait's clock and price, the launch catalogue's data. `swift test` runs on macOS — 438 tests across 65 suites (three generations of fuzz corpora, a seeded 20k-input fuzzer, see `docs/qa/`, the wait's frame-budget bounds, and the re-lock's lateness bounds), no simulator needed. |
| `Silk/` | The app: Now, Mirror + Settings, the bar and its conversation, the compile pipeline, wall controller, the launch catalogue's one `UIApplication` call, the `Spend` App Intent, the on-device model widener. |
| `Shared/` | The App Group bridge (`SharedStore`) and the single wall (`Wall.reconcile()`), shared with all three extensions. |
| `SilkMonitor/` · `SilkShield/` · `SilkShieldAction/` | The Screen Time extensions: re-lock layers, the statement-only shield, the one OK button. |
| `project.yml` | XcodeGen spec — regenerate `Silk.xcodeproj` with `xcodegen generate`. |
| `SilkTests/` | The app's own logic, hosted by the app so it reaches `AppModel` without a simulator walk: the wait's state machine, its ledger transaction, undo on the far side of it, and the frame budget the mark's geometry and the landing are held to. |
| `scripts/ci.sh` · `.githooks/` | All three suites, and the pre-push hook that runs the cheap one. See **Tests**. |
| `docs/market/` | The research this design rests on. Start with `docs/market/README.md`. |
| `silk-ds/` · `ds-bundle/` | The design language: warm paper, ink, the ensō, and a deliberately small vocabulary. |

## Build

```bash
cd SilkCore && swift test        # the spine's logic, on macOS
xcodegen generate                # after editing project.yml
xcodebuild -project Silk.xcodeproj -scheme Silk \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Tests

```bash
scripts/ci.sh                    # all three suites, ~7 min
scripts/ci.sh spine              # SilkCore only, seconds, no simulator
scripts/ci.sh unit               # SilkTests only — the app's logic, ~1 min
scripts/ci.sh ui                 # SilkUITests only, ~5 min
```

`.github/workflows/ci.yml` runs both on every pull request and every push to `main` — the spine in
about a minute, the simulator in about thirteen. That is the gate; a red PR is the answer.

The hook is the fast half. Turn it on once per clone:

```bash
git config core.hooksPath .githooks
```

`.githooks/pre-push` then runs **the spine only** — a tenth of a second, and it catches most of what
breaks before it costs a round trip. It deliberately does not run the simulator: five minutes locally
to learn what the PR is about to tell you anyway is how a hook gets deleted.

```bash
SILK_RUN_UI=1 git push    # both suites first — before a PR you want green
git push --no-verify      # skip the hook entirely
```

Know one thing about it before you trust it. `core.hooksPath` is per-clone config, but the hook file
is branch content — so on any checkout that predates `.githooks/`, or during a `git bisect`, or from
an old tag, git finds no hook, says **nothing**, and the push goes out ungated. It fails silent, which
is the one direction a gate must not fail. CI is what actually holds the line; the hook only shortens
the feedback loop when it happens to be there. The hook also tests the working tree rather than the
commits being pushed, so a dirty tree or a push of some other branch is not the thing it measured.

If you change what the script runs, change the workflow to match.

Before running on a device: `DEVELOPMENT_TEAM` is already set in `project.yml`, and development signing
needs nothing else — FamilyControls is available to every team for development.

Bundle identity derives from a single build setting, `SILK_BUNDLE_PREFIX` in `project.yml`. All four
bundle IDs, the App Group, and the log subsystem are built from it, so a rename is one line plus
`xcodegen generate`. Two things make that rename one-way, and neither has happened yet:

- bundle IDs lock at the **first build upload** to App Store Connect;
- the **FamilyControls (Distribution)** entitlement is granted *per bundle ID* — four separate requests
  here — so renaming afterward means re-requesting all four and waiting out the queue again.

Distribution is the gate, not development: TestFlight, Ad Hoc and the App Store all require that
entitlement, and Apple must grant it by hand (see `docs/market/what-is-buildable.md` → Shipping).

## The rules the code enforces

1. **Spend by asking.** Within budget a grant is granted, the balance read back, the app opened —
   after a wait priced in seconds of watching, which passes only while Silk is on screen and stops
   the moment it is not. Nothing is debited, unshielded or armed until the wait is paid, so leaving
   costs nothing and the wall never comes down early. See
   [`docs/design/wait.md`](docs/design/wait.md), which states the canon objection before it answers
   it.
2. **Edges never yield.** Budget gone, a door's own ceiling spent, or down hours means no. Refusals
   are four words and a time, and they name the door when the door is what ran out — "0 left today."
   beside a hero reading 30 is a lie.
3. **Loosening waits for tomorrow** — unless a physical key the phone doesn't hold is tapped.
   Tightening is instant. Polarity is computed by state diff, never parsed from words.
4. **The wall fails closed.** The ledger is the truth; a dead extension closes doors late, never
   leaves them open. The model proposes; the validator disposes.
5. **No notification permission, ever.** Every word the app says comes from
   `SilkCore/Sources/SilkCore/Strings.swift` — 60 of them today, 55 constants and 5 that compose. The
   file is the vocabulary, and nothing outside it may speak.
