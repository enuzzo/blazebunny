# AGENTS.md — Blazebunny

Guidance for coding agents (and humans) working in this repository.

## What this is

A native macOS image-archive browser. Design: `docs/superpowers/specs/2026-11-16-blazebunny-design.md`.
Current plan: `docs/superpowers/plans/2026-11-16-blazebunny-m1.md`.

## Layout

- `Sources/BlazebunnyCore` — everything that is not UI: PNG text reader,
  Midjourney prompt parser, metadata reader, SQLite index, scanner, thumbnail
  packs. Must stay fully unit-tested.
- `Sources/Blazebunny` — SwiftUI app with an AppKit `NSCollectionView` grid.
- `Sources/bbbench` — CLI that runs the scanner on a folder and prints timings.
- `Sources/bbscopebench` — CLI that builds a generated 100k index (rows shaped like a real library's)
  and times every query the app makes against the speed budgets; `--extra` adds what the UI feels
  while a scan writes.
- `Tests/BlazebunnyCoreTests` — Swift Testing; fixtures are generated in code.
- `Tests/BlazebunnyTests` — the app's own logic that is not UI (grid snapshots, thumbnail loader,
  the model's ghost lifecycle).
- `scripts/build-app.sh` — assembles and ad-hoc signs `build/Blazebunny.app`.

## Rules

- **Never write inside a scanned folder.** Open source files read-only; never
  rename, touch dates, or create files next to them. A test guards this.
- **No third-party dependencies.** Apple frameworks and the system SQLite only.
  This is about code. **Free, openly licensed resources may be bundled** (fonts under
  the SIL OFL, line icons under ISC/MIT): unmodified, with the licence text kept in
  `Resources/` and each one listed in `NOTICE` before it is committed. Currently:
  Space Grotesk (text) and Space Mono (numbers and data), switchable off in Preferences.
- **No real user data in the repo.** Never commit real images, prompts, author
  names or file names from anyone's archive. Tests build their own PNGs.
- **No network access** in the app.
- Code, comments, docs and commit messages in English.
- Run `swift test` before committing; run `gitleaks dir .` before the first
  commit and `gitleaks git .` before pushing.
- **Speed is a feature** (the budgets are in
  `docs/superpowers/specs/2026-11-17-libraries-and-folders-design.md`). Nothing that grows with the
  library runs on the main thread: the grid's data is a `GridSnapshot` made off the main thread, views
  read the index through its read-only connections, thumbnails are read with `pread` from the location
  each `BrowseItem` carries. A SwiftUI view reads only what it shows (a new piece of state that changes
  often gets its own small view). Measure before and after with the commands below and record the
  numbers in `docs/MILESTONES.md`; an optimisation that does not show in them is reverted.
- Swift 6 language mode; macOS 15 minimum.
- **UI goes through the design system** in `Sources/Blazebunny/DesignSystem.swift`:
  spacing from `DS.Space`, sizes from `DS.Size`, radii from `DS.Radius`, tints
  from `DS.Tint`. Toolbar: system controls only (view-level actions such as
  Save Search live there). Filter row: `PillStyle` only, 28 pt. Inspector: one
  prominent button (Copy Prompt), the rest bordered, regular size. No one-off
  sizes or colours in views.
- **Visual language: dark frosted glass.** Deep near-black window, hairline
  borders, a slow soft light behind the chrome. Frosted-glass surfaces are
  allowed on chrome and containers (sidebar, inspector panel, folder/collection
  cards and their label panels, popovers), always built from shared glass styles
  and tokens in `DesignSystem.swift`, never ad hoc in a view. **Never put glass
  or blur over the image grid itself**: thumbnails stay sharp, unfiltered and
  uncovered. Clear medium-weight titles (no light weights for UI text), quiet grey
  secondary text, one accent at a time. Library statistics may use the dot-matrix numeral style.
- **Typeface and type scale:** words are Space Grotesk (sans), numbers and data are Space
  Mono. Set text only with `.dsText(.role, .text / .number)` (roles in `DS.TextStyle`:
  display, title, headline, reading, body, label, meta, caption); never `.font(...)`, a
  literal size, or `.monospacedDigit()`. It falls back to the system font when the
  Preferences switch is off. Before adding or changing a size, read
  `docs/DESIGN-SYSTEM.md` (the scale, why, and where to look) and update it with the reason.
- **Motion** is short and purposeful (view changes: blur + slide + fade, about
  0.25–0.4 s). Respect Reduce Motion and Reduce Transparency: glass falls back
  to a solid fill. Never animate during fast scroll.
- Design references: `docs/design/mockup-v2.html` (approved layout). The dark
  frosted-glass reference (a third-party motion concept, "Kiln Studio") is a
  mood reference for the visual language only: we do not copy its product,
  layout or assets, and its files stay out of the repo.

## Commands

```bash
swift build
swift test
swift run -c release bbbench <folder> [--io N] [--no-thumbs] [--limit N]
swift run -c release bbscopebench [--count N] [--extra] [--reuse <dir>]
scripts/build-app.sh && open build/Blazebunny.app
# Timings of the running app (generated demo folders only, never a real library):
BB_PERF_LOG=/tmp/bb.log build/Blazebunny.app/Contents/MacOS/Blazebunny --open <folder> --ghost [--bench]
```

`BB_PERF_LOG` writes launch and reload timings; `--bench` then drives the app through the side
panels, the size slider, folder, filter, search, scrolling and arrowing, logs the main thread's CPU
time and stalls for each, and quits. `BB_SNAPSHOT_DIR=<dir>` saves pictures of the window at the key
moments (`Perf.swift`, `PerfBench.swift`). Signpost intervals (`grid.apply`, `grid.reflow`) show in
Instruments under Points of Interest.
