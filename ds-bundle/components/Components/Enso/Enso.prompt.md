# Ensō — the living circle

Silk's hero element and its brand mark. A single brush-drawn circle whose
**stroke length is the remaining budget**. It is not a progress ring.

> The stroke is the budget. No track, no ghost ring — spent time is bare paper.

That sentence governs everything. **Never** draw a faint full circle behind the
stroke to show "total". Time already spent is simply absent — it is paper. If you
find yourself adding a track, you have stopped drawing Silk.

## Markup

Paste the symbol block from `guidelines/enso-symbols.svg` once per page, then:

```html
<div class="silk-hero">
  <div class="silk-enso-wrap">
    <svg viewBox="0 0 200 200"><use href="#enso-full"/></svg>
    <div class="silk-hero-inner">
      <div class="silk-hero-num silk-serif">40</div>
      <div class="silk-hero-label">min left today</div>
    </div>
  </div>
</div>
```

`.silk-enso-wrap` is 232×232 and positions the SVG absolutely behind a centred
`.silk-hero-inner`. The numeral **must** carry `.silk-serif` — a sans numeral in
the ring is the single most common way to make this look wrong.

## Variants

| `href` | Meaning | Colour it inherits |
|---|---|---|
| `#enso-full` | 100% — the complete circle | `--silk-leaf` (day) / `--silk-dusk-blue` (night) |
| `#enso-82` | 82% — used by Mirror, drawn in ink | `--silk-ink` via `.silk-enso-wrap--mirror` |
| `#enso-37` | 37% — the stroke has visibly shortened | leaf |
| `#enso-rest` | down hours: complete, lighter hand | dusk blue |
| `#enso-s` | the 13–15px wordmark/shield mark | current text colour |

The stroke takes `currentColor`, so recolour by setting `color` on the `<svg>`
— don't touch `stroke`.

### Mirror's ensō

```html
<div class="silk-enso-wrap silk-enso-wrap--mirror">…</div>
```

Drops to 190×190, switches the stroke to ink, and reduces the numeral to 72px.
Mirror is a reflection on a finished day, so it is drawn in ink rather than the
live leaf.

## Drawing an arbitrary percentage

All variants share one path `d`. Five stacked strokes of increasing width
(2.2 / 2.6 / 3.0 / 3.8 / 4.6) create the taper that makes it read as a brush
rather than a ring. For a budget of `p` percent, set the five dasharrays to:

```
p × [1, 0.80, 0.58, 0.34, 0.16]
```

(the widest stroke is shortest, so the line thins as it lifts). Below roughly
40%, pull the tail in a little further — at 37% the measured set is
`37 / 28.5 / 20 / 11.5 / 5`.

Two strokes finish the gesture and are easy to forget:

- the **dry-brush shadow** — width 0.7, opacity .45, offset `translate(4 4) scale(0.96)`
- the **lift-off flick** — a short 1.1-width arc that must leave the path
  *tangentially at the point where the stroke ends*. Reuse the flick from the
  nearest variant rather than inventing one; a flick at the wrong angle reads as
  a stray mark.

## Don't

- Don't add a track, ghost ring, or percentage text.
- Don't animate it as a filling ring. If it moves, it is drawn — once, forward.
- Don't set the numeral in sans, and don't let it lose `tabular-nums` (digits
  must not shift as the number ticks down).
