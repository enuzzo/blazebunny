# Blazebunny M1 (scan + grid + prompt) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First working build: open a folder, index it into SQLite with Midjourney metadata, generate packed thumbnails, show a fast grid and the prompt of the selected image with copy buttons and live search.

**Architecture:** SwiftPM package. `BlazebunnyCore` holds every non-UI piece (PNG text reader, Midjourney parser, metadata reader, SQLite index, scanner, thumbnail packs) and is fully unit-tested. `Blazebunny` is a SwiftUI app with an AppKit `NSCollectionView` grid. `bbbench` is a CLI that runs the same scanner and prints timings.

**Tech Stack:** Swift 6, macOS 15+, SwiftUI, AppKit, ImageIO, Compression, system SQLite3, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-16-blazebunny-design.md`

## Global Constraints

- Apple frameworks and system SQLite only; no third-party packages.
- Source folders are opened read-only; nothing is ever written, renamed or re-dated inside them.
- Library data lives in `~/Library/Application Support/Blazebunny/Libraries/<library-id>/` (`index.sqlite`, `thumbs-NNN.pack`, pack roll-over ~256 MB).
- Thumbnails: max 512 px long side.
- Copy prompt = text + parameters without `Job ID`; Copy text = text only; Copy parameters = parameter string only.
- No real archive prompts, images or file names in the repo or fixtures.
- Code, comments, docs, commits in English. MIT licence.

## Review Focus

1. PNG whose text chunks run past the first read window → reader extends the read and still finds them (test in Task 2).
2. PNG with no text chunks at all (28 % of the archive) → item indexed with `created_source = file`, empty prompt, no crash (Task 4).
3. Truncated or non-PNG bytes with a `.png` name → metadata state `failed`, scan continues (Task 2, Task 6).
4. Rescan after a file was removed → row deleted; unchanged files not re-read (Task 6).
5. Scan never modifies the source folder (bytes, mtimes, no new entries) (Task 6).

---

### Task 1: Package scaffold and docs

**Files:** `Package.swift`, `README.md`, `AGENTS.md`, `LICENSE`, `.gitignore`, `Sources/BlazebunnyCore/Blazebunny.swift`, `Tests/BlazebunnyCoreTests/SmokeTests.swift`

- [ ] Package with products: library `BlazebunnyCore`, executables `Blazebunny`, `bbbench`; test target `BlazebunnyCoreTests`; platform `.macOS(.v15)`; `BlazebunnyCore` links `sqlite3`.
- [ ] `swift build` and `swift test` pass with a smoke test.
- [ ] `gitleaks dir .` clean; first commit.

### Task 2: PNG text reader

**Files:** `Sources/BlazebunnyCore/PNGTextReader.swift`, `Tests/BlazebunnyCoreTests/Support/PNGFixture.swift`, `Tests/BlazebunnyCoreTests/PNGTextReaderTests.swift`

**Interfaces — Produces:**
- `struct PNGTextInfo { var width: Int; var height: Int; var text: [String: String] }` (keys as in the chunk; XMP under `"XML:com.adobe.xmp"`)
- `enum PNGTextReader { static func read(fileHandle: FileHandle, initialWindow: Int = 4096) throws -> PNGTextInfo; static func parse(_ data: Data) -> ParseResult }` where `ParseResult` is `.complete(PNGTextInfo)`, `.needMore(Int)` or `.invalid`.
- Test support: `PNGFixture.make(width:height:text: [(type: "tEXt"|"zTXt"|"iTXt", key: String, value: String)], padding: Int = 0) -> Data` builds a real PNG via ImageIO and splices the chunks before `IDAT` (padding inserts a large private chunk before them).

- [ ] Tests: tEXt keys and IHDR size read; zTXt and iTXt (compressed and not) decoded; chunks beyond the initial 4 KB window found with `padding: 40_000`; random bytes → throws `PNGTextReader.Error.notPNG`; truncated file → throws.
- [ ] Implement; zlib streams decoded with `Compression` (`COMPRESSION_ZLIB`, skipping the 2-byte header). Stop at the first `IDAT`.

### Task 3: Midjourney prompt parser

**Files:** `Sources/BlazebunnyCore/MidjourneyPrompt.swift`, `Tests/BlazebunnyCoreTests/MidjourneyPromptTests.swift`

**Interfaces — Produces:**
- `struct PromptParameter: Codable, Hashable { var name: String; var value: String }`
- `struct MidjourneyPrompt { var text: String; var parameters: [PromptParameter]; var jobID: String?; init(raw: String); var fullPrompt: String /* text + params, no Job ID */; var parameterString: String; var aspect: String? /* --ar value */ }`
- `enum PNGDate { static func parse(_ s: String) -> Date? }` (RFC 1123, GMT)

- [ ] Tests with invented prompts: `"a cat in rain --ar 16:9 --v 7 Job ID: 0f8e…"` → text `"a cat in rain"`, params `[ar 16:9, v 7]`, jobID; flag without value (`--raw`); multi-value (`--sref 123 https://x.test/a.png`); `--no red, blue`; leading URL `"https://x.test/i.png a dog --v 6"` keeps URL in text; `::` weights stay in text; no params; no Job ID; `fullPrompt` round-trips without Job ID; `PNGDate.parse("Mon, 22 Dec 2025 22:04:32 GMT")` equals the expected epoch.

