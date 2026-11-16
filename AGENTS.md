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
- `Tests/BlazebunnyCoreTests` — Swift Testing; fixtures are generated in code.
- `scripts/build-app.sh` — assembles and ad-hoc signs `build/Blazebunny.app`.

## Rules

- **Never write inside a scanned folder.** Open source files read-only; never
  rename, touch dates, or create files next to them. A test guards this.
- **No third-party dependencies.** Apple frameworks and the system SQLite only.
- **No real user data in the repo.** Never commit real images, prompts, author
  names or file names from anyone's archive. Tests build their own PNGs.
- **No network access** in the app.
- Code, comments, docs and commit messages in English.
- Run `swift test` before committing; run `gitleaks dir .` before the first
  commit and `gitleaks git .` before pushing.
- Swift 6 language mode; macOS 15 minimum.
- **UI goes through the design system** in `Sources/Blazebunny/DesignSystem.swift`:
  spacing from `DS.Space`, sizes from `DS.Size`, radii from `DS.Radius`, tints
  from `DS.Tint`. Toolbar: system controls only (view-level actions such as
  Save Search live there). Filter row: `PillStyle` only, 28 pt. Inspector: one
  prominent button (Copy Prompt), the rest bordered, regular size. No custom
  glass on content. No one-off sizes or colours in views.
- Design references: `docs/design/mockup-v2.html` (approved layout).

## Commands

```bash
swift build
swift test
swift run -c release bbbench <folder> [--io N] [--no-thumbs] [--limit N]
scripts/build-app.sh && open build/Blazebunny.app
```
