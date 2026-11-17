# Libraries, folders and saved things: design

Date: 2026-11-17. Status: **approved by the owner on 2026-11-17** (stage 1 to be built in a separate Opus session;
the three inspector deviations listed in `docs/MILESTONES.md` are accepted). Sources: the owner's requests, the Fable 5.2 organization report
and mockup (2026-11-17, mockup kept under the session scratchpad), the Opus reviews (round 1 to 3).
Supersedes roadmap item 3 (folder trees) and M5/M8 in `docs/MILESTONES.md`.

## Intent

People keep huge archives spread over folders and disks. They need to open one or many folders,
browse a folder with everything below it, save quick "albums" (live searches and hand-picked lists),
collect images while scrolling, compare them, and reorganize all of it without ever touching the files.
It must be simple to understand, easy to grow and manage, and **shamelessly fast** (the app is called
Blazebunny for a reason).

## Goals, non-goals, anti-goals

- Goals: one clear model with few nouns; a library can hold several folders (even on different disks);
  subfolders at any depth; saved searches and collections side by side; a tray; ghosts; direct
  manipulation to reorganize; each stage shippable.
- Non-goals: editing or moving files on disk; renaming subfolders in the app; tags and ratings;
  cross-library collections; a merged grid across libraries.
- Anti-goals: a concept the user must learn twice; a modal edit mode; a feature that makes opening or
  scrolling a 100k library slower; any write inside a source folder.

## The model (nouns)

| Noun | One sentence for a first-time user | Notes |
|---|---|---|
| **Library** | A named place for one body of work: one or more folders, plus everything you save about them. | Replaces "Project" (owner accepted: a project implies an end; "Library" matches macOS Photos/Music). Today's one-folder library becomes a library with one folder. |
| **Folder** | A real folder on disk, shown as it is and never changed; click it to see everything inside, subfolders included. | "Root" and "source" are never shown in the UI. |
| **Saved search** | A search that stays in the sidebar and keeps itself up to date. | Gains an optional "in this folder" scope. Live rule. |
| **Collection** | Images you picked by hand; it changes only when you change it. | Replaces "saved selection". "Selection" stays for what is highlighted in the grid. Fixed list. |
| **Tray** | A temporary pile you fill while browsing, then compare or save as a collection. | One per library; docked at the bottom of the sidebar. |
| **Ghost** | A temporary library that deletes itself when closed. | A kind of library, never a folder inside a normal one. |
| **Group** | A sidebar heading that holds saved searches and collections. | Renames today's saved-search "folder", so "Folder" only ever means disk. One level. |

Dropped or merged: the **Views** section goes. "All Images" and "Recently Added" become fixed rows;
Generated, Photos and Screenshots become starter saved searches the user can delete. The comparer is a
view, not a sidebar noun.

## Structure and flows

Sidebar, top to bottom: **library switcher** (name, count) | All Images, Recently Added | Pinned |
**Folders** (tree of the library's folders, any depth, mirrors disk) | **Saved** (searches and
collections, one level of groups) | **Tray** dock | Add Folder and the ghost button.

- **Switcher:** a popover listing libraries with their folders, disks and offline state, type to filter,
  ⌃1 to ⌃9, ghosts in their own dashed amber group; also New Library, Open Ghost Folder, Search All Libraries.
- **Context line** above the title (11 pt): says what you look at and where, with clickable path parts,
  for example "Folder · Main Archive › Renders · on Disk B" or "Saved search · live · in Main Archive".
