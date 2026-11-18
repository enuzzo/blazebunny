# Blazebunny milestones

Everything the owner has asked for, nothing dropped. Status: `[x]` done in code (not all
committed), `[ ]` to do. Design context and the proposed order live in
`docs/superpowers/specs/2026-11-17-roadmap-design.md`; M1/M2 plans are in
`docs/superpowers/plans/`.

## Done in the dark-glass round (uncommitted until the owner says commit)

- [x] Dark theme, near-black window, soft light behind the chrome, hairline borders.
- [x] Large light page title; toolbar title hidden.
- [x] Header compacted to one row: title + image count + filter pills (was three lines).
- [x] Sidebar and month headers restyled dark.
- [x] Footer text bigger (10 pt to 12 pt), bar 32 pt; shows thumbnail count while
      metadata is still being read.
- [x] Rename libraries in the sidebar (double-click or context menu, Esc cancels).
      Display name only; the folder on disk is never renamed.
- [x] Selecting a library (no image selected) shows a summary in the right sidebar:
      count, types, sources, size, date range, with-prompt count, date added, folder.
      It follows the active filters or saved search.
- [x] Thumbnails are made while metadata is still being read (alternating time slices,
      visible items first). Tested; not yet watched live on the 23k folder.
- [x] Core: `LibrarySummary`, `LibraryIndex.summary`, `createdAt` (with tests).

## Open items from this round

- [ ] Show progress while listing files ("Listing files… 0" stays frozen on big folders).
- [x] Verified live that thumbnails appear while metadata is being read (8k thumbnails visible
      while with-prompt count was still climbing on the 23k folder).
- [ ] Balance the layout further: decide whether the sidebar is part of the main block
      (current call: sidebar and inspector are full-height columns; footer under the grid).
- [ ] Inspector empty state and filter row can still be tightened after the new typeface.

## M3: preferences and typeface

- [x] Preferences window (Settings scene, also holds viewer settings later).
- [x] Typeface chosen by the owner: Space Grotesk for text, Space Mono for numbers and data.
      Bundled in `Resources/Fonts`, registered at launch, applied through `.dsFont(...)`.
- [x] Preferences toggle to turn the typeface off (system font fallback). Checked live.
- [x] AGENTS.md amended (free bundled resources allowed, licences in `NOTICE`); `NOTICE` added.
- [ ] Apply the typeface to the AppKit grid month headers and sidebar badges/section titles
      (they still use the system font).
- [ ] Dot-matrix numerals for library statistics (reference style), where it fits.

## M4: ghost (temporary) folders

- [x] When adding a folder, choose "Open as ghost" (checkbox in the Open panel; ghost button
      at the bottom of the sidebar; File > Open Ghost Folder… ⇧⌘O).
- [x] A ghost leaves no thumbnails, index or other data behind: stored only in a private
      temporary directory (mode 0700), deleted on Close Ghost, on quit, and orphans of a
      crash are removed at the next launch. `GhostStorage` in Core, tested (4 tests).
- [x] Not remembered across launches (not in saved libraries, not as the library to reopen).
- [x] Very visible: amber line-ghost icon, dashed outline around the whole content area,
      dashed row in a "Ghosts · leave no trace" sidebar section, badge and
      "Deleted when closed" in the summary.
- [x] Verified live: data only under the temp dir while open; none after Close Ghost, after
      quit, or after a kill -9 plus relaunch; real library folder unchanged.
- [x] The Open panel's remembered folder (`NSNavLast*` in the app's own defaults) is removed
      after a ghost is chosen. (Found in review round 1; it was wrongly called system state.)
- [x] Ghost bases are named with the owning process id, so a second running copy never
      purges them as orphans.

## M5: folder trees

Design: `docs/superpowers/specs/2026-11-17-libraries-and-folders-design.md`; plan for stage 1:
`docs/superpowers/plans/2026-11-17-m5-stage1-folder-tree.md`. Stages 2 to 8 are not started.

