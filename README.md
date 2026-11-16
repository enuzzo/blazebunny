# 🐰🔥 Blazebunny

*Hops through your archive faster than you can scroll.*

Blazebunny is a native macOS app for browsing huge image folders — tens of
thousands of files, even on slow external disks — and for showing the metadata
most apps ignore: the original creation time and the full prompt that
Midjourney (and other tools) embed inside each PNG.

> Status: early development (milestone 1).

## What it does

- **Indexes once, browses instantly.** A small SQLite index and packed
  thumbnails live on your Mac, so browsing never waits on the disk again —
  and keeps working with the disk unplugged.
- **Reads hidden metadata.** PNG `tEXt`/`zTXt`/`iTXt` chunks (`Creation Time`,
  `Author`, `Description`, XMP), EXIF and XMP from JPEG, WebP and HEIC.
- **Midjourney-aware.** Splits the prompt into text and parameters
  (`--ar 16:9 --v 7`), drops the `Job ID`, and copies a prompt that is ready to
  paste back into Midjourney.
- **Search and sort.** Full-text search over prompts; sort by the real,
  embedded creation time.
- **Never touches your files.** Source folders are opened read-only. Nothing is
  written, renamed or re-dated inside them.
- **Native and light.** SwiftUI + AppKit, ImageIO, system SQLite. No
  third-party dependencies.

## Requirements

macOS 15 or later, Swift 6 toolchain (Xcode 16 or later).

## Build

```bash
swift test
scripts/build-app.sh        # builds build/Blazebunny.app (ad-hoc signed)
open build/Blazebunny.app
```

Measure scanning speed on a folder without the UI:

```bash
swift run -c release bbbench /path/to/folder
```

## Where data lives

`~/Library/Application Support/Blazebunny/Libraries/<library-id>/` holds the
index (`index.sqlite`) and thumbnail packs (`thumbs-NNN.pack`) for each folder
you open. Delete that folder to forget a library.

## Licence

MIT — see [LICENSE](LICENSE).
