# Type

Two voices, and the split between them is the strongest signal in Silk.

- **Sans** (`--silk-font-sans`, SF Pro) is the *interface*: app names, labels,
  observations, buttons.
- **Serif** (`--silk-font-serif`, New York) is the *editorial voice*, and it is
  **locked** to two jobs: **numerals**, and **sentences Silk speaks in its own
  voice** — the greeting, the ask, the equation.

Apply serif with `.silk-serif` (or `.ny`; both are defined and identical). The
class also sets `tabular-nums lining-nums` and `font-feature-settings:'tnum','lnum'`,
so digits hold their width as a number ticks down. Never set serif via
`font-family` alone — you lose the numerics.

## The roles

| Role | Family | Size | Tracking | Colour |
|---|---|---|---|---|
| Hero numeral | serif | 92px / lh 1 | `-.045em` | `--silk-ink` |
| Shield numeral | serif | 40px | `-.02em` | `--silk-ink` |
| Greeting | serif | 21px | `-.005em` | `--silk-ink-90` |
| Ask (proposal) | serif | 17px | — | `--silk-ink-92` |
| Body / door name | sans | 15px | `-.005em` | `--silk-ink-84` |
| Equation | serif | 14.5px | `.005em` | `--silk-ink-58` |
| Door time | serif | 14px | — | `--silk-ink-50` |
| Observation | sans | 13.5px | — | `--silk-ink-70` |
| Label | sans | 12.5px | `.015em` | `--silk-ink-52` |
| Chart title | sans | 12px | `.04em` | `--silk-ink-48` |
| Wordmark | sans 500 | 11px | `.34em` | `--silk-ink-62` |
| Chart tick | sans | 10px | `.02em` | `--silk-ink-42` |

Two patterns run through the whole table: **display type tightens**
(`-.045em` on the hero) and **small type opens** (`.34em` on the wordmark). Type
in between sits near zero.

## The wordmark

```html
<span class="silk-wordmark__text">SILK</span>
```

11px, weight 500, `.34em` tracking, and `margin-right: -.34em` to claw back the
trailing letterspace so it optically centres. Drop that negative margin and the
wordmark sits visibly left of centre next to the mark.

## Sentences

Silk speaks in short, complete sentences with terminal punctuation — "Good
afternoon." not "Good afternoon". Questions end in a question mark and are the
only thing `.silk-card__ask` ever contains.

Labels are lowercase and unpunctuated: "min left today", not "Min Left Today" or
"Minutes remaining today".

## Don't

- Don't set a numeral in sans, anywhere.
- Don't set a UI label in serif — serif is Silk's voice, and a serif label
  makes the interface sound like it's talking when it isn't.
- Don't add a third family. The mono stack (`--silk-font-mono`) exists only for
  spec annotations in the foundation cards and never ships in product UI.
- Don't use weights above 500. Silk has no bold.
