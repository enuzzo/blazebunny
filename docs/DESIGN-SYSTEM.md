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

Base: Apple's macOS text styles (13 pt body). Typeface: Space Grotesk for words (variable font,
real weights 300 to 700), Space Mono for numbers and data (Regular and Bold); switchable off in
Preferences, then SF. Measured facts behind the choices (round 3, 2026-11-17): the mono's x-height
and cap height match the sans, but it is about 12% wider; its punctuation takes a full character cell;
its line box is 1.48 em against 1.28 em.

| Role (`DS.TextStyle`) | Size / weight | Mono size | Tracking | Used for | Why |
|---|---|---|---|---|---|
| `display` | 40 / regular (mono) | 40 | thousands separator pulled in by 0.3 em | the one big statistic | One display number per screen; the separator would otherwise read "23 . 193". Sits on one baseline with its unit. |
| `title` | 20 / medium | n/a | -0.3 | page or view title | Between Apple Title 2 (17) and Title 1 (22); tighter tracking at larger size. |
| `reading` | 15 / regular | n/a | 0 | the prompt | Text read in sentences; about 22 pt leading. |
| `headline` | 13 / semibold (600) | n/a | 0 | popover and sheet titles, month headers | Real 600 gives a clear step over body. |
| `body` | 13 / regular | n/a | 0 | sidebar rows, default copy | Apple macOS default. |
| `label` / `labelStrong` | 12 / regular, semibold | 11.5 | 0 | pills, inspector rows, footer | Apple Callout. Mono 0.5 pt smaller evens the width. |
| `meta` / `metaStrong` | 11 / regular, semibold | 10.5 | 0 | counts, notes, sidebar section titles | Apple Subheadline. |
| `caption` | 10 / semibold, UPPERCASE | n/a | +0.6 | inspector section titles | Apple minimum; looser tracking for small caps. |

Rules:
- **Numbers and data are mono, words are sans**, including inside one line: `RichText` sets
  "23.193 indexed" with the number in mono and the word in sans.
- **Levels are kept apart by colour and weight, not by more sizes.** 13, 12, 11 are close (ratio about
  1.08); do not add 14 or 16.
- **Avoid light weights** for UI text. Regular, medium, semibold, bold only.
- **Secondary = secondary colour, not thinner or smaller.** Tertiary is never used for text (2.2:1).
- **Uppercase only for the tiny `caption` role**, never sentences.
- **One rule for tables:** the thing you compare is primary (counts, values); names and labels in the
  inspector keep their colour as the label side.
- **One title per view.** The header row owns it.

## Colour

Dark window `#0C0D0F`. Text uses the system levels so it adapts to Increase Contrast.

| Token | Value | Use |
|---|---|---|
| text primary / secondary | system `.primary` (about 0.85) / `.secondary` (about 0.55); 14.0 / 6.3 on the window | values and titles / labels and notes |
| `Palette.hairline` | white 0.09 | panel edges (decorative, exempt from the 3:1 rule) |
| `Palette.rowRule` | white 0.10 | table row rules (one rule, never doubled) |
| `Palette.controlStroke` | white 0.20 | outline of a control that is off (1.8:1; the chevron is the second cue) |
| `Palette.dataBar` / `dataTrack` | white 0.45 / 0.08 | bars that show proportion: neutral, never the accent |
| `Tint.activeText` | accent lightened 35% | text of an active filter (about 8:1) |
| accent (system) | unchanged | selection and active state only, never data |
| `Tint.midjourney` | #ADB8FF | source Midjourney, only where it is named |
| `Tint.stableDiffusion` | #8ED6A0 | source Stable Diffusion |
| `Tint.camera` | #7CCFE3 | source camera |
| `Tint.ghost` | #F2B861 | ghosts only |
| `Tint.warning` | #F57361 | offline / needs attention |
| `Tint.fill` | 0.15 | opacity of every tinted fill |

Rules: one accent at a time; a source tint appears only where that source is named; status shows by
exception (the connected-drive icon is neutral, the offline one is coral); a group label that is not a
control is secondary and only its icon carries the tint, so it never reads as an active filter.

## Tables and bars: one grid

Every table sits on one clean column grid, so rows compare at a glance. For a table with bars
(Types, Sources): label (flexible) | bar (constant width, `DS.Size.dataBar`) | count (right-aligned
mono in ONE fixed width for the whole table, sized for its longest number:
`digits * DS.Size.monoDigitWidth`). Bars therefore start and end at the same x in every row whatever
the number looks like; a count with more digits must never push its bar. The same applies to the
label | value columns of the inspector: one label column width (`DS.Size.inspectorLabel`), values
left-aligned on the same x.

## Spacing, size and shape