- **All Images** merges every folder of the current library by date; never across libraries.
- **Add Folder** (or a drop) opens one sheet: add to this library, new library named after the folder, or
  open as ghost. First launch has no choice (today's behaviour).
- **Remove / move a folder:** Remove from Library detaches it (files untouched). Moving: drag the row onto
  the switcher (it springs open) and drop on a library, or use the menu. Saved searches scoped to the
  folder travel with it. Every such action has Undo.
- **Merge and split:** "Merge into…" in the library menu moves folders, saved items (into a group named after
  the source) and the tray. Split is "New Library from This Folder".
- **Reorder and group:** drag rows directly, no edit mode. A line between rows reorders; a ring on a group
  files into it. Top-level folders reorder; subfolders stay alphabetical.
- **Rename:** double-click, slow click or menu. Only top-level folders take a display name; subfolders mirror
  the disk (rename in Finder). Colour for libraries and saved items; no custom icons (the icon says live
  versus fixed).
- **Pins:** any folder or saved item can be pinned to the top: the fast path to a deep subfolder.
- **Search scope:** a chip in the search field: here, this library, or all libraries. "All libraries"
  returns hit counts per library and a jump, not a merged grid. Ghosts are never searched from outside.
- **Live versus fixed:** saved search = bookmark-style icon and "live"; collection = stacked-squares icon and
  "fixed list". Dropping images on a collection adds them; on a saved search it is refused ("a live search
  fills itself"). "Freeze as Collection" turns a search's current results into a fixed list.
- **Tray:** drag images in or press T; then Compare, or Save as Collection (named inline, tray empties).
  Persists per library. Grid images already in the tray get a thin ring (to confirm in a mock).
- **Ghosts:** their searches, collections and tray die with them; a ghost cannot be moved or merged into a
  library. Dashed amber styling stays (M4).
- **Offline disk:** the folder dims with a coral drive icon; its images stay browsable from the local index
  and thumbnails; originals and rescans wait. **Moved folder:** "Locate Folder…" re-points the index.
- **Nesting:** folders unlimited; groups one level; libraries flat.

What we will NOT build: a merged all-libraries grid, nested libraries, a ghost folder inside a normal library,
re-parenting or renaming subfolders in the app, nested groups, custom icons, multiple trays, a sidebar edit
mode, cross-library collections (for now), tags, ratings, collections mixing rules with manual picks,
per-folder exclude rules.

## Under the hood

- **Per folder:** `index.sqlite` and thumbnail packs stay as they are. The folder's data directory is named
  by a stored id (existing hashes kept), not recomputed from the path, so a relocated folder keeps its index.
  New: a `dirs` table and a `dir_id` column on `items`, so a folder scope is an integer match, not a path
  prefix (a prefix range on an 8k subtree in a 100k index made the planner scan the date index: 117 ms in
  Fable's measurement; a `dir_id` match avoids it). The directory tree for 100k paths builds in about 34 ms.
- **Per library:** a small `library.sqlite`: folders (bookmark, volume, display name, position), saved items
  (kind, name, colour, group, position, query, optional scope), collection members, pins, the tray as a
  collection row.
- **Query:** each folder's index is queried and the sorted results merged in memory (about 172 ms for 120k
  items across three indexes in Python, similar to one index; Swift unmeasured). Facet counts add per folder.
- **Item identity:** in memory an item becomes (folder, rowid). This is the widest code change (selection,
  `ThumbnailLoader`, grid). For collections, a random `uid` column on `items`.
- **Collections surviving rescans:** before pruning vanished rows, the scanner re-links moved files (unique
  match on name, size, mtime) by updating `rel_path`, keeping uid, metadata and thumbnail. Unmatched members
  stay as "missing (n)" with Locate or Remove, never silently dropped. The pruning safety of review round 1
  stays.
- **Ghost:** both the per-folder and per-library files live under `GhostStorage`; nothing persistent mentions it.
- **Migration:** each saved library becomes a one-folder library; its `saved_searches` rows are copied, the
  originals left for rollback. No index is rebuilt, no disk is re-read.

## Speed: budgets and rules (the app is called Blaze)

Targets, measured on a 100k-image library on an internal SSD with a warm index, checked at every stage:
- App launch to a usable grid with cached thumbnails: under 300 ms.
- Switching library, folder scope or saved search: first rows on screen under 50 ms, complete under 150 ms.
- Changing a filter or search text: result visible under 30 ms for 23k items, under 100 ms for 100k.
- Scrolling: no dropped frames (120 Hz where the display allows); thumbnails appear without waiting on a lock.
- Scan: bounded by disk speed, never blocking the UI; no full grid reload when only thumbnails changed.
- Memory: grows with what is visible plus a bounded cache, not with library size.

Rules: nothing heavy on the main thread; no query that scales with total library size on every keystroke
or scroll; read thumbnails with `pread` and no shared lock; store thumbnail location in the browse item;
indexes on every filtered or grouped column; precompute (dirs, counts, histograms) instead of recomputing;
measure before and after each stage. After the stages, **Fable runs a speed assessment** of the whole app
against these budgets (owner's request), and its findings are applied before M5 is called done.

## Staged plan (each stage shippable)

1. **Folder tree inside today's one-folder libraries:** `dirs`/`dir_id`, folder scope, context line. No migration.
2. **Library file and switcher:** one folder per library still; ghosts in the switcher; Views dropped; Saved
   section (searches, groups); starter searches.
3. **Several folders per library:** composite ids, merge in memory, add/remove/move, merge and split with Undo,
   offline and missing states, "Locate Folder".
4. **Tray, collections and comparer (M8):** `uid` and move re-linking in the scanner.
5. **Pins, group polish, Search All Libraries.**
6. **Icons:** Iconoir (MIT; ghost drawn to match) replaces SF Symbols in the sidebar and controls. Needs a
   small spike on rendering: SVG as template images in SwiftUI, with a generated `Path` fallback; licence
   in `NOTICE`.
7. **Inspector redesign** from Fable's inspector mockup (focal point, calm rhythm, copyable groups, several-
   images and folder states) together with M7 full metadata.
8. **Speed assessment by Fable**, then its fixes.

## Riskiest assumptions

1. A fixed list can follow files in read-only folders with cheap fingerprints (name, size, mtime). If the
   owner renames or moves files in bulk, collections would show "missing" too often and a content hash at
   metadata time becomes necessary.
2. Load-everything-and-merge holds to about 300k items (to be measured in Swift at stage 3).
3. Composite item identity can be introduced without regressions in selection and thumbnails (stage 3 has the
   widest diff; covered by tests added first).

## Open questions (decide while building, cheap to change)

- Section title "Saved" or "Albums". The ring on tray images. Whether the tray may ever span libraries.

## Owner decisions, 2026-11-17 (after approval)

- Implementation: one session per stage, Opus for the risky stages (2 to 4), a fresh context each, tests
  first; visual stages can be done with the mockups open and screenshots compared.
- Icons: **Iconoir** (decided).
- The inspector deviations from Fable's mockup are accepted: no row rule on value rows, a fourth tint
  (rose #E2ABC6) for Location, and "Copy Exposure" as the one filled button for photos.
- **The sidebar must feel alive**, less muted: see "Sidebar: alive, not dull" in `docs/DESIGN-SYSTEM.md`.
  Reference the owner liked: Claude's own session sidebar (soft coloured glow at the edge, small vivid
  accents such as a teal switch and a blue progress bar, colour-coded legend squares, generous row rhythm,
  clear section titles).
- Mockups to imitate live in `docs/design/library-mockup/` (`index.html` organization, `index-inspector.html`).
