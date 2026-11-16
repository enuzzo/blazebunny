# Blazebunny M2 (sources, filters, saved searches) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Turn the M1 browser into the approved v2 design: source detection, pill filters with live counts, saved searches, adaptive inspector, month sections.

**Architecture:** Filtering lives in `BlazebunnyCore` as a Codable `FilterState` that compiles to SQL; the app only renders it. Facet counts are `GROUP BY` queries that apply every filter except the facet's own.

**Tech Stack:** as M1. **Spec:** `docs/superpowers/specs/2026-11-16-blazebunny-design.md` §10.

## Global Constraints
As M1 (read-only sources, no dependencies, no real data in fixtures, English code).

## Review Focus
1. Schema upgrade from v1 keeps thumbnails and re-reads metadata (no full rebuild).
2. A filter combination with zero results shows an empty state, never a crash.
3. Facet counts exclude the facet's own selection (so you can add a second value).
4. Saved searches survive relaunch and decode old/missing fields safely.
5. PNG without any text still gets a source (`unknown`) and an orientation.

### Task 1: Source detection and extra metadata
**Files:** `Sources/BlazebunnyCore/MetadataReader.swift`, `ItemSource.swift`, `GeneratorParameters.swift`, tests.
- `enum ItemSource: String, Codable, CaseIterable { camera, midjourney, stableDiffusion, screenshot, unknown }`
- `ItemMetadata` gains `source`, `cameraMake/Model`, `lens`, `exposure` (`fNumber`, `exposureTime`, `iso`), `generator` (`model`, `steps`, `cfg`, `seed`, `sampler`).
- `A1111Parameters(raw:)` parses `prompt\nNegative prompt: …\nSteps: 20, Sampler: …, CFG scale: 7, Seed: …, Model: …`.
- Tests: MJ, A1111 PNG, ComfyUI PNG (`prompt` JSON → stableDiffusion), JPEG with EXIF Make/Model → camera, PNG with XMP UserComment "Screenshot" → screenshot, plain PNG → unknown.

### Task 2: Schema v2, FilterState, facets
**Files:** `LibraryIndex.swift`, `FilterState.swift`, tests.
- Migration v1→v2: `ALTER TABLE` add `source, orientation, mj_version, camera, lens, exposure, generator`; table `item_params(item_id, name, value)`; reset `meta_state` to 0 (thumbnails kept).
- `struct FilterState: Codable, Hashable { types, orientations, ratios: Set<String>; dateFrom/dateTo: Date?; sources: Set<ItemSource>; versions, params (all-of), cameras: Set<String> }`.
- `LibraryIndex.items(filter:search:sort:)`, `facetCounts(_ facet: Facet, filter:search:) -> [(value, count)]`, `monthHistogram(filter:search:) -> [(month: String, count: Int)]`.
- Tests: OR within facet, AND across; params all-of; counts ignore own facet; date range; migration from a v1 file keeps thumbnail rows.

### Task 3: Saved searches
- Table `saved_searches(id, name, color, folder, position, state_json)`; `SavedSearch: Codable` (filter, search, sort); CRUD on `LibraryIndex`.
- Tests: round trip, reorder, unknown JSON fields tolerated.

### Task 4: App filter row
- `FilterRow` with `FilterPill` + popovers (checkbox rows with counts, shape popover with glyphs + ratios, date popover with bar histogram and presets, source list); contextual groups; Clear; Save Search sheet (name, colour, folder).

### Task 5: Sidebar, grid sections, adaptive inspector
- Sidebar: libraries, built-in views, saved searches grouped by folder with colour dots; context menu Rename/Delete.
- Grid: month sections with pinned headers (date sorts), Fill/Fit, source glyph.
- Inspector: per-source sections, clickable values → filter.

### Task 6: Verify
- `swift test`; build app; try on the generated demo folder with mixed sources; check the archive library reopens and upgrades.
