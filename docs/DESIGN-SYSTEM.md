# Blazebunny design system

How big things are, and why. The code is the source of truth: `Sources/Blazebunny/DesignSystem.swift`
(tokens) and `Typeface.swift` (fonts). This page records the reasoning and where it came from, so the
next decision starts from the same place instead of from taste.

## How to decide a size (the method)

1. Start from what the information *is* (a title, a control label, a number you scan, a note), not
   from how it should look.
2. Pick the matching **role** below. Never type a literal size in a view: add or reuse a token.
3. Build hierarchy with **size, weight and colour together** and keep the number of levels small
   (primary / secondary / tertiary). De-emphasise the secondary thing instead of shouting the primary.
4. Check it in the real app with real data (a 23k library, a long name, a ghost frame), not on a mock.
5. If a role is missing, add it here first with the reason and a source, then in code.

## Type scale

Base: Apple's macOS text styles (13 pt body). Typeface: Space Grotesk for words, Space Mono for
numbers and data (switchable off in Preferences, then SF).

| Role (`DS.TextStyle`) | Size / weight | Used for | Why this size |
|---|---|---|---|
| `display` | 40 / regular, mono | the one big statistic (library count) | One display number per screen; large enough to read from across the desk; regular, not light (see rules). |
| `title` | 20 / medium | page or view title in the header row | Between Apple Title 2 (17) and Title 1 (22); fits the 52 pt header row without crowding the filters. At 24 light it overpowered the ghost frame. |
| `headline` | 13 / semibold | sheet and popover headings | Apple Headline. |
| `reading` | 15 / regular | the prompt in the inspector | Text people actually read in sentences: Apple Title 3 size, comfortable measure at the inspector width. |
| `body` | 13 / regular | sidebar rows, default copy | Apple macOS default size. |
| `label` / `labelStrong` | 12 / regular, semibold | pills, inspector rows, footer, table values | Apple Callout; dense but legible. |
| `meta` / `metaStrong` | 11 / regular, semibold | counts beside titles, notes, badges | Apple Subheadline; secondary information that must stay readable (the footer was too small at 10). |
| `caption` / `captionStrong` | 10 / medium, semibold | section captions, key hints | Apple's minimum for macOS; never go below. |

Rules:
- **Numbers and data are mono, words are sans.** Mono numbers align in columns and read as data.
- **Avoid light weights** for UI text (Apple: they are hard to see when small). Regular, medium,
  semibold, bold only. Large display numbers are the one place we could go lighter; we currently
  do not.
- **Secondary = lighter colour, not thinner or smaller.** Use `.secondary` / `.tertiary` colours
  before shrinking text; never below 10 pt.
- **Uppercase is for tiny section captions only**, with a little tracking, never for sentences.
- **Line height:** keep Apple's pairing (13/16, 12/15, 11/14, 10/13); for three or more lines of
  text do not tighten the leading.
- **One title per view.** Do not repeat the same name in the window title, header and sidebar at
  different sizes; the header row owns it.

## Spacing, size and shape

- 4 pt base grid, 8 pt for layout (`DS.Space`: 4, 8, 12, 16, 24). 4 pt for tight internals (icon
  padding, pill padding); 8 and up between components.
- Controls are 28 pt high (`DS.Size.control`); the header row is 52 pt; the footer 32 pt.
- Radii: 4 / 6 / 8 for small things and thumbnails, 16 for glass panels. Capsules for pills.
- Hairline borders at 9% white; one accent at a time; ghost tint (amber) only for ghosts.

## Icons

- Line icons, not filled. SF Symbols by default (they are line-weight matched to SF/Space text);
  custom line shapes where SF has nothing right (the ghost). Bundled icon sets (Lucide, ISC) only
  with a `NOTICE` entry.
- Icon size follows the text next to it: 14 to 16 pt beside body/label text, 18 pt beside the
  20 pt title.

## Ghost folders

Temporary and private must be impossible to miss, so they use several redundant signals: amber
line-ghost icon, dashed outline (dashed = temporary/anonymous), a "Ghosts" sidebar section, a
badge and "Deleted when closed". The title inside the frame stays at the normal `title` size: the
frame carries the signal, the text stays calm.

## Where to look when deciding (and what each is good for)

Check these before inventing a size or a pattern, and add what you learn here.

- **Apple Human Interface Guidelines, Typography** (primary source for macOS sizes, weights,
  minimums, hierarchy advice): https://developer.apple.com/design/human-interface-guidelines/typography
  (the `.md` suffix returns the full text with the tables). macOS table read on 2026-11-17:
  Large Title 26/32, Title 1 22/26, Title 2 17/22, Title 3 15/20, Headline 13/16 bold,
  Body 13/16, Callout 12/15, Subheadline 11/14, Footnote 10/13, Caption 1 10/13, Caption 2 10/13
  medium; default 13 pt, minimum 10 pt; "avoid light font weights"; "adjust font weight, size,
  and color ... to help people visualize hierarchy".
- **WWDC20 "The details of UI typography"** (tracking, leading, optical sizes):
  https://developer.apple.com/videos/play/wwdc2020/10175/
- **Refactoring UI** (Adam Wathan, Steve Schoger): hierarchy through weight and colour, not size
  alone; de-emphasise secondary information; labels vs values. Article excerpt:
  https://medium.com/refactoring-ui/7-practical-tips-for-cheating-at-design-40c736799886
  Treat third-party summaries of the book as examples, not rules.
- **Type scales and grids:** modular scales with a tight ratio for dense UIs, 4 pt for internals
  and 8 pt for layout (Material uses an 8 pt component grid and a 4 pt baseline): see the Uxcel
  lessons on typography systems https://uxcel.com/lessons/typography-systems-020 and the Figma
  design-systems typography guide https://www.designsystems.com/typography-guides/
- **Liquid Glass / system chrome:** the `liquid-glass` and `swiftui-expert` skills, for anything
  that touches system controls.

## Open questions

- Dot-matrix numerals for statistics (reference style): trial on `display` only.
- A larger `title` for empty states and the viewer; decide with the viewer design (M6).
