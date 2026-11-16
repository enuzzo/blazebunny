# Blazebunny — design (v1)

*Hops through your archive faster than you can scroll.*

Date: 2026-11-16. Owner: enuzzo. Status: approved by the owner on 2026-11-16.

## 1. Intent

Blazebunny is a native, open-source macOS app for browsing very large image
folders — tens of thousands of files, often on slow external disks — at full
speed, and for showing the metadata that Finder and most viewers hide.

The trigger is the owner's Midjourney archive: about 19,900 files (≈18,800 PNG,
≈1,050 JPEG, a few MP4/MOV/WebP/PSD), ~50 GB, one flat folder on an external
disk that reads at roughly 8 MB/s on large reads. Listing the folder alone took
87 s on a cold disk. Every file date is the export date, so the only real
creation time is the one embedded in the PNG. Each Midjourney PNG carries,
**before the first `IDAT`, within the first ~1 KB**:

| PNG chunk | Content (shape only) |
|---|---|
| `tEXt` `Creation Time` | `Mon, 22 Dec 2025 22:04:32 GMT` (RFC 1123, GMT) |
| `tEXt` `Author` | the Midjourney user name |
| `tEXt` `Description` | `<prompt text> --ar 16:9 --v 7 Job ID: <uuid>` |
| `tEXt` (or `iTXt`) `XML:com.adobe.xmp` | XMP with `iptcExt:DigitalSourceType` and the job id |

File names look like `<prompt_slug>_<job uuid>_<index>.png`.

Measured on a random sample of 600 PNGs (read-only, counts only):

- 28 % of the PNGs carry **no** Midjourney text at all (no `Description`, no
  `Creation Time`); they fall back to EXIF/XMP or the file date.
- Every `Description` found ends with `Job ID: <uuid>`.
- XMP is stored as `tEXt` in some files and `iTXt` in others.
- Flags seen, most common first: `ar`, `v`, `stylize`, `chaos`, `raw`, `sref`,
  `profile`, `exp`, `hd`, `style`, `sv`, `quality`, `preview`, `niji`, `sw`,
  `weird`, `no`, `cref`, `personalize`, `seed`.
- ~7 % have a parameter with several values (`--sref` with several codes or
  URLs), ~3 % start with an image URL, ~1 % use `::` weights, a few use
  `--no` with several words.
- The first `IDAT` starts at byte ~1,000 (median), ~3,500 (p99), 27,905 (max).
- Throughput: ~30 files/s reading the first 64 KB of random files; the disk
  is a 5 TB USB APFS volume, almost certainly spinning, so **seeks, not
  bytes, set the pace**. A naive metadata pass is ~11 minutes for 20k files.

The owner calls the archive a gold mine. What they do with it, in their words:
**copy the prompt to run it again in Midjourney**, or **pick the image to
upscale it** (in another app).

## 2. Goals (v1)

1. Open a folder; build a small local index of every image in it, quickly,
   with bounded reads, on slow disks; reopen it later instantly.
2. Show, next to the selected image, the full prompt, its parameters as
   separate chips, the embedded creation time, the author, pixel size, file
   name, and whether the original is currently reachable.
3. Copy, always ready to paste into Midjourney: **Copy prompt** = text +
   parameters, **without** the `Job ID` (⌘C does this); **Copy text** = text
   only, including any leading image URLs and `::` weights; **Copy
   parameters** = the parameter string only. With several items selected,
   each copy puts one prompt per line.
4. Hand off the original: drag from the grid into any app, **Show in Finder**,
   **Open With…**, Space for Quick Look.
5. Search the prompt text (and file name), sort by embedded creation time,
   name, file size or pixel size, filter by aspect ratio (`--ar`).
6. Smooth scrolling over 20,000+ items; adjustable thumbnail size.
7. Browse with the disk unplugged: index and thumbnails live on the Mac.

## 3. Non-goals (v1)

- Moodboard layouts (masonry, mosaic, packed) — **v2**.
- Portable library (cache stored next to the images) — later.
- Video metadata (videos get a thumbnail only), PSD beyond what ImageIO gives.
- Editing or writing metadata, tags, ratings, collections, deduplication.
- iOS/iPadOS, sync, cloud, accounts.

## 4. Anti-goals (failure even if it works)

- **Writing anything inside a scanned folder**, renaming, or touching file
  dates. Blazebunny opens source files read-only, always.
- Making the user wait on the disk to browse what is already indexed.
- Heavy third-party dependencies. Only Apple frameworks (SwiftUI, AppKit,
  ImageIO, AVFoundation, QuickLook) and the system SQLite.
