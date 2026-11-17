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
- [ ] Known limit: macOS itself remembers the last folder shown by the Open panel; that is
      system state we cannot control.

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
