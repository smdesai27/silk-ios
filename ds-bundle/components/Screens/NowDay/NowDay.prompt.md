# Now (day)

Silk's home screen, and the canonical composition — if you are building a new
Silk screen, start from this stacking order.

## Composition

```html
<div class="silk-screen">
  <div class="silk-dapple"></div>
  <div class="silk-island"></div>

  <div class="silk-wordmark">
    <svg class="silk-wordmark__mark" viewBox="0 0 200 200"><use href="#enso-s"/></svg>
    <span class="silk-wordmark__text">SILK</span>
  </div>
  <div class="silk-greet silk-serif">Good afternoon.</div>

  <div class="silk-hero">
    <div class="silk-enso-wrap">
      <svg viewBox="0 0 200 200"><use href="#enso-full"/></svg>
      <div class="silk-hero-inner">
        <div class="silk-hero-num silk-serif">40</div>
        <div class="silk-hero-label">min left today</div>
      </div>
    </div>
  </div>

  <div class="silk-aperture">
    <span class="silk-aperture__text silk-serif">☾&nbsp; 10:00 PM – 7:00 AM</span>
  </div>

  <div class="silk-doors">…</div>

  <div class="silk-cmdbar">
    <input type="text" placeholder="Tell Silk…" autocomplete="off">
    <span class="silk-cmdbar__mic"><svg width="18" height="18" viewBox="0 0 24 24"><use href="#mic"/></svg></span>
  </div>
  <div class="silk-dots">
    <span class="silk-dot silk-dot--active"></span><span class="silk-dot"></span>
  </div>
  <div class="silk-home"></div>
</div>
```

Order, top to bottom: **wordmark → greeting → ensō → aperture → doors →
command bar → dots**. Each block carries its own top margin (`62px` wordmark,
`32px` greeting, `22px` hero, `18px` aperture, `26px` doors), so you compose by
stacking, not by adding spacers.

`.silk-screen` is 390×800 with a 46px radius and `overflow:hidden`. The command
bar, dots and home indicator are absolutely positioned against it.

## Dapple

`.silk-dapple` is four barely-there radial gradients — warm yellows and one
cool green — pooled in the top 46% of the screen. Peak alpha is `.045`. It is
sunlight through leaves, and it should never be consciously noticeable; if you
can see it as a gradient, it's too strong.

It is the day screen's only texture. Don't add noise, grain, or a vignette.

## What makes it Silk

The screen is mostly empty, and the emptiness is the design. One number owns it.
Everything else is a quiet line of type. Resist adding: a header bar, a tab bar,
an avatar, a streak counter, a settings gear, a "today" summary card, or a
second metric. If new information needs a home, it goes on Mirror.

The greeting is time-aware and always a complete sentence — "Good afternoon."

## Pop budget

The leaf ensō is this screen's one pop. If a door is `--open` (leaf dot), that's
a second — acceptable only because the dot is 6px, but never add a third.