- Any network access or telemetry.
- A cache made of tens of thousands of small files (it overwhelms Time
  Machine, Spotlight and Dropbox).

## 5. Constraints

- Swift 6, macOS 15 or later, Apple silicon and Intel.
- Built from the command line (SwiftPM) so the repo has no Xcode project to
  maintain; a script assembles `Blazebunny.app`.
- Open source under the **MIT licence**, public on GitHub as
  `enuzzo/blazebunny`.
- Distribution: the owner has an Apple Developer Program membership.
  `scripts/build-app.sh` makes an ad-hoc signed build for local use; a
  `scripts/release.sh` signs with Developer ID, enables the hardened runtime,
  notarizes with `notarytool` (credentials from a local keychain profile,
  never in the repo) and staples the ticket, producing a zip or DMG for
  GitHub Releases. The release script is written in v1 but the first public
  release happens only when the owner asks.
- The repo and its test fixtures must never contain the owner's images,
  prompts or file names. Tests generate their own PNGs with the same chunks.
- `gitleaks dir .` before the first commit.

## 6. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | SwiftUI shell + AppKit `NSCollectionView` grid; SQLite index with FTS5; thumbnails in a few large pack files | Most code, but the only one that stays smooth at 20k–100k items and searches in milliseconds |
| B | Pure SwiftUI `LazyVGrid`; JSON index; thumbnails as files | Simplest; JSON is rewritten whole on every change (~15 MB here), linear search, the grid stutters beyond a few thousand items |
| C | Core Data / SwiftData | Standard Apple persistence, but heavier and opaque about when it reads and writes; no gain over SQLite here |

The owner picked **A**. JSON survives as an **export** (“Export index as JSON”).

## 7. Design

### 7.1 Libraries and where data lives

A *library* is one opened folder. All its data lives on the Mac in
`~/Library/Application Support/Blazebunny/Libraries/<library-id>/`:

- `index.sqlite` (WAL mode) — the index.
- `thumbs-NNN.pack` — append-only pack files of encoded thumbnails, rolled
  over at ~256 MB.

`<library-id>` is derived from the volume UUID plus the folder path relative
to the volume root, so the same disk mounted at another path, or on another
day, reopens the same library. Volumes without a stable UUID (network shares,
some FAT/exFAT disks) fall back to the volume name plus the relative path. A
bookmark of the folder is stored too, to find it again if it moves.

The app is **not sandboxed** in v1: it reads any folder the user opens, and
plain bookmarks are enough.

*Builder's note, my call:* Application Support instead of `~/Library/Caches`
(mentioned in the conversation), because macOS may purge Caches under storage
pressure and the whole point is browsing with the disk unplugged after an
hour-long thumbnail pass. Pack files are marked excluded from Time Machine
(they can be regenerated). A “Delete cache” command per library frees the
space.

The sidebar lists the opened libraries, each with an online/offline badge.

### 7.2 Index schema (SQLite)

```sql
items(
  id INTEGER PRIMARY KEY,
  rel_path TEXT UNIQUE NOT NULL,     -- relative to the library root
  file_size INTEGER, file_mtime REAL, -- change detection
  kind TEXT,                          -- png, jpeg, webp, heic, mp4, mov, psd, other
  width INTEGER, height INTEGER,
  created_at REAL,                    -- embedded creation time (UTC), NULL if none
  created_source TEXT,                -- 'png-text', 'exif', 'xmp', 'file' (fallback)
  author TEXT,
  prompt_raw TEXT,                    -- the Description as found
  prompt_text TEXT,                   -- without parameters and Job ID
  params TEXT,                        -- JSON array of {name, value}
  aspect TEXT,                        -- normalised --ar, or computed from w/h
  job_id TEXT,
  xmp TEXT,                           -- raw XMP packet, kept for later
  meta_state INTEGER,                 -- 0 pending, 1 done, 2 failed
  thumb_pack INTEGER, thumb_offset INTEGER, thumb_length INTEGER,
  thumb_state INTEGER                 -- 0 pending, 1 done, 2 failed
);
CREATE VIRTUAL TABLE items_fts USING fts5(prompt_text, file_name,
  content='items', content_rowid='id');
library(key TEXT PRIMARY KEY, value BLOB);  -- schema version, bookmark, volume UUID, scan stats
```

The whole grid model is loaded into memory as a compact array of
`(id, sort keys, aspect)` at open; details are fetched per selection.

### 7.3 Scanning

Three resumable phases; the app can quit at any point and continue later.

