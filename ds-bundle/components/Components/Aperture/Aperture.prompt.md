# Aperture

The down-hours window — a piece of sky held by the page. It shows the sleep
window and is the one object in Silk with real material depth: everything else
is ink on paper, this is a recessed pane of glass.

## Markup

```html
<div class="silk-aperture">
  <span class="silk-aperture__text silk-serif">☾&nbsp; 10:00 PM – 7:00 AM</span>
</div>
```

Fixed at 234×56 with a 27px radius, centred by its own `margin: 18px auto 0`.
The text is serif, ~13.5px, in a desaturated blue-grey rather than ink — it
belongs to the sky, not the page.

## The two states

**Day** — washed sky, pressed *into* the paper. Two inset shadows do the
recessing, a hairline highlight along the bottom edge lifts it back out, and a
faint open-sky glow sits along the top lip.

**Night** (`.silk-night` on any ancestor) — the same window, now holding dusk.
It becomes the screen's single lit object: the gradient deepens to a dusk-blue
lacquer and an outer `0 0 34px rgba(78,134,184,.16)` glow spills onto the
surrounding dark.

This inversion is the point of the component. During the day the aperture is a
quiet recess; at night, when everything else has dimmed, it is the only thing
awake. Both states transition over `.8s ease`, so a day→night switch reads as
dusk falling rather than a theme toggle.

## Rules

- **One aperture per screen.** It is the down-hours window, singular.
- Don't put it on a coloured surface — it is calibrated against warm paper
  (`--silk-paper`) and night lacquer (`--silk-lacquer`) and nothing else.
- Don't resize it. The gradients are pixel-tuned to 234×56; scaling smears the
  glass and the recess reads as a plain grey pill.
- Keep the content to a time range, with the ☾ glyph and a non-breaking space.
  It is a label, not a control — no chevron, no tap target styling.
- Don't reuse it as a generic pill or badge. If you need a pill, use
  `.silk-btn-accept` or plain type.
