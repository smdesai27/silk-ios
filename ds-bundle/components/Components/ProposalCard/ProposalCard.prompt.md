# Proposal card

How Silk asks for something. It appears when Silk has noticed a pattern and wants
to propose a rule change. The structure is fixed and it is a small argument:
**observation → ask → one clear yes, one quiet exit.**

## Markup

```html
<div class="silk-card">
  <div class="silk-card__obs">Most of your Instagram time follows the 9&nbsp;PM pickup.</div>
  <div class="silk-card__ask silk-serif">Start down hours at 9:30&nbsp;PM?</div>
  <div class="silk-card__actions">
    <button class="silk-btn-accept">Accept</button>
    <button class="silk-btn-later">Not now</button>
  </div>
</div>
```

Linen ground (`--silk-linen`), 20px radius, inset `34px 40px 0`. This is one of
the only raised surfaces in Silk — the card lifts off the paper because Silk is
speaking rather than reporting.

## The two voices

- **`__obs`** — sans, 13.5px, ink at .70. A fact, stated flatly. No adjectives,
  no judgement. "Most of your Instagram time follows the 9 PM pickup." — not
  "You're spending too long on Instagram at night."
- **`__ask`** — **serif**, 17px, ink at .92. Always a question, always ends in a
  question mark. This is Silk's own voice and serif is what marks it as such.

Getting these backwards — serif observation, sans ask — is the most common way
to break the component.

## The actions

`Accept` is an ink pill (999px radius, paper text). `Not now` is bare text at
ink .50 — no border, no background, no second pill. The asymmetry is deliberate:
one obvious yes, one exit that costs nothing and isn't shamed.

Use `Not now`, not "Dismiss", "Cancel", or "No". Silk's proposals come back.

## Rules

- **One proposal at a time.** Never a stack or a feed of cards.
- The ask must be answerable with a single yes. If it needs a picker, a slider,
  or three options, it isn't a proposal — it belongs in the command bar.
- Don't add a close (×) affordance. `Not now` is the dismissal.
- Don't put it on a night screen. Silk proposes on Mirror, in daylight, when the
  day is being reflected on — not while you are being blocked.