1. **Enumerate.** Walk the folder (recursive, skipping hidden files and
   packages), collecting name, size and modification date in the same call.
   Items appear in the grid as placeholders while enumeration runs. Unchanged
   files (same size and mtime) are skipped on rescans. A rescan runs when a
   library is opened with its folder reachable, when its volume mounts, and
   on demand (⌘R); no live file watching in v1. A rescan only runs with the
   folder online, so a file it does not find is gone: its row is deleted and
   its pack space becomes garbage, reclaimed by a later compaction. When the
   folder is unreachable the whole library is shown as offline; nothing is
   deleted.
2. **Metadata.** For PNG, our own parser reads the signature and chunks up to
   the first `IDAT`, starting with one 64 KB read and extending only if a
   metadata chunk runs past it. It handles `tEXt`, `zTXt`, `iTXt` (compressed
   or not) and `IHDR` for pixel size. For JPEG/WebP/HEIC, ImageIO properties
   (EXIF `DateTimeOriginal`, XMP) with caching disabled. Midjourney parsing
   rules:
   - strip a trailing `Job ID: <uuid>` into `job_id`;
   - the parameters start at the first ` --<letters>` token; everything
     before it is the text (leading image URLs, `::` weights and `{a,b}`
     permutations stay in the text untouched);
   - each parameter is a flag plus all tokens up to the next ` --` flag, so
     `--sref <code> <url>` and `--no red, blue` keep their full values;
     flags without a value (`--raw`, `--hd`) have an empty value; unknown
     flags are kept as they are;
   - `aspect` comes from `--ar` (default `1:1` when a Midjourney prompt has
     none), otherwise from width/height reduced to the nearest common ratio;
   - `Creation Time` parsed as RFC 1123 in GMT.
   Non-Midjourney images fall back to EXIF/XMP dates, then the file date
   (`created_source` says which, and the inspector shows it).
   Tests cover each of these shapes with invented prompts.

   Because seeks set the pace on spinning disks, reads follow the directory
   enumeration order (close to on-disk order) rather than name order, start
   with a 4 KB read (enough for 99 % of files) and extend only when needed.
   `bbbench` measures 1, 2 and 4 concurrent reads on the real disk; the
   target is to beat the naive ~11 minutes for the test archive.
3. **Thumbnails.** One sequential read of the whole file, then ImageIO
   `CGImageSourceCreateThumbnailAtIndex` (max 512 px, transform applied),
   encoded and appended to the current pack. Videos: AVFoundation frame grab.
   **Visible and nearby items first**, then everything else in the background.

Disk I/O is the bottleneck, so reads run through a small I/O queue (start at
2 concurrent reads, measured and tuned per volume; SSDs can take more), while
decoding and encoding run in parallel on the CPU. Progress shows in a status
bar (“Indexed 12,345 / 19,890 · thumbnails 3,210 · 7.8 MB/s”) with pause and
resume.

Expected on the test archive: phases 1–2 in a few minutes; phase 3 bound by
50 GB of reads, about 1¾ hours at 8 MB/s, running in the background while the
user already browses and searches.

### 7.4 Thumbnail cache

- Pack files on disk, read with memory mapping; an `NSCache` of decoded
  images in memory sized to a few screens.
- 512 px long side covers the largest grid size on Retina. Encoding
  (JPEG ~0.75 vs HEIC) is chosen by measuring speed and size on generated
  samples — left to the builder.
- Expected size for 20k items: roughly 0.5–1 GB.

### 7.5 Interface

```
┌──────────────┬──────────────────────────────────────────┬───────────────────────┐
│ Libraries    │ [🔍 search prompts]  Sort ▾  --ar ▾  ━●━ │  ┌─────────────────┐  │
│ ● Midjourney │ ┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐        │  │   preview       │  │
│ ○ Photos 2024│ │  ││  ││  ││  ││  ││  ││  ││  │        │  └─────────────────┘  │
│              │ └──┘└──┘└──┘└──┘└──┘└──┘└──┘└──┘        │ Prompt  [Copy] [Text] │
│ + Open folder│ ┌──┐┌──┐┌──┐ …                           │ …full prompt…         │
│              │                                          │ [--ar 16:9] [--v 7]   │
│              │                                          │ Created 22 Dec 2025   │
│              │                                          │ 2912×1632 · 3.1 MB    │
│              │ Indexed 19,890 · thumbs 3,210 · 7.8 MB/s │ [Show in Finder] [⋯]  │
└──────────────┴──────────────────────────────────────────┴───────────────────────┘
```

- SwiftUI `NavigationSplitView`: libraries sidebar, grid, inspector.
- Grid: AppKit `NSCollectionView` with a flow layout of square cells
  (aspect-fit image), wrapped for SwiftUI; cell size from a slider (⌘+ / ⌘−).
  Keyboard navigation, multiple selection, Space for Quick Look, drag out as
  file URLs (only when the original is online).