### Task 4: Metadata reader

**Files:** `Sources/BlazebunnyCore/MetadataReader.swift`, `Sources/BlazebunnyCore/ItemMetadata.swift`, tests.

**Interfaces — Produces:**
- `enum ItemKind: String { case png, jpeg, webp, heic, gif, tiff, mp4, mov, psd, other; init(pathExtension:) }`
- `struct ItemMetadata { var width, height: Int?; var createdAt: Date?; var createdSource: String /* png-text|exif|xmp|file */; var author: String?; var promptRaw: String?; var prompt: MidjourneyPrompt?; var xmp: String? }`
- `enum MetadataReader { static func read(url: URL, kind: ItemKind, fileDate: Date) throws -> ItemMetadata }`

- [ ] Tests: MJ fixture → createdSource `png-text`, author, prompt; PNG without text → `file`, date = fileDate; JPEG fixture with EXIF DateTimeOriginal (written via ImageIO) → `exif`.
- [ ] PNG via `PNGTextReader`; others via `CGImageSourceCopyPropertiesAtIndex` with `kCGImageSourceShouldCache: false`; videos: no metadata, file date.

### Task 5: SQLite index

**Files:** `Sources/BlazebunnyCore/SQLite.swift` (thin wrapper), `Sources/BlazebunnyCore/LibraryIndex.swift`, tests.

**Interfaces — Produces:**
- `struct FileRecord { var relPath: String; var size: Int64; var mtime: Double; var kind: ItemKind }`
- `struct GridItem: Hashable { var id: Int64; var relPath: String; var createdAt: Double?; var width: Int?; var height: Int?; var hasThumb: Bool }`
- `struct ItemDetail { var id: Int64; var relPath: String; var kind: ItemKind; var size: Int64; var metadata: ItemMetadata?; var createdSource: String }`
- `final class LibraryIndex` (`@unchecked Sendable`, serial internal queue): `init(url: URL) throws`; `func knownFiles() throws -> [String: (size: Int64, mtime: Double)]`; `func upsertFiles(_: [FileRecord]) throws`; `func deleteFiles(relPaths: [String]) throws`; `func pendingMetadata(limit: Int) throws -> [(id: Int64, relPath: String, kind: ItemKind, mtime: Double)]`; `func saveMetadata(id: Int64, _: ItemMetadata?) throws` (nil → failed); `func pendingThumbnails(limit: Int) throws -> [(id: Int64, relPath: String, kind: ItemKind)]`; `func saveThumbnail(id: Int64, pack: Int, offset: Int64, length: Int) throws`; `func markThumbnailFailed(id: Int64) throws`; `func thumbnailLocation(id: Int64) throws -> (pack: Int, offset: Int64, length: Int)?`; `func gridItems(search: String?, sort: SortOrder) throws -> [GridItem]`; `func detail(id: Int64) throws -> ItemDetail?`; `func counts() throws -> (total: Int, metadata: Int, thumbnails: Int)`.
- `enum SortOrder { case createdDescending, createdAscending, name }` (createdAt falls back to file mtime).
- Schema as in spec §7.2, WAL, FTS5 table synced by triggers.

