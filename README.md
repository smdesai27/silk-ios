# Silk

Your distracting apps live behind one door. You say what you want in your own words; Silk grants it
from one daily budget, opens the app, and locks the door behind you. Deterministic hard blocking,
three pages, nothing to scroll. *The app you open instead.*

## Layout

| Path | What it is |
|---|---|
| `SilkCore/` | The spine as a pure-Swift package: parser, number tokenizer, validator, polarity engine, grant ledger. `swift test` runs on macOS — 139 tests across 24 suites, no simulator needed. |
| `Silk/` | The app: Now, Mirror + Settings, the bar and its conversation, the compile pipeline, wall controller, launch catalogue, the `Spend` App Intent, the on-device model widener. |
| `Shared/` | The App Group bridge (`SharedStore`) and the single wall (`Wall.reconcile()`), shared with all three extensions. |
| `SilkMonitor/` · `SilkShield/` · `SilkShieldAction/` | The Screen Time extensions: re-lock layers, the statement-only shield, the one OK button. |
| `project.yml` | XcodeGen spec — regenerate `Silk.xcodeproj` with `xcodegen generate`. |
| `scripts/ci.sh` · `.githooks/` | Both suites, and the pre-push hook that runs them. See **Tests**. |
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
scripts/ci.sh                    # both suites, ~6 min
scripts/ci.sh spine              # SilkCore only, seconds, no simulator
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

Before running on a device: `DEVELOPMENT_TEAM` is already set in `project.yml`, but the bundle IDs are
still the placeholder `com.sanildesai.*` — change them (all four targets and the app group), and request
the **FamilyControls (Distribution)** entitlement for all four (see
`docs/market/what-is-buildable.md` → Shipping).

## The rules the code enforces

1. **Spend by asking.** Within budget a grant is granted, the balance read back, the app opened.
2. **Edges never yield.** Budget gone or down hours means no. Refusals are four words and a time.
3. **Loosening waits for tomorrow** — unless a physical key the phone doesn't hold is tapped.
   Tightening is instant. Polarity is computed by state diff, never parsed from words.
4. **The wall fails closed.** The ledger is the truth; a dead extension closes doors late, never
   leaves them open. The model proposes; the validator disposes.
5. **No notification permission, ever.** Every word the app says comes from
   `SilkCore/Sources/SilkCore/Strings.swift` — 55 of them today, 52 constants and 3 that compose. The
   file is the vocabulary, and nothing outside it may speak.