- 4 pt base grid, 8 pt for layout (`DS.Space`: 4, 8, 12, 16, 24; `iconGap` 6 between a small icon and its
  label in a control, `pillInset` 10, `iconText` 10 in sidebar rows). 4 pt for tight internals (icon
  padding, pill padding); 8 and up between components.
- Controls are 28 pt high (`DS.Size.control`); the header row is 52 pt; the footer 32 pt.
- Radii: 4 / 6 / 8 for small things and thumbnails, 16 for glass panels (all from `DS.Radius`). Capsules
  for pills. Status badges are `DS.Size.badge` (22) high, whatever their kind.
- Hairline borders at 9% white; one accent at a time; ghost tint (amber) only for ghosts.

## Sidebar

- Section titles all use one style (`SidebarHeader`: `headline`, 13 pt semibold, secondary colour): the
  same size as the rows below, set apart by weight and colour only (owner, 2026-11-17: a title smaller
  than its content looked wrong). Only the Ghosts title gets the amber tint and icon. A section title must say what the section *is*
  ("Libraries", "Views", "Saved Searches"), never repeat a name that is already on screen (the
  library name above the views was removed: it added nothing).
- Rows are 28 pt (`DS.Size.sidebarRow`) with a fixed 20 pt icon column and a 10 pt gap (`DS.Space.iconText`)
  before the text. Rows sit flush with the section title's left edge (no extra inset); only the Folders
  section keeps a 14 pt chevron column in front of the icon (so folders with and without subfolders line
  up) and indents 14 pt per level (`DS.Size.sidebarIndent`). Counts are the mono, secondary, right-aligned.
- Folders (stage 1): the tree mirrors the disk, siblings sorted with `localizedStandardCompare`, counts are
  the number of images in the folder *and everything below it*. A folder with no image anywhere below it is
  hidden (a folder of documents or an empty one is noise in an image browser; the Core tree still has them).
  Which folders are open is remembered per library (`expandedFolders` in UserDefaults), never for a ghost.
- Context line above the title (`ContextLine`, 11 pt): `Folder · library › parent`, `Saved search · live · in
  library › folder`, `View · in library`, `Library · everything, subfolders included`; the parts that lead
  somewhere are clickable. Kind in `metaStrong`, the rest `meta`, all secondary (ghost: amber kind).
- Primary things (libraries) and secondary things (views, saved searches) share the 13 pt body
  size; hierarchy comes from the section titles and spacing, not from many sizes.

## Sidebar: alive, not dull

Owner's note (2026-11-17): the sidebar is too muted; it should feel lively and pleasant, like Claude's own
session sidebar, without becoming a rainbow. Direction:
- **A soft coloured glow** behind the sidebar (cool blue to violet at low opacity, a little stronger than
  the main window's backdrop), so the glass has something to refract. Reduce Transparency removes it.
- **Colour in small, matched doses, on icons and dots only:** each kind of thing gets one tint of equal
  lightness (library, folder, saved search, collection, tray; ghost stays amber, offline coral). Text stays
  neutral; selection stays the system accent but as a clearly tinted fill with a thin leading marker rather
  than a flat grey. The palette is the existing matched-lightness tints (indigo #ADB8FF, green #8ED6A0, teal
  #7CCFE3, amber #F2B861, coral #F57361) plus at most two new ones chosen the same way; every pair keeps 3:1
  against the glass and never carries meaning by colour alone.
- **Rhythm and weight:** 28 pt rows, 20 pt icon column, 10 pt icon gap, section titles semibold 11 pt; row text
  at primary colour (not dimmed), counts in the mono and secondary. Hover and press feedback visible.
- **Small delight:** a short spring on expand/collapse and on drag targets; respects Reduce Motion.
- Still one accent at a time per region, and no glass over the image grid.

### Sidebar as built (stage 1)

- Tints (icon only, text stays neutral): library `Tint.library` violet #C2A8FF (the one new tint), folders
  `Tint.folder` #8ED6A0, Generated and Photos their source tints, other views secondary; saved searches keep
  their user-chosen colour dot. Pink is reserved for collections (stage 4).
- Selection: accent at 30% (`Tint.selection`) with a 3 x 14 pt accent marker at the leading edge; the
  system's grey selection is switched off (`SidebarTableTweaks`, `selectionHighlightStyle = .none`).
  Hover: white 7%. Both fade in 0.12 s, no animation with Reduce Motion.
- Glow: `SidebarGlow`, violet at the top left and cool blue at the bottom right, drifting a few points,
  under the 50% ultra-thin material. Reduce Motion stops the drift; Reduce Transparency removes glow and
  material (solid window colour).
- Chevron turns with a short spring (off with Reduce Motion).

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
