# design-sync notes — Silk

Project: **Silk — Design System** · `727ccb6e-98bc-4700-bf7e-73188332e597`
https://claude.ai/design/p/727ccb6e-98bc-4700-bf7e-73188332e597

First sync: 2026-07-28.

## This repo is outside the converter's envelope — on purpose

Silk has **no JavaScript component library**: no `package.json`, no Storybook, no
build, no `dist/`. The source is 12 self-contained HTML+CSS mockups under
`silk-ds/`. So `package-build.mjs` was never run and there is no `_ds_bundle.js`,
no `.jsx`, and no `.d.ts` — there is no component API to describe.

Do **not** "fix" this by generating React wrappers. That was considered and
explicitly declined (the alternative on the table was building a real component
library first, which is a build job, not a sync). What ships instead is the
design *language*, which is what the mockups actually contain.

## What the build does

1. The CSS was duplicated inline across all 12 mockups. It was extracted **once**
   into `ds-bundle/tokens/{color,type}.css` + `ds-bundle/_ds_bundle.css`,
   namespaced `silk-*` (BEM-flavoured), and reached from `styles.css` by
   `@import`. Rules were copied verbatim — only selectors were renamed.
2. Preview cards are the original mockups, **byte-for-byte unmodified**, moved to
   `components/<group>/<Name>/<Name>.html`. Their `@dsCard group="…"` first lines
   are what the app builds its card index from, so never strip them.
3. `<Name>.prompt.md` is authored per component: markup, states, and don'ts.

## Verification method (repeat this on any re-sync)

There is no storybook to diff against, so fidelity was checked by **rebuilding
the mockups from `styles.css` alone** and comparing renders side by side:

```bash
python3 -m http.server 8731     # from the repo root
# then open .design-sync/verify/rebuilt-now.html
#           .design-sync/verify/rebuilt-components.html
#           .design-sync/verify/rebuilt-doors.html
# and compare against silk-ds/screens/*.html and silk-ds/components/*.html
```

Those three harness pages are the local reference. They are **not uploaded**
(`.design-sync/` is outside the plan's write globs) and should stay that way.

Verified this run: Now (day), Now (night), Shield ×3, Mirror hero + equation +
chart + proposal card, and Doors in all four states across both themes.

## Findings

- **Brand fonts are not uploaded, and the app warns about it.** Silk's stacks
  name `SF Pro Text` / `SF Pro Display` and `New York` — Apple system fonts.
  They are present on this Mac (`/System/Library/Fonts/SFNS.ttf`,
  `NewYork.ttf`), which is *why local verification rendered with the real
  typefaces. The cloud renderer has neither*, so designs built in Claude Design
  substitute **Georgia** for the serif voice and **Helvetica/Arial** for the sans.
  - This does not invalidate the CSS verification — both sides of every
    comparison used the same fonts, so the extraction is confirmed faithful.
    What substitutes is the typeface, not the layout.
  - It does mean the serif numeral voice — the most distinctive thing about
    Silk — will not look right in cloud-rendered designs until font files exist
    in `fonts/`.
  - **Not resolved deliberately.** Uploading Apple's font binaries to a cloud
    service is redistribution, and their licence restricts that. Options for
    Sanil: license a substitute pairing with similar proportions and ship those
    files, or accept the substitution in Design and rely on the real fonts
    appearing once designs are ported to the iOS app (where they are free).
- **`⚿` (U+269F) renders as tofu.** `silk-ds/screens/mirror.html` uses it in the
  footnote. Most system fonts lack the glyph — it is a source issue, present in
  the original, not a regression. Flagged in `Mirror.prompt.md`. Worth replacing
  with a key/lock glyph that SF Pro actually ships.
- **The Mirror ensō overrides the numeral size** (72px, label 12px) — this was
  missed on the first extraction pass and is now carried by
  `.silk-enso-wrap--mirror`. If you re-extract, don't lose it.
- **The ensō is parametric.** For a budget of `p` percent the five stacked
  dasharrays are `p × [1, .80, .58, .34, .16]`, tapering slightly further below
  ~40%. Derived from the three variants in the source; documented in
  `Enso.prompt.md`.
- The night theme is a **container modifier** (`.silk-night`), never
  `prefers-color-scheme` — Silk's night follows the down-hours window.

## `_ds_sync.json` is a custom envelope

It is marked `"shape": "static-html"`, which matches neither `storybook` nor
`package`, so any converter-based resync driver will fail to match it and will
correctly re-verify everything rather than trusting a stale skip. It carries
sha256[:12] of every source mockup and every uploaded card, which is enough to
diff by hand on a re-sync.

## Open question

The repo is named `silk-ios` and every mockup is an iPhone screen, but Claude
Design renders on the web. Designs produced there are web HTML/CSS in the Silk
idiom and still need translating to SwiftUI. Raised with Sanil; not yet decided.

## Housekeeping

- The repo is **not a git repository** — nothing here is committed. `git init`
  and commit `.design-sync/` + `silk-ds/` when convenient.
- `silk-ds/` was extracted from `~/Downloads/silk-design-system.zip`.