- Inspector: preview (the thumbnail, upgraded to a larger image read from the
  original when online), prompt with copy buttons, parameter chips, dates,
  size, path, online/offline state.
- Search is live (FTS5, prefix matching); sort and aspect filter in the
  toolbar.
- Offline: everything indexed stays browsable; actions that need the original
  are disabled with a clear “Disk not connected” note.

### 7.6 Code layout

- `BlazebunnyCore` (library): PNG chunk parser, Midjourney prompt parser,
  metadata readers, scanner, SQLite index, thumbnail packs. Fully tested.
- `Blazebunny` (executable): SwiftUI/AppKit app.
- `bbbench` (executable): command-line scan of a folder into a throwaway
  library, printing timings — used to measure on the slow disk without the UI.
- `scripts/build-app.sh`: release build, `.app` bundle, ad-hoc signature.
- Tests use Swift Testing with generated fixtures (synthetic PNGs carrying the
  same chunks, JPEGs with EXIF/XMP).

### 7.7 Performance targets

- Reopen an indexed library: grid on screen in under 1 s.
- Scroll at the display's refresh rate with 20,000 items.
- Search results in under 50 ms.
- Metadata for the test archive faster than the naive ~11 minutes on its
  spinning USB disk (measured with `bbbench`; the session building v1 may
  read that folder, read-only, to measure).
- `bbbench` and the app never open a source file for writing; a test checks
  that a scan leaves a fixture folder byte-for-byte and date-for-date
  unchanged.

## 8. Decided by the owner

- Name **Blazebunny**, subtitle *Hops through your archive faster than you
  can scroll.*
- Cache on the Mac by default; portable library later.
- v1 centres on copying prompts and handing originals off for upscaling.
- Moodboard in v2.
- Approach A: AppKit grid + SQLite.
- MIT licence; signed and notarized releases with the owner's Developer ID.

## 8b. Calls made by the designer (for the owner to check)

- Index and thumbnails in Application Support, not Caches (Caches can be
  purged by macOS).
- Copy prompt drops the `Job ID`; parameters split at the first ` --flag`.
- Rescan on open, on mount and on ⌘R; files gone from an online folder are
  removed from the index.
- Not sandboxed in v1; macOS 15+; SwiftPM, no Xcode project.
- A `bbbench` command-line tool to measure scanning on the real disk.

## 9. Left to the builder

Thumbnail encoding, I/O concurrency tuning, the exact cell layout, the
placeholder look, error messages wording, the app icon (a bunny made of
blazing thumbnails is the idea), sort of ties.

## 10. Revision after the mockups (2026-11-16, approved by the owner)

Mockups: `docs/design/mockup-v1.html` (rejected: facet wall too cramped,
too Midjourney-centric) and `docs/design/mockup-v2.html` (approved).

- **Generic first, Midjourney as a reader.** Every item gets a detected
  *source*: Camera (EXIF make/model), Midjourney (`Description` with
  `Job ID`), Stable Diffusion / ComfyUI (PNG `parameters`, `prompt` or
  `workflow` text), Screenshot (EXIF/XMP user comment "Screenshot"), or
  Unknown. Source is a filter like any other. Generator-specific filters and
  inspector sections appear only for items of that source.
- **Filter row of pills** under the toolbar: `Type`, `Shape`
  (orientation + exact ratio), `Date` (histogram by month + presets),
  `Source`, then contextual groups (`✦ Midjourney`: Version, Parameters;
  `◉ Camera`: Camera). Each pill opens a popover with checkboxes and live
  counts (counts apply every other active filter). OR inside a pill, AND
  across pills; Midjourney Parameters is "all of". An active pill shows its
  values and an ✕. `Clear` and `Save Search…` at the trailing end.
- **Click a value to filter** anywhere in the inspector.
- **Saved searches** in the sidebar: name, colour, optional folder (one
  level), the full filter state, search text and sort. Stored in the
  library's index. Built-in views per library: Recently Added, Generated,
  Photos, Screenshots.
- **Grid:** Fill/Fit toggle, month section headers pinned while scrolling
  when sorted by date, a small source glyph per cell.
- **Inspector adapts:** source badge; Prompt (generated images) with Copy;
  Midjourney table; Generation table (Stable Diffusion: model, steps, CFG,
  seed, sampler); Camera table (camera, lens, exposure); File table always.
- Sidebar and toolbar are system chrome (Liquid Glass with the 27 SDK);
  grid, filter row and inspector are content: no custom glass.
