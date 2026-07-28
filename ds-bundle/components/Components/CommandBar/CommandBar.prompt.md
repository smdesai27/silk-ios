# Command bar

The single input in Silk. Everything the user wants to change — rules, budgets,
down hours, grants — is said here in words. There is no settings screen behind it.

## Markup

```html
<div class="silk-cmdbar">
  <input type="text" placeholder="Tell Silk…" autocomplete="off">
  <span class="silk-cmdbar__mic" title="Speak">
    <svg width="18" height="18" viewBox="0 0 24 24"><use href="#mic"/></svg>
  </span>
</div>
```

Absolutely positioned: `left:28px; right:28px; bottom:44px`, 52px tall, 26px
radius. It expects a positioned ancestor — normally `.silk-screen`.

## It is a hairline, not a field

> Day — a hairline on the paper, nothing more.

`background: transparent` and a 1px border at ink `.14`. **Never fill it.** A
filled input turns Silk into a chat app, which is exactly what it isn't: the
command bar is available, not inviting. It should recede until you want it.

The placeholder is `Tell Silk…` — with the ellipsis character, not three periods.

## Night

`.silk-night` dims the hairline to paper `.12` and the mic to `.42`, over a
`.8s ease` transition. Same object, less light.

## Page dots

The command bar is usually accompanied by page dots, which sit below it:

```html
<div class="silk-dots">
  <span class="silk-dot silk-dot--active"></span>
  <span class="silk-dot"></span>
</div>
```

Two dots — Now and Mirror. Silk is two screens deep and should stay that way.

## Don't

- Don't add a send button. Return sends; the mic is the only affordance.
- Don't add suggestion chips, autocomplete dropdowns, or a command palette.
  It takes a sentence.
- Don't let it scroll with content — it is pinned to the screen, always in the
  same place.
- Don't stack anything below it except `.silk-dots` and the home indicator.
