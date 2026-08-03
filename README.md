# Silk

Your distracting apps live behind one door. You say what you want in your own words; Silk grants it
from one daily budget, opens the app, and locks the door behind you. Deterministic hard blocking,
three pages, nothing to scroll. *The app you open instead.*

## Layout

| Path | What it is |
|---|---|
| `SilkCore/` | The spine as a pure-Swift package: parser, number tokenizer, validator, polarity engine, grant ledger. `swift test` runs on macOS — 119 tests across 23 suites, no simulator needed. |
| `Silk/` | The app: Now, Mirror + Settings, the bar and its conversation, the compile pipeline, wall controller, launch catalogue, the `Spend` App Intent, the on-device model widener. |
| `Shared/` | The App Group bridge (`SharedStore`) and the single wall (`Wall.reconcile()`), shared with all three extensions. |
| `SilkMonitor/` · `SilkShield/` · `SilkShieldAction/` | The Screen Time extensions: re-lock layers, the statement-only shield, the one OK button. |
| `project.yml` | XcodeGen spec — regenerate `Silk.xcodeproj` with `xcodegen generate`. |
| `docs/market/` | The research this design rests on. Start with `docs/market/README.md`. |
| `silk-ds/` · `ds-bundle/` | The design language: warm paper, ink, the ensō, and a deliberately small vocabulary. |

## Build

```bash
cd SilkCore && swift test        # the spine's logic, on macOS
xcodegen generate                # after editing project.yml
xcodebuild -project Silk.xcodeproj -scheme Silk \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

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
