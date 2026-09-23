# design-sync notes — Silk

`.design-sync/` is the bookkeeping for one direction of traffic: `silk-ds/`, the
canonical mockups, out to `ds-bundle/`, the design language a builder receives.
It holds the sync config, the header and body `ds-bundle/README.md` is
concatenated from — `conventions.md` + `readme-body.md`, which are what you
edit, never the README — a local verification harness, and these notes. None of
it is in the app.

Project: **Silk — Design System**. The id the sync tool pushes to lives in
`config.json`, which is the only file that needs it.

First sync: 2026-07-28.

## This repo is outside the converter's envelope — on purpose

Silk has **no JavaScript component library**: no `package.json`, no Storybook, no
build, no `dist/`. The source is 13 self-contained HTML+CSS mockups under
`silk-ds/`. So `package-build.mjs` was never run and there is no `_ds_bundle.js`,
no `.jsx`, and no `.d.ts` — there is no component API to describe.

Do **not** "fix" this by generating React wrappers. That was considered and
explicitly declined (the alternative on the table was building a real component
library first, which is a build job, not a sync). What ships instead is the
design *language*, which is what the mockups actually contain.

## What the build does

1. The CSS was duplicated inline across the 12 mockups that were converted. It
   was extracted **once** into `ds-bundle/tokens/{color,type}.css` +
   `ds-bundle/_ds_bundle.css`, namespaced `silk-*` (BEM-flavoured), and reached
   from `styles.css` by `@import`. Rules were copied verbatim — only selectors
   were renamed.
2. Preview cards are the original mockups, **byte-for-byte unmodified**, moved to
   `components/<group>/<Name>/<Name>.html`. Their `@dsCard group="…"` first lines
   are what the app builds its card index from, so never strip them.
3. `<Name>.prompt.md` is authored per component: markup, states, and don'ts.

The thirteenth mockup, `silk-ds/screens/interactive.html`, was added after the
first sync and has never been converted — there is no card for it under
`ds-bundle/components/`. It is carried in `_ds_sync.json`'s `sourceHashes` with
no matching `renderHashes` entry, which is how the manifest says so. It still
carries a `@dsCard group="Screens"` first line, so a re-sync will offer it as a
new card until someone decides it should not be one.

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
(`.design-sync/` is outside the sync's write globs) and should stay that way.

Verified at the first sync: Now (day), Now (night), Shield ×3, Mirror hero +
equation + chart + proposal card, and Doors in all four states across both
themes. Several of those have since left the app — see the note at the top of
`ds-bundle/README.md`. They are still what the mockups draw, and the mockups are
what this harness checks.

## Findings

- **Brand fonts are not uploaded, and the app warns about it.** Silk's stacks
  name `SF Pro Text` / `SF Pro Display` and `New York` — Apple system fonts.
  They ship with macOS (`/System/Library/Fonts/SFNS.ttf`, `NewYork.ttf`), which
  is *why local verification rendered with the real typefaces. The cloud
  renderer has neither*, so designs built there substitute **Georgia** for the
  serif voice and **Helvetica/Arial** for the sans.
  - This does not invalidate the CSS verification — both sides of every
    comparison used the same fonts, so the extraction is confirmed faithful.
    What substitutes is the typeface, not the layout.
  - It does mean the serif numeral voice — the most distinctive thing about
    Silk — will not look right in cloud-rendered designs until font files exist
    in `fonts/`.
  - **Not resolved deliberately.** Uploading Apple's font binaries to a cloud
    service is redistribution, and their licence restricts that. Two ways out:
    license a substitute pairing with similar proportions and ship those files,
    or accept the substitution in the design tool and rely on the real fonts
    appearing once designs are ported to the iOS app, where they are free.
- **`⚿` (U+269F) renders as tofu.** `silk-ds/screens/mirror.html` uses it in the
  footnote. Most system fonts lack the glyph — it is a source issue, present in
  the original, not a regression. Flagged in `Mirror.prompt.md`. The app settled
  it by drawing the `key` SF Symbol at the same optical size instead.
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

Two of its keys cover more than one file, and the recipe is literal:
`bundleSha12` is `_ds_bundle.css` alone, and `styleSha` is `styles.css`,
`tokens/color.css`, `tokens/type.css` and `_ds_bundle.css` concatenated in that
order, with no separator — so editing a comment in `styles.css` moves it, and it
has to be recomputed. `auxSha` matches no file in `ds-bundle/`, `silk-ds/` or
here, and nothing in the repo says what it covers; leave it alone until a
re-sync writes it.

## Designs come back as web HTML

The repo is named `silk-ios` and every mockup is an iPhone screen, but the
design tool renders on the web. What comes back is web HTML/CSS in the Silk
idiom, and it still has to be translated to SwiftUI by hand.
`Silk/DesignSystem.swift` is where the tokens land — it names
`ds-bundle/tokens/` as its source — and the views beside it are that
translation.
