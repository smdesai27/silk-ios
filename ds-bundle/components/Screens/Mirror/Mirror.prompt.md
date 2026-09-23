# Mirror

> **Note, 19 September 2026.** The app's Mirror is the score, the week band and
> today's unlocks, standing in a hedgerow. The equation, the attempts chart and
> the proposal card were all dropped; the sections below that prescribe them are
> marked where they stand. What follows is the mockup's record, not something to
> build from.

Silk's second screen and, in the mockups, its last — the reflection. Now is
about what's left; Mirror is about what happened. It is where the week is
shown, and where the mockups have Silk propose changes.

## Composition

```html
<div class="silk-screen">
  <div class="silk-dapple"></div>
  <div class="silk-island"></div>

  <div class="silk-hero" style="margin-top:96px">
    <div class="silk-enso-wrap silk-enso-wrap--mirror">
      <svg viewBox="0 0 200 200"><use href="#enso-82"/></svg>
      <div class="silk-hero-inner">
        <div class="silk-hero-num silk-serif">82</div>
        <div class="silk-hero-label">Sunday</div>
      </div>
    </div>
  </div>

  <div class="silk-eq silk-serif">82 = 100 − 12 attempts − 6 late</div>

  <div class="silk-chart">…</div>
  <div class="silk-card">…</div>
  <div class="silk-footnote silk-serif">⚿ 1 · Jul 12</div>

  <div class="silk-cmdbar">…</div>
  <div class="silk-dots">
    <span class="silk-dot"></span><span class="silk-dot silk-dot--active"></span>
  </div>
  <div class="silk-home"></div>
</div>
```

Order: **score → equation → chart → proposal → footnote**. The app keeps the
first and the last of those and drops the middle three; what it stacks is score
→ week band → footnote. Note there is no wordmark and no greeting — Mirror
opens straight on the number, and it starts lower (`margin-top:96px`) to make
room for that silence.

The second page dot is the active one.

## The score

`--mirror` drops the ensō to 190px, draws it in **ink** rather than leaf, and
sets the numeral at 72px. Mirror reflects a finished day, so it is drawn in the
same ink as the rest of the page — the live leaf belongs to Now.

The label under the score is the **day name** (`Sunday`), not a unit.

## The equation

> **Retired.** The app prints no equation: how the score is calculated is not
> something it carries on the page (`Silk/MirrorView.swift`). The rule below is
> the mockup's, and it no longer binds.

```html
<div class="silk-eq silk-serif">82 = 100 − 12 attempts − 6 late</div>
```

Silk always shows its work. The score is never a black-box number: the equation
states exactly what was subtracted and why, in serif, at ink `.58`. Use proper
minus signs (`−`, U+2212), not hyphens.

This is Silk's answer to the scoring problem — if you can't write the equation,
don't show the score.

## The proposal

> **Retired.** Nothing in the app draws a proposal card, on Mirror or anywhere
> else.

Mirror is the **only** place a proposal card appears. Silk noticed something in
the week's data, and here is where it asks. One card, never a stack.

## Footnote

`⚿ 1 · Jul 12` — the count of rules currently held and the date they were last
changed. Serif, ink `.45`, centred, quiet.

> **Changed.** The app's footnote is today's unlocks — how many times a door was
> opened since the day began — not a count of rules.

> **Known issue:** `⚿` (U+269F) is missing from most system fonts and renders as
> a tofu box. Substitute a key or lock glyph that your target font actually has.

## Don't

- Don't add a date range picker, a month view, or history navigation. Mirror is
  the last seven days, full stop.
- Don't add per-app breakdowns, pie charts, or "time saved" estimates.
- Don't show the score without the equation. Retired with it: the app shows the
  score alone.
