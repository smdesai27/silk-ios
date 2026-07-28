# Shield

The wall that appears instead of the app. It is Silk's most important moment and
its most restrained: the user has just been stopped, and the screen's job is to
be **unarguable** rather than persuasive.

> Wall — the mark and the name; nothing to argue with.

## Markup

```html
<div class="silk-shield">
  <svg class="silk-shield__mark" viewBox="0 0 200 200"><use href="#enso-s"/></svg>
  <div class="silk-shield__until silk-serif">Until 5:00</div>
  <div class="silk-shield__app">Instagram</div>
  <button class="silk-shield__ok">OK</button>
</div>
```

`position:absolute; inset:0` with a `blur(20px)` backdrop — it covers its
positioned ancestor entirely. The blurred paper at `.92` alpha means the app
behind stays faintly visible: you can see what you were reaching for, and it is
out of focus.

## The three shields

| Shield | `__until` | `__app` |
|---|---|---|
| **Wall** — a hard block | the app name (`Instagram`) | empty |
| **Ruled** — a rule holds it until an hour | `Until 5:00` | the app name |
| **Down hours** — the night is answering | `☾ 7:00 AM` | the app name |

The largest thing on the wall is always serif and always **when**, not what
(except the Wall shield, where there is no when). Use `.silk-night` for the
down-hours variant — "the night answers, not the app."

## The button

One button. It says `OK`. It is an outlined rectangle at 16px radius — deliberately
*not* the ink pill used for `Accept`, because acknowledging a wall is not the same
gesture as accepting a proposal.

**There is no second button.** No "15 more minutes", no "Dismiss", no override,
no countdown-to-unlock. Adding an escape hatch here does not make Silk gentler;
it makes the wall a negotiation, and then it is not a wall.

## Don't

- Don't explain, justify, or encourage. No "You've used 45 of 40 minutes",
  no streak, no emoji, no "Great job staying focused!".
- Don't animate the entrance beyond a fade. It should feel like a door that was
  already closed, not a modal that arrived.
- Don't add a settings shortcut. The command bar on the Now screen is where
  rules change — not here, not mid-block.
