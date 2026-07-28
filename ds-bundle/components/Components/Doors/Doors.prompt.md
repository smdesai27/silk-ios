# Doors

Silk's app list. They are called doors, not rows, and the naming is load-bearing:
a door is a threshold you may or may not pass, so the component shows **state**,
never a control. There is no toggle, no chevron, no "Manage" button.

## Markup

```html
<div class="silk-doors">
  <div class="silk-door silk-door--live">
    <span class="silk-door__name">Instagram</span>
    <span class="silk-door__time silk-serif">&nbsp;· 5:00</span>
    <span class="silk-door__state"></span>
  </div>
  <div class="silk-door silk-door--rest">
    <span class="silk-door__name">YouTube</span>
    <span class="silk-door__time silk-serif"></span>
    <span class="silk-door__state"></span>
  </div>
</div>
```

`.silk-doors` supplies the `26px 46px 0` inset. Each door is 52px tall with a
`.055` alpha rule beneath it — the faintest line Silk draws — and the last one
drops its rule automatically.

The time **must** carry `.silk-serif`. Names are sans, durations are serif; that
split is the whole typographic idea and it repeats everywhere in Silk.

## States

| Modifier | Meaning | Dot |
|---|---|---|
| `--live` | in play today | filled, ink at .72 |
| `--rest` | not in play; name also dims to .44 and drops to weight 400 | hollow outline ring |
| `--open` | a grant is running right now | **filled leaf** (`--silk-leaf`) |

`--open` is the only door that gets the leaf pop, and it is usually the only pop
on the screen. Pair it with a countdown in `.silk-door__time`. Give at most one
door `--open` at a time — two leaf dots and the accent stops meaning anything.

The dot is 6px and sits at `margin-left:auto`, so it pins right regardless of how
long the name is. Leave `.silk-door__time` present but empty for resting doors so
the baseline stays put.

## Night

Add `.silk-night` to any ancestor. Everything dims under lacquer — names to .36,
times to .26, rules to .05 — **except** the `--open` leaf dot, which keeps its
colour. A grant that is running is still running after dark.

## Don't

- Don't add icons or app artwork. Doors are typographic.
- Don't make the whole row a button-looking surface — no fill, no border, no
  hover background. `cursor:pointer` is already set; that is the entire affordance.
- Don't reorder doors by usage. Silk keeps them stable so the list is a place, not a leaderboard.
