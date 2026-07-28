# Attempts chart

Seven days of attempts — the number of times a door was tried. It lives on Mirror
and it is the only chart in Silk.

## Markup

```html
<div class="silk-chart">
  <div class="silk-chart__title">Attempts</div>
  <div class="silk-bars">
    <div class="silk-bars__col"><div class="silk-bar" style="height:53px"></div></div>
    <div class="silk-bars__col"><div class="silk-bar" style="height:32px"></div></div>
    <div class="silk-bars__col"><div class="silk-bar" style="height:43px"></div></div>
    <div class="silk-bars__col"><div class="silk-bar" style="height:21px"></div></div>
    <div class="silk-bars__col"><div class="silk-bar" style="height:64px"></div></div>
    <div class="silk-bars__col"><div class="silk-bar" style="height:21px"></div></div>
    <div class="silk-bars__col silk-bars__col--today"><div class="silk-bar" style="height:11px"></div></div>
  </div>
  <div class="silk-xlabels">
    <div class="silk-xlabels__col">Tu</div>
    <div class="silk-xlabels__col">We</div>
    <div class="silk-xlabels__col">Th</div>
    <div class="silk-xlabels__col">Fr</div>
    <div class="silk-xlabels__col">Sa</div>
    <div class="silk-xlabels__col">Su</div>
    <div class="silk-xlabels__col silk-xlabels__col--today">Today</div>
  </div>
</div>
```

Plot area is 64px tall over a single hairline baseline. Bars are **3px wide**,
ink at .28, with a 2px radius on the top corners only — they are strokes, not
columns. Set height inline in px against the 64px maximum.

## Today

`--today` on both the bar column and its label. The bar widens to 5px and turns
`--silk-leaf`; the label goes to ink .72 and weight 500. That leaf bar is
typically **the screen's one pop** — if a door is also `--open` on the same
screen, drop one of them.

Labels are two-letter day abbreviations (`Tu`, `We`, …) with the last reading
`Today`, not the day name.

## Rules

- **Seven columns, always.** A rolling week, not a selectable range.
- No y-axis, no gridlines, no value labels, no tooltips. The shape is the
  information; exact counts live in the Mirror equation above it.
- Don't add a second series, don't stack, don't colour bars by app.
- Don't sort. Chronological left-to-right, today last.
- Lower is better here — Silk never inverts the axis to make a bad week look
  like a tall bar.
