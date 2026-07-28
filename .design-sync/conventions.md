# Building with Silk

Silk is a **CSS design language, not a component library.** There is no
`_ds_bundle.js` and nothing to import — you build with plain HTML and the
`silk-*` classes defined in `styles.css`. Every class below is real and
verified against the compiled stylesheet.

## Setup

Two things, both required:

1. **Load `styles.css`.** It `@import`s `tokens/color.css`, `tokens/type.css`
   and `_ds_bundle.css`. Nothing reachable outside that closure will render.
   It also applies a zeroed box model (`margin/padding: 0; box-sizing: border-box`)
   that every measurement in Silk assumes.
2. **Paste the ensō symbol block** from `guidelines/enso-symbols.svg` once per
   page before using `<use href="#enso-full">`. It renders nothing on its own.

There is **no provider and no wrapper component** — but most screens live inside
`.silk-screen` (390×800, 46px radius, `overflow:hidden`), which is the positioned
ancestor that `.silk-cmdbar`, `.silk-dots`, `.silk-shield` and `.silk-home`
absolutely position against. Put them outside it and they will escape the frame.

**Night is a container modifier, not a media query.** Add `.silk-night` to
`.silk-screen` (or any ancestor) and every descendant restyles. Never use
`prefers-color-scheme` — Silk's night follows the user's down-hours window, not
their system theme.

## The class vocabulary

BEM-flavoured, all `silk-` prefixed. `__` is a part, `--` is a state.

| Family | Classes |
|---|---|
| Ground | `.silk-atmosphere` `.silk-screen` `.silk-night` `.silk-dapple` `.silk-moonwash` `.silk-island` `.silk-home` |
| Brand | `.silk-wordmark` `__mark` `__text` · `.silk-greet` |
| Ensō | `.silk-hero` `.silk-enso-wrap` `--mirror` `.silk-hero-inner` `.silk-hero-num` `.silk-hero-label` |
| Aperture | `.silk-aperture` `__text` |
| Doors | `.silk-doors` `.silk-door` `__name` `__time` `__state` · `--live` `--rest` `--open` |
| Command bar | `.silk-cmdbar` `__mic` · `.silk-dots` `.silk-dot` `--active` |
| Proposal | `.silk-card` `__obs` `__ask` `__actions` · `.silk-btn-accept` `.silk-btn-later` |
| Chart | `.silk-chart` `__title` `.silk-bars` `__col` `--today` `.silk-bar` `.silk-xlabels` `__col` `--today` · `.silk-eq` `.silk-footnote` |
| Shield | `.silk-shield` `__mark` `__until` `__app` `__ok` |
| Type | `.silk-serif` (alias `.ny`) |

For your own layout glue, use the tokens rather than literals: `var(--silk-ink-84)`,
`var(--silk-paper)`, `var(--silk-leaf)`, `var(--silk-font-serif)`. The ink and
paper ramps run `--silk-ink-92 … --silk-ink-055` and `--silk-paper-92 … --silk-paper-05`.

## Four rules that decide whether it looks like Silk

1. **Serif is locked** to numerals and to sentences Silk speaks in its own voice
   (greeting, ask, equation). Apply it with `.silk-serif` — never `font-family`
   alone, or you lose the tabular numerals. A sans numeral is the single most
   common way to get this wrong.
2. **One pop moment per screen — a wall, not wallpaper.** `--silk-leaf` and
   `--silk-open-sky` appear once. Everything else is an alpha ramp on ink or paper.
3. **The stroke is the budget.** The ensō has no track and no ghost ring; spent
   time is bare paper. Never draw the remainder.
4. **Nothing is pure white or black,** and there is no semantic colour — no red
   error, no amber warning. Things recede down the ramp instead.

Silk has no bold (nothing above weight 500), no icons in lists, no tab bar, and
only two screens. When something new needs a home, it goes on Mirror.

## Where the truth lives

Read `styles.css` and its imports before styling — the real values beat any
summary. Each component's `components/<group>/<Name>/<Name>.prompt.md` carries
its markup, states, and its don'ts; the `<Name>.html` next to it is the original
canonical mockup and renders standalone.

## An idiomatic snippet

```html
<div class="silk-screen">
  <div class="silk-dapple"></div>
  <div class="silk-hero">
    <div class="silk-enso-wrap">
      <svg viewBox="0 0 200 200"><use href="#enso-full"/></svg>
      <div class="silk-hero-inner">
        <div class="silk-hero-num silk-serif">40</div>
        <div class="silk-hero-label">min left today</div>
      </div>
    </div>
  </div>

  <!-- your own layout glue uses tokens, not literals -->
  <p style="margin: 22px 46px 0; font-size: 15px;
            letter-spacing: var(--silk-track-tight);
            color: var(--silk-ink-84);">
    Two doors are still open.
  </p>
</div>
```
