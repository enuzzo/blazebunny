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

- [ ] Add a folder that contains subfolders.
- [ ] Clicking the parent shows everything below it, together.
- [ ] Clicking one subfolder shows only its content, and its own subfolders in turn,
      to any depth. Sidebar shows the tree.

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
- [ ] Put thumbnail pack/offset/length in `BrowseItem` and read packs with `pread`, so cells do
      not wait on the index lock (26 to 110 ms per reload at 23k to 100k items).
- [ ] While scanning, skip a full grid `reloadData` when only `hasThumbnail` changed; compute the
      summary only while it is visible.
- [ ] Indexes on `items(kind)` and `file_name COLLATE NOCASE`; cache the month histogram; page
      `items()` for libraries beyond 100k.
- [ ] `ioConcurrency` by volume type (SSD about 1.8x faster at 6 than at 2).
- [ ] "Recently Added" uses the embedded date, not when the file entered the library.
- [ ] Refresh stale bookmarks; symlinked files and folders are skipped; zero-byte files are
      marked failed; delete the index of a forgotten library.
- [ ] Tests still missing: scanner cancel mid-batch, priority ordering, ThumbnailLoader across a
      switch, summary with search plus facets, ghost lifecycle at the model level.
- [ ] AGENTS.md sweep (round 2): `.monospacedDigit()` in BlazebunnyApp and InspectorView,
      literal `.font(.system(size: 8))` in FilterRow, AppKit literal fonts in GridView, literal
      spacings and radii outside `DS`.

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
- [ ] Literal sweep: spacings and radii outside `DS` (add Space 6 and 10, Radius 12), `FilterPill` should
      reuse `PillStyle`, icon sizes (8 to 19) onto a small scale, AppKit literals in `GridView`.
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