Stage 1 (folder tree inside today's one-folder libraries), built 2026-11-17, uncommitted:
- [x] Core: schema v3 (`dirs`, `items.dir_id`, index `items_dir_sort(dir_id, date)`), migration from v2 fills them from
      `rel_path` without reading disk; thumbnails and metadata kept. `directoryTree()`, `dirID(forPath:)`,
      `items/summary/facetCounts/monthHistogram(... folder:)`, `items(... limit:)`, `optimize()`.
      Scanner records every directory (empty ones too) and prunes them only on a trustworthy listing.
      `SearchQuery.folder` (a path) so saved searches remember their folder. 79 tests pass (62 before).
- [x] App: Folders section (disclosure tree, counts, expand state per library), folder scope feeds grid,
      summary, filter pills, facet counts, saved searches and Save Search; context line above the title;
      clicking the library shows everything; two-phase load (first 400 rows, then the rest).
- [x] Alive sidebar per DESIGN-SYSTEM.md (glow, tinted icons, tinted selection with marker, hover).
- Scope is an integer match on `dir_id` (leaf: `=`, otherwise a recursive CTE over the small `dirs` table).
  Finding: with no planner statistics SQLite filtered a source or full-text match first and the folder
  afterwards (a source filter in an 8k subtree: 59 ms, search 95 ms); `INDEXED BY items_dir_sort` when a scope is
  set fixes it (6 ms and 38 ms). `PRAGMA optimize` did not help.

Measured with `swift run -c release bbscopebench` (generated 100 000 items, 1 109 folders, an 8 000-file
branch; internal SSD, warm; best of 5; no real data):

| What | Budget | Measured |
|---|---|---|
| Tree build, 1 109 folders | about 34 ms | 2.2 ms |
| Select an 8k-item folder: first 400 rows | 50 ms | 0.2 ms |
| Select an 8k-item folder: complete (items, counts, facets, summary) | 150 ms | 22 ms |
| Select a 92-item leaf folder: first rows / complete | 50 / 150 ms | 0.03 / 15 ms |
| Whole library (100k): first 400 rows / complete | 50 / 150 ms | 0.1 / 86 ms |
| Filter change (source) inside the 8k folder | 100 ms | 6 ms |
| Filter change (source), whole library | 100 ms | 71 ms |
| Text search in the 8k folder (selective / word in 66% of items) | 100 ms | 7.6 / 38 ms |
| Text search, whole library (selective / word in 66% of items) | 100 ms | 8.4 / **130 ms** |
| Month histogram in the folder / whole library | n/a | 2.6 / 37 ms |
| Memory (RSS) after generating and querying 100k | bounded | 74 to 82 MB |

Not met at the time: a whole-library full-text search for a word that 66% of the images contain took 130 ms (budget
100 ms). Fixed in the speed pass below (first rows in 14 ms, the full list in 47 ms on rows shaped like a real
library's, where the old path took 331 ms).
Other notes: a reload because of a filter no longer recounts the whole library (`counts()` is 15 ms at
100k); the folder tree is rebuilt off the main thread; writing 100k metadata rows takes 27 s (FTS triggers,
not new, not measured on the UI path). Not measured: scrolling and thumbnail delivery, launch time, main-thread
cost of rebuilding the `FolderTree` for tens of thousands of folders.

## M6: full-screen viewer

- [ ] Open with double-click and with the Space bar, as expected on macOS.
- [ ] Navigate left/right and up/down to move through images.
- [ ] Ultra-fast scrolling through images (smooth on key repeat; prefetch neighbours).
- [ ] Mini thumbnail strip along the bottom.
- [ ] Background chosen in Preferences: white, cream, black, "frame", custom colour.
      Default: solid black.
- [ ] Controls only as an overlay on hover; otherwise no controls at all.
- [ ] Top bar controls include Fit to Screen, 100%, and similar zoom steps, to judge images.

## M7: full-metadata inspector

- [ ] Show 100% of the metadata that can be shown for each image: every single small
      piece of information (EXIF, TIFF, GPS, IPTC, XMP, maker notes, PNG chunks, file info).
- [ ] Laid out beautifully, grouped, with purpose-made line icons (not filled) from a free
      library, and clean, clearly distinguishable colours (no rainbow).
- [ ] Everything shown in the sidebar (EXIF and all other data) can be copied: all of it
      or part of it (a row, a group, everything).

## M8: comparer and saved selections

- [ ] Image comparer for any number of selected images.
- [ ] A collection tray that can open in a sidebar and be filled by dragging, so you can
      scroll huge libraries, prepare a comparison, then open it.
- [ ] Optionally save the selection to the sidebar. Saved searches stay a core strength:
      quick, album-like. Proposal: saved searches (live filters) and saved selections
      (fixed lists) coexist with different icons.

## M9: more generators detected and laid out

- [ ] Find which flags GPT/ChatGPT, Gemini and others embed so they can be detected and
      laid out (research done: see roadmap item 7). OpenAI: C2PA in PNG `caBX`
      (strings `OpenAI`, `ChatGPT`, `GPT-4o`). Google: C2PA from `Google LLC`, IPTC credit
      "Made with Google AI". Firefly and Flux: C2PA, strings unpublished.
- [ ] Implement: walk PNG chunks and JPEG APP11 segments, byte-search issuer strings;
      Midjourney and Stable Diffusion rules stay first; labels say "looks like";
      SynthID is not detectable.
- [ ] Add sources (OpenAI, Google, and others as confirmed) to the Source filter, the
      grid glyphs and the inspector.

## Review round 1 (Opus, code + performance, 2026-11-17)

Fixed, with tests (62 pass):
- [x] CRITICAL: a rescan of an empty, missing or half-readable root wiped the index; pruning now
      needs a complete listing, a reachable root, and a non-empty result for a non-empty library.
- [x] A batch read while the disk vanished was recorded as permanently failed; it is now not
      saved and stays pending.
- [x] Thumbnail loader: stale in-flight entries after a library switch left cells blank forever.
- [x] Stale progress and errors from a cancelled scan no longer reach the new library.
- [x] SQLite busy timeout (5 s); id list for priority thumbnails bound as one JSON parameter
      (the statement cache grew without bound).
- [x] One `ThumbnailStore` per directory (two stores overwrote each other's thumbnails).
- [x] Metadata/thumbnail interleave: thumbnails get about as long as the metadata batch, not 85%
      of the time (metadata was ready 3.4x later than necessary).
- [x] Inspector no longer sticks on "Reading metadata…" for an image selected early.
- [x] Reload while scanning every 3 s instead of 2; forgetting a library releases everything.
- [x] Folder open as ghost and library at once now explains itself instead of silently choosing.
- [x] PNG text chunks capped at 16 MB; files over 128 MB are not read whole for thumbnails.

Deferred (ranked by gain), to do later:
- [x] Thumbnail pack/offset/length in `BrowseItem`, packs read with `pread` and no shared lock (speed pass).
- [x] While scanning, no full grid `reloadData` when only thumbnails changed (they reach the cells directly);
      the summary is read only while it is visible (speed pass).
- [x] Index on `file_name COLLATE NOCASE` (first rows of a name-sorted view: 0.2 ms); `kind` needs no index of
      its own (it is in the browse index); month histogram cached (speed pass). Still open: page `items()` for
      libraries beyond 100k.
- [x] `ioConcurrency` by volume type: 6 on a solid-state disk, 2 on anything else (speed pass; 1.7x on the SSD).
- [ ] "Recently Added" uses the embedded date, not when the file entered the library.
- [ ] Refresh stale bookmarks; symlinked files and folders are skipped; zero-byte files are
      marked failed; delete the index of a forgotten library.
- [x] Tests added in the speed pass: scanner cancel mid-batch, priority ordering, ThumbnailLoader across a
      switch, summary with search plus facets, ghost lifecycle at the model level.
- [x] AGENTS.md sweep (round 2), finished in the speed pass: no `.font(...)` in views (symbols use `.dsIcon`),
      the grid's AppKit sizes and colours come from `DS`, spacings and radii are tokens.

## Review round 2 (Opus, UI/UX, 2026-11-17)

Fixed:
- [x] Saved searches: "Save as New Search" is now the primary action; overwriting is a menu choice, and
      the context-menu update only appears on the active search. Deleting a saved search and
      forgetting a library ask for confirmation.
- [x] Slow-click rename only arms when the library is shown plain (no filters or search).
- [x] Filter pills toggle their popover; Midjourney/Camera groups show whenever the view contains them.
- [x] Empty states: "Looking for images…", "No Images", and "No images match “text”".
- [x] Edit > Find (⌘F) focuses the search field; Rescan is disabled when the folder is offline.
- [x] Copy buttons say "Copied" briefly and read "Copy Text" / "Copy Parameters"; Esc clears the
      selection (back to the summary).
- [x] One ghost wording everywhere (`GhostText`): "Ghost · temporary", "Close Ghost", and "Your files are
      never changed".
- [x] Accessibility: grid cells have a name and the source in their label; popover rows expose their
      selected state; slider labelled; ghost button named "Open Ghost Folder"; the ghost icon is
      decorative where text already says ghost; the sidebar honours Reduce Transparency.
- [x] Contrast: tertiary text raised to secondary; Midjourney tint lightened for text.
- [x] Coherence: month header uses the brand typeface; `.monospacedDigit()`/`.fontWeight` removed from
      the app code; `DS.Tint.ok` and `DS.Tint.warning` (distinct from the ghost amber).
- [x] Microcopy: "Clear All" everywhere, "Fit/Fill Thumbnails", "Color", "Sort order".

Deferred (needs a decision or is larger):
- [ ] Sidebar structure: nest Views, folders (M5) and saved searches/selections (M8) under their library
      (disclosure group or a library switcher). Best decided at the start of M5.
- [ ] Filter row at narrow widths: wrap the pills under the title or add an overflow menu/edge fade.
- [ ] Multi-selection inspector state ("12 images") with counted actions; run copy off the main thread.
- [ ] Toolbar layout (inspector toggle at the trailing edge) and menu homes: View > Sidebar/Inspector,
      Library > Save Search; decide Space and double-click for the viewer (M6) and Open in default app.
- [ ] Increase Contrast handling; keyboard access for the date histogram and colour swatches (use a
      palette Picker); popover materials via `glassPanel`.
- [x] Literal sweep (speed pass): spacings and radii outside `DS` are gone (`Radius.large` 12 and `hair` 2
      added; 6 and 10 already existed as `iconGap`, `pillInset`, `iconText`), the filter pills and `PillStyle`
      share one capsule (`PillChrome`), icon sizes sit on a small scale set with `.dsIcon`, the grid's AppKit
      literals are tokens. Left on purpose: the window and column widths, the dash patterns of the ghost
      outlines, the orientation glyphs in the Shape popover, the prompt's line spacing.
- [ ] Specific alert titles; "HD · hd" flag parameters shown as "On"; drag a folder onto the window.

## Review round 3 (Opus, hierarchy, type and colour, 2026-11-17)

Applied (spec in `docs/DESIGN-SYSTEM.md`):
- [x] Real semibold (wght 600) through a font variation; `captionStrong` removed; caption is semibold
      uppercase with +0.6 tracking; title tracking -0.3.
- [x] Mono sizes 0.5 pt smaller than sans on label and meta (even line width); `RichText` mixes
      sans words and mono numbers in one line (header count, footer).
- [x] Hero number on one baseline with its unit; thousands separator pulled in.
- [x] Summary bars neutral (not the accent) with a track and a 2 pt minimum; counts primary; one
      row rule instead of a doubled line.
- [x] Popovers use the dark glass fill (they were the system grey, 3.2:1 text); pill outline 0.20;
      active filter text lightened; filter-group label secondary with a tinted icon.
- [x] Source tints matched in lightness (indigo, green, teal) and `Tint.ok` removed; connected-drive
      icon neutral, offline coral; one 0.15 opacity for tinted fills; 22 pt badges.
- [x] Footer: sans words, mono numbers, no duplicate thumbnail count while scanning.
- [x] Inspector numbers all through the mono; Job ID at label size; "⌘C" hint removed from the button;
      Preferences uses the body role; month headers take their font from the type scale.

Left as is on purpose: base sizes 13/12/11/10, display 40 and title 20, system primary/secondary
text, the 2 pt selection ring, 9% hairline, 16 pt left edge shared by title, month header and grid,
ghost signals, 28 pt rows, 92 pt label column, no glass on the inspector.

## M10: grid layouts and spacing (owner, 2026-11-17)

- [ ] Choose how a folder is shown, at a glance, from the toolbar (one control, remembered per
      project): **Square** (1:1, cropped: today's Fill), **Square, whole image** (today's Fit),
      **Justified rows** (true proportions, every row flush), **Masonry** (columns, true proportions),
      and possibly a **packed / mosaic** layout ("isotope": mixed sizes packed tightly). Confirm the
      last one's meaning with the owner before building.
- [ ] Preferences: horizontal and vertical spacing between images, separately, as numbers with a
      live preview.
- [ ] Notes: the index already stores width and height per item, so rows and columns can be laid out
      without opening files. Layout must stay O(n) and smooth on 100k items; month sections and
      the "fill the row exactly" behaviour must carry over; thumbnail size slider keeps working
      (as target row height or column width).
- [ ] Keep Space-to-view, keyboard navigation and selection ring identical in every layout.

## Icons (owner, 2026-11-17, nice to have)

- [ ] A rounder, more "designed" and less formal line-icon set than SF Symbols, if a good free one
      fits. Candidates to evaluate: Phosphor (MIT, rounded line weights), Lucide (ISC), Tabler (MIT).
      Needs: all icons in one family and weight, consistent with the type (round terminals), usable
      from SwiftUI as template images, and listed in `NOTICE` with its licence. Decide with a
      side-by-side mock like the typeface and sidebar ones.

## Owner notes, 2026-11-17 (later)

- [x] Summary bars: one fixed count column per table so every bar starts and ends at the same x
      (a longer number used to push its bar left). Rule added to DESIGN-SYSTEM.md.
- [x] Hero number: the squeezed thousands separator is centred in its gap.
- [x] Inspector deviations accepted by the owner (2026-11-17) and applied: no rule on value rows (hover highlight), `DS.Tint.location` rose #E2ABC6 reserved for the Location group (M7), "Copy Exposure" as the one filled button for photos.
- [ ] The inspector (right sidebar) must be beautiful, not only technical: a clear focal point,
      calm rhythm, a little delight. Fable was asked to design it (summary, one image, several images,
      folder); apply its design when it arrives.
- [ ] Icons: demo of five free families made (Phosphor regular and duotone, Lucide, Tabler, Iconoir);
      owner to choose, then bundle with licences in NOTICE.

## Owner notes, 2026-11-17 (evening)

- [x] Libraries can be reordered by dragging in the sidebar (order remembered). Quick version for the
      current flat list.
- [ ] Group libraries (one level) with drag and drop, collapse and rename; lives in the library switcher
      of stage 2 (design updated).
- [x] The scan status no longer sits on "Listing files… 0": the listing reports its count every 1000
      entries; a scan that stops with an error now says "Scan stopped · Rescan with ⌘R" in the footer
      instead of leaving a stale status. Measured listing of the 23k real folder: 1.1 s (release).
      Likely cause of the stuck status seen by the owner: two copies of the app scanning the same
      library. Not reproduced in the speed pass (it ran one copy per library); the listing now also
      starts only after the first grid is shown.
- [x] ~~Double click opens the original~~ reverted by the owner: a double click must NOT open Preview. It will open the full-screen viewer (M6); until then it does nothing. Opening in another app is a context-menu choice.
- [x] Inspector preview: sharp previews cached (48) and the wait before decoding cut from 250 to 90 ms.
      Preview source: the cached 512 px thumbnail at once, then the real file downsampled to 1200 px
      (slow on an external disk; the speed review should look at prefetching neighbours).

## Right-click menu and shared actions (owner, 2026-11-17)

- [x] Grid context menu organized in two groups with icons: **Copy** (Prompt, Text Only, Parameters,
      Path) then **Open and locate** (Show in Finder, Open in Default App). One list of actions with
      one name and one icon each (`Actions.swift`, `AppAction`) is shared by the grid menu and the
      sidebar menus, so the same action looks the same everywhere; the icons move to Iconoir later with
      no change at the call sites.
- [ ] Add to the menu when the features exist: **Add to Tray**, **Add to Compare**, **Add to
      Collection**, and "Open With" (a list of apps). Use the same `AppAction` list and icons in the
      inspector buttons, the menu bar and the toolbar.
- [ ] Return key: currently "open in default app"; revisit with the viewer (Space and double click
      open the viewer, a menu key for Open in Default App).

## Speed and quality pass, before the viewer (owner, 2026-11-17)

Order decided: speed and quality pass first (the viewer's ultra-fast navigation needs the same
prefetch and caching), then the full-screen viewer (M6), then the remaining stages.

Done 2026-11-17 (uncommitted until the owner says commit). 113 tests pass (79 before): 95 in Core, 18 in the
new `BlazebunnyTests` target for the app's own logic.

- [x] Animated backdrops removed (owner: speed beats flourish): the window light and the sidebar glow are
      now still gradients. Idle CPU went from **9 to 16% to 0.0%** (measured with `ps`).
- [x] **Stutter when opening and closing the side panels.** Measured first: the layout pass itself was cheap
      (0.1 ms); what jumped was every thumbnail being resized and re-wrapped on every frame, while AppKit and
      SwiftUI animate the panel. Now the rows keep the width they had while a panel slides (`JustifiedFlowLayout.
      layoutWidth`), and when the width has rested for 60 ms the grid reflows **once** and the thumbnails on
      screen **glide** to their new places in 0.24 s, ease-out (first-last-invert-play with layer transforms;
      thumbnails that were off screen fade in, nothing else moves, none of it with Reduce Motion). The image at
      the top left stays where it is, so the same pictures are in view before and after, also deep in a
      library. Dragging the window edge still reflows live. The thumbnail size slider and ⌘+/⌘− use the same
      glide (at most one reflow every 0.1 s while dragging: 16 layout passes for a drag that took 80); Fill/Fit
      cross-fades. What is left of the cost of a panel toggle (about 100 to 160 ms of main-thread CPU spread
      over its animation) is AppKit's split view and SwiftUI laying out the panels: the grid's share in a
      profile is about 2%.
- [x] **Dragging libraries to reorder.** Cause: each library row carried a double-tap gesture and a
      simultaneous tap gesture; a SwiftUI gesture on a list row makes the list wait for the gesture to fail
      before it can select or drag the row. The rows now carry no gesture: `RowClicks`, a view behind the row
      that is never hit, watches mouse-down events as they pass (two clicks: rename; one click on the selected
      row, not held and not moved: slow-click rename). The list's own `.onMove` does the drag with its own
      insertion line. The same watcher works for folders and saved searches, and nothing stands in the way of
      `.draggable` / `.dropDestination` when libraries get groups. **Not verified by hand**: the screen was
      locked during this work, so no real drag could be made; the owner has to try it.
- [x] **Inspector preview.** The grid's thumbnail shows at once (no grey flash: it is set in the same pass
      as the selection). The original is decoded off the main thread at the size the panel can show (768 px
      for the default panel on a Retina screen, not 1 200), only when the thumbnail is not already enough (on
      a non-Retina screen it is: the original is never read). While an arrow key is held nothing is decoded.
      When the selection rests, the next two images in the direction of travel and the one behind are decoded
      one after the other at low priority, kept in a 192 MB cache, and cancelled when the selection moves
      on; the sharper image cross-fades in. `PreviewModel` and `PreviewDecoder` are written for the viewer.
      Larger stored thumbnails are **not** justified: a real 23k library's 512 px thumbnails average 57 KB
      (1.3 GB); 1 024 px would be about three to four times that (4 to 5 GB per 23k, about 20 GB per 100k).
- [x] **Thumbnails without the index lock**: each grid item carries its thumbnail's location, packs are read
      with `pread` on any number of threads, requests of cells that scrolled away are cancelled, and the
      memory cache is bounded by bytes (192 to 512 MB by the Mac's memory; it held 3 000 images whatever
      their size).
- [x] **Reads never wait for the scanner**: the index has a writer connection and two read-only ones (lists,
      lookups) on the same WAL database.
- [x] **No full grid reload for thumbnails**: the scan hands each batch of thumbnails to the grid, which
      fills the cells on screen; the grid's items are read again only when files were listed or metadata was
      read. The summary is read only while the inspector shows it; the source counts of the filter row come
      from the items in memory.
- [x] **SQL**: schema 4 adds `items_browse`, one index in date order that holds everything the grid, the
      counts, the facets and the summary read, so those queries never touch the wide rows (prompt, XMP). About
      15 MB per 100k items, built in a fraction of a second at the first launch after the update; the plain
      date index is dropped. `items_name` for name-sorted views. Query plans checked with EXPLAIN QUERY PLAN
      on a generated 100k index: SQLite, having no statistics, started from the big match and sorted, so the
      index is chosen in code (the browse index for a whole library by date, the folder index inside a
      folder, SQLite's own choice for a search with at most 5 000 matches and for a view by name). Month
      histogram: the dates only, grouped in Swift, kept until the index changes. FTS5 needed no change (the
      match itself takes 1 to 6 ms; a one-letter prefix 27 ms): no `prefix` index, no rebuild. `PRAGMA
      optimize` is not used (no gain once the index is chosen in code).
- [x] **Launch**: the first rows are read off the main thread while the window is being built, the scan
      starts after the first grid is shown, counts are three small index scans. Launch no longer grows
      with the library (about 400 ms at 23k and at 100k). The 300 ms budget is **not met**: what remains is
      AppKit and SwiftUI creating the window (the app's own code is about 3% of the main thread's work in a
      launch profile).
- [x] **Scan**: 6 files at once on a solid-state disk, 2 on anything else or unknown (`VolumeKind`, from the
      disk's own description in IOKit). A USB enclosure that does not say what it holds counts as unknown.
- [x] **SwiftUI**: `ContentView` reads only what changes rarely; the toolbar controls, the header row, the
      grid, the placeholder, the library count in the sidebar and the preview image each read their own
      state, so a scan's progress, the thumbnail size or a step through the images redraws one small view.
      Fonts are made once (every text asked Core Text for its font at every draw). The scan reports about
      ten times a second instead of after every batch. While an arrow key is held the image follows every
      step and the text of the inspector follows ten times a second.
- [x] **Code quality**: `LibraryIndex` and `LibraryModel` split by concern, `GridView` into view, layout
      and cells; the grid's month sections and positions are a `GridSnapshot` made off the main thread;
      dead code removed (`ThumbnailLoader.missing`, the per-view month loop, `PreviewImage`'s own loader);
      literals moved to `DS` (see review round 2); no Swift 6 warnings.

### Before and after

Same Mac (M4 Max, internal SSD), release builds, generated data only. "Before" is the last commit with the
same timing code added. The app figures were taken with the screen locked (the window is drawn but not
shown): CPU time of the main thread is what the app itself spent; wall-clock times include the main
thread waiting for the window server and are best read as "not worse than".

Index queries, `swift run -c release bbscopebench --extra` (100 000 items in 1 109 folders, rows shaped like a
real library's: 2.6 KB each; warm; best of 5):

| What | Budget | Before | After |
|---|---|---|---|
| Whole library: the grid's items | 150 ms | 68 ms (206 with the counts, facet and summary the reload also read) | 22 ms |
| Filter by source, whole library | 100 ms | 177 ms | 18 ms |
| Search, word in most items: first rows / all | 100 ms | no first rows / 331 ms | 14 ms / 47 ms |
| Search, selective word | 100 ms | 32 ms | 13 ms |
| Search, one letter | 100 ms | not measured | 77 ms |
| Folder of 8 000 items: the grid's items | 150 ms | 5.5 ms | 6.9 ms |
| View by name: first rows / all | 50 / 150 ms | 138 ms / 138 ms (in the `sqlite3` shell) | 0.2 ms / 147 ms |
| Month histogram, whole library | n/a | 67 ms every time | 8 ms once, then kept |
| Summary, whole library (now only while shown) | n/a | part of every reload | 37 ms |
| One image's detail while a scan writes (median / worst) | n/a | 24 ms / 72 ms | 0.006 ms / 0.04 ms |
| 8 000 thumbnail reads on 8 threads, idle / while a scan writes | no lock | 101 ms / 35 s | 10 ms / 9 ms |
| At 23 000 items, what one reload read: whole library / filter / search | 30 ms | 42 / 34 / 67 ms | 4.7 / 3.3 / 10 ms |
| Writing: 100 000 new rows / their metadata | n/a | 1.6 s / 39.8 s | 4.8 s / 41.8 s |

The app, `--bench` on generated folders of 23 012 and 100 000 images (`before / after`, 23k then 100k):

| What | Budget | 23k | 100k |
|---|---|---|---|
| Warm launch to a grid with its thumbnails | 300 ms | 529 to 557 / **394 to 420 ms** | 765 to 788 / **398 to 421 ms** |
| Switch to the whole library: first rows | 50 ms | 36 to 40 / 24 to 36 ms | 39 / 26 to 33 ms |
| Switch to the whole library: complete | 150 ms | 68 / 34 to 55 ms | 154 / 65 to 73 ms |
| Filter by source: complete | 30 / 100 ms | 48 to 71 / 15 to 32 ms | 131 to 171 / 45 to 56 ms |
| Search, common word: first rows | 30 / 100 ms | 187 (the full list) / 23 to 31 ms | 278 to 306 / 20 to 26 ms |
| Main thread per reload (applying the items to the grid) | small | 6 / 0.2 ms | 12 to 28 / 0.2 ms |
| Arrow key held, 60 images: main-thread CPU | fluid | 1 932 / 517 to 656 ms | 1 943 / 472 to 545 ms |
| Size slider dragged: main-thread CPU, layout passes | fluid | 826 / 444 to 495 ms, 80 / 16 | 843 / 451 to 546 ms, 80 / 16 |
| Fill / Fit: main-thread CPU | fluid | 46 / 20 ms | 51 / 22 ms |
| Filter change: main-thread CPU | fluid | 76 / 32 to 42 ms | 77 / 35 to 45 ms |
| Inspector open or close: main-thread CPU | fluid | 176 / 151 to 159 ms | 169 / 159 to 166 ms |
| Sidebar open or close: main-thread CPU | fluid | 143 / 101 to 119 ms | 128 / 127 to 139 ms |
| Fast scroll (30 000 pt/s): thumbnail wait, median / 95% | no lock | 3.9 / 6.2 ms / 3.7 / 5.9 ms | 4.2 / 6.1 / 3.4 / 5.5 ms |
| Memory after the whole bench | bounded | 422 / 169 to 241 MB | 217 / 238 to 317 MB |
| Idle CPU | about 0% | 0.0 / 0.0% | 0.0 / 0.0% |

Also measured: preview of 8 MB PNGs stepped every 0.6 s on the internal SSD: sharp 107 to 132 ms after every
step before; after, 105 to 120 ms for the first and at once for each next one (already decoded). Scan of the
23k folder (`bbbench`): 31.9 s at 2 files at once, 18.6 s at 6. First scan in the app: the grid was fully
reloaded 20 times at 23k (47 at 100k) taking up to 14 ms (27 ms) of the main thread each; now 18 (44) times
taking up to 1.5 ms (0.2 ms).

Inferred, not measured: the preview on an external disk (no such disk with generated data: the gain there
should be larger, since each original is read once, in advance, and never when the thumbnail is enough);
scrolling at 120 Hz and the feel of the glide (no screen was on); the thumbnail path during a scan inside
the app (measured in `bbscopebench` only). Scrolling itself did not change (the cells were already cheap);
flinging back over a thousand thumbnails now decodes them again where the old cache had kept all of them,
which is the price of the bound on memory.

### Remaining

- [ ] The owner tries by hand: dragging libraries, slow-click and double-click rename, the glide when the
      side panels open and close and when the slider moves, arrowing with the inspector open.
- [ ] Launch under 300 ms: only a lighter window could do it (a plain AppKit window, or showing the grid
      before the side panels exist). Decide whether it is worth it.
- [ ] A view sorted by name at 100k takes 147 ms to complete (its first rows are immediate).
- [ ] The first listing of a new library writes rows three times slower (4.8 s per 100 000 files) because of
      the two new indexes; it happens once per file and is small next to reading the disk.
- [ ] During the first scan the grid still reloads every 3 s while metadata is read (dates and order change);
      a diff that moves cells instead would keep the scroll position steadier.
- [ ] Page `items()` beyond about 300k items; `SidebarTableTweaks` searches the window for the table at
      every update (about 5 ms at launch).
- [ ] Changed on the way, to confirm: a new folder, filter, search or sort starts at the top of the grid (it
      kept the old scroll offset); the inspector keeps its scroll position while stepping through images; the
      main window's default size is 1440 x 900 (the size was attached to the Settings scene and did nothing).

## Themes (owner, 2026-11-17)

- [ ] Preferences > Appearance: **Accent theme** with System (default), Neon (Griddo's lime and magenta),
      Graphite (monochrome), Violet, Rose, and a **Colored icons** switch. Spec in `docs/DESIGN-SYSTEM.md`
      ("Themes (accent)"). Small work, after the speed pass: one theme value read in one place
      (replaces `Color.accentColor` and `NSColor.controlAccentColor` in about a dozen spots), the grid's
      AppKit selection ring wired separately, fills use a per-theme `onAccent` (a bright accent needs dark
      text). No full theming (no light/dark or font per theme). More themes later, one row each.