- [ ] Tests: upsert + gridItems count; changed mtime resets meta/thumb state; delete; FTS search `"rain cat"` matches prefix `"rai"`; sort by created with fallback.

### Task 6: Scanner

**Files:** `Sources/BlazebunnyCore/Scanner.swift`, `Sources/BlazebunnyCore/LibraryLocation.swift`, tests.

**Interfaces — Produces:**
- `struct LibraryLocation { static func libraryID(for folder: URL) -> String; static func directory(for folder: URL, base: URL = default) -> URL }` (volume UUID + relative path, SHA-256 hex prefix; fallback volume name).
- `struct ScanProgress: Sendable { var phase: Phase /* enumerating, metadata, thumbnails, done */; var total, metadataDone, thumbnailsDone: Int; var bytesRead: Int64 }`
- `final class Scanner` : `init(root: URL, index: LibraryIndex, thumbnails: ThumbnailStore?, ioConcurrency: Int = 2)`; `func run(progress: @Sendable (ScanProgress) -> Void) async throws`; `func cancel()`.
- Enumeration with `FileManager.enumerator(at:includingPropertiesForKeys:[.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])`, directory order preserved; supported extensions only.

- [ ] Tests on a temp fixture folder: first scan indexes all; second scan re-reads nothing (count metadata reads via injected counter); removing a file deletes its row; corrupt `.png` → failed, scan continues; folder snapshot (names, sizes, mtimes, sha of bytes) identical before and after.

### Task 7: Thumbnail store

**Files:** `Sources/BlazebunnyCore/ThumbnailStore.swift`, tests.

**Interfaces — Produces:**
- `final class ThumbnailStore` (`@unchecked Sendable`): `init(directory: URL, maxPackSize: Int64 = 256 << 20) throws`; `func append(_ data: Data) throws -> (pack: Int, offset: Int64, length: Int)`; `func data(pack: Int, offset: Int64, length: Int) throws -> Data`.
- `enum ThumbnailMaker { static func make(from url: URL, kind: ItemKind, maxPixel: Int = 512) throws -> Data }` (whole-file read, ImageIO thumbnail with transform, JPEG q 0.75; video via AVAssetImageGenerator).
- Packs excluded from backup (`isExcludedFromBackup`).

- [ ] Tests: append/read round-trip across a pack roll-over (`maxPackSize: 1000`); thumbnail of a 2000×1000 fixture is 512×256.
- [ ] Scanner phase 3 uses it (priority hook: `Scanner.prioritize(ids: [Int64])`, processed before the rest).

### Task 8: bbbench

**Files:** `Sources/bbbench/main.swift`

- [ ] `bbbench <folder> [--io N] [--no-thumbs] [--limit N]` scans into a temp library (deleted at exit), prints per-phase time, files/s, MB/s, counts of MJ/no-text/failed. Read-only on the source.

### Task 9: App

**Files:** `Sources/Blazebunny/BlazebunnyApp.swift`, `LibraryModel.swift`, `GridView.swift` (NSCollectionView representable + cell), `InspectorView.swift`, `ContentView.swift`, `Resources/Info.plist`, `scripts/build-app.sh`

- [ ] `LibraryModel` (`@MainActor @Observable`): open folder (NSOpenPanel), remember libraries (UserDefaults: list of bookmark data), load grid items, run Scanner in background with progress, refresh grid in batches (≤ 2 per second), search text → FTS, sort, selection → detail.
- [ ] Grid: `NSCollectionView` flow layout, cell size slider 80–320 pt, thumbnails loaded async from packs with `NSCache`, visible ids sent to `Scanner.prioritize`, single/multi selection, ⌘C copies prompt.
- [ ] Inspector: preview, prompt text, parameter chips, Copy prompt / Copy text / Copy parameters, created (with source), author, pixel size, file size, name, Show in Finder; offline note when the folder is not reachable.
- [ ] Status bar with progress counts.
- [ ] `scripts/build-app.sh`: `swift build -c release`, assemble `build/Blazebunny.app` with Info.plist, ad-hoc `codesign`.
- [ ] Manual check: open a generated fixture folder, then the archive (read-only), select, copy, search.

(Release script, Quick Look, drag out, aspect filter, Open With and JSON export follow in M2.)
