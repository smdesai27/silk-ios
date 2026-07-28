# Color

Silk has two grounds and almost no hues. Everything you see is an alpha ramp of
ink on warm paper, or of paper on night lacquer. Introducing a new colour is
almost always the wrong move.

## The palette

| Token | Hex | Role |
|---|---|---|
| `--silk-paper` | `#F6F3EC` | warm paper — the day ground |
| `--silk-linen` | `#EFE9DB` | unbleached linen — the only raised surface (proposal card) |
| `--silk-ink` | `#211E17` | warm ink — day foreground, the `Accept` pill |
| `--silk-lacquer` | `#16130E` | night lacquer — the night ground |
| `--silk-washed-sky` | `#D8DCD3` | the aperture's day glass |
| `--silk-moss` | `#8A9484` | muted green |
| `--silk-pine-shadow` | `#4A5A50` | deep muted green |
| `--silk-dusk-blue` | `#6E7F8A` | the night ensō |
| `--silk-leaf` | `#5F8A52` | **pop** — day accent |
| `--silk-open-sky` | `#4E86B8` | **pop** — night accent, only inside the aperture's glow |

Nothing is pure white or pure black. `#F6F3EC` and `#211E17` are both warm, and
that warmth is most of why Silk reads as paper rather than as a UI.

## The ramps

Use the ramp tokens rather than writing `rgba()` by hand — they encode the exact
alphas the design uses:

- **Day:** `--silk-ink-92` … `--silk-ink-055` (ink on paper)
- **Night:** `--silk-paper-92` … `--silk-paper-05` (paper on lacquer)

Landmarks worth knowing: `.84` body text, `.52` labels, `.40` placeholders,
`.14` the command-bar hairline, `.055` the door rule — the faintest line Silk
draws. When something needs to recede, drop it down the ramp; don't tint it.

## One pop moment per screen — a wall, not wallpaper

The two pop colours are rationed to a single element per screen. On Now that is
the leaf ensō. On Mirror it is the leaf `Today` bar. At night it is the aperture's
open-sky glow. If you have added a second pop, remove one — the accent's power is
entirely in its scarcity.

Semantic colour does not exist in Silk. There is no red for error, no amber for
warning. A door that is out of budget doesn't turn red; it stops being available,
and a shield appears.

## Night is not dark mode

`.silk-night` is the same room after sunset, not an inverted theme. Content
dims *further* than a dark theme would — door names sit at `.36`, times at
`.26` — because at night Silk wants to be less legible, not equally legible.
The one thing that gets brighter is the aperture.
