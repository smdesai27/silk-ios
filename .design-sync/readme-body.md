
---

# Silk — Design System

Silk is a screen-time app for iOS. Its design language is warm-paper editorial:
ink on unbleached stock, a locked serif numeral voice, and a single brush-drawn
ensō whose stroke length *is* the remaining budget.

## What this project contains

| Path | What it is |
|---|---|
| `styles.css` | the entry point — `@import`s everything below. Designs receive only this closure. |
| `tokens/color.css` | palette + the ink/paper alpha ramps |
| `tokens/type.css` | font stacks, role sizes, tracking, and `.silk-serif` |
| `_ds_bundle.css` | the component classes, lifted verbatim from the canonical mockups |
| `guidelines/enso-symbols.svg` | the ensō symbol set — paste once per page, then `<use href="#…">` |
| `components/<group>/<Name>/<Name>.html` | the original canonical mockup; renders standalone |
| `components/<group>/<Name>/<Name>.prompt.md` | how to build with it: markup, states, and don'ts |

## Component index

**Foundations**

| | |
|---|---|
| `Colors` | two grounds, two ramps, two rationed pops |
| `Type` | the sans/serif split and the eleven type roles |

**Components**

| | |
|---|---|
| `Enso` | the living circle — 5 variants, and the rule against drawing a track |
| `Aperture` | the down-hours window; recessed by day, the only lit thing at night |
| `Doors` | the app list — `--live` / `--rest` / `--open` |
| `CommandBar` | the single input. A hairline, never a filled field |
| `Shield` | the wall that appears instead of the app. One button, no escape hatch |
| `ProposalCard` | observation → ask → one yes, one quiet exit |
| `AttemptsChart` | seven bare strokes; today carries the pop |

**Screens**

| | |
|---|---|
| `NowDay` | the canonical composition — start here |
| `NowNight` | the same screen after the down-hours window opens |
| `Mirror` | the reflection: score, equation, week, proposal |

## Provenance, and what is deliberately absent

This project was converted from 12 self-contained HTML+CSS mockups
(`silk-ds/` in the source repo). Silk has **no JavaScript component library** —
no `package.json`, no build, no `dist/` — so there is no `_ds_bundle.js` and
there are no `.d.ts` contracts. Nothing was reimplemented to fake one.

What was done instead: the CSS that was duplicated inline across all 12 mockups
was extracted once into `tokens/` + `_ds_bundle.css`, namespaced `silk-*`, and
verified by rebuilding the Now (day), Now (night), Mirror, Shield, Doors, chart
and proposal-card renders from `styles.css` alone and comparing them against the
originals. The preview cards are the original mockups, byte-for-byte unmodified.

So: build Silk screens as HTML with the `silk-*` classes. That is the whole API.

## Re-syncing

Source of truth is the repo, not this project. Config lives in
`.design-sync/config.json`; the conventions header above is
`.design-sync/conventions.md` and is meant to be edited by hand. Findings and
caveats are in `.design-sync/NOTES.md`.
