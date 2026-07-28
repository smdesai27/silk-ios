# Now (down hours)

The same screen as [Now (day)](../NowDay/NowDay.prompt.md), after the down-hours
window opens. Identical structure — add `.silk-night` to `.silk-screen` and swap
two things.

```html
<div class="silk-screen silk-night">
  <div class="silk-moonwash"></div>
  …
</div>
```

## What changes

**1. Dapple → moonwash.** Replace `.silk-dapple` with `.silk-moonwash`: a single
cool 340×340 pool behind the hero at `rgba(110,127,138,.09)`. Daylight was
scattered across the top of the screen; moonlight is one source.

**2. The hero stops counting.** The numeral is replaced by the moon glyph at
80px, and the label becomes the hour the window closes:

```html
<div class="silk-hero-num silk-serif" style="font-size:80px">☾</div>
<div class="silk-hero-label">7:00 AM</div>
```

There is no budget during down hours — nothing is being spent, so there is
nothing to count. Showing `0` here would be wrong: zero is a failure state, and
this is rest.

Everything else — greeting ("Good evening."), aperture, doors, command bar, dots
— stays exactly where it was.

## The inversion

Every other element steps down: door names to paper `.36`, times to `.26`,
rules to `.05`, the ensō from leaf to dusk blue. The **aperture steps up** — it
becomes the screen's single lit object, glowing open-sky onto the lacquer.

That is the whole idea of the night screen. During the day the aperture is a
recess you barely notice; at night it is the only thing awake, and it is the
thing that is currently in charge.

Because both states share the same markup and the aperture transitions over
`.8s ease`, moving between them reads as dusk falling rather than a theme flip.

## Don't

- Don't brighten anything to "keep it usable". Night is deliberately harder to
  read; that is the feature.
- Don't add a "wake up" or override control. The command bar still works — that
  is enough.
- Don't switch on `prefers-color-scheme`. Silk's night follows the user's
  down-hours window, not their system theme.
