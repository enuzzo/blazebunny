# Blazebunny roadmap: dark-glass UI round and what follows

Date: 2026-11-17. Status: **draft, waiting for owner approval**. Nothing below is built yet
except step 0.

## Intent

Blazebunny is a fast native browser for huge image archives (20k+ files, local or
external disks). Its strengths to protect: speed on big libraries, saved searches used
like quick albums, read-only access to sources. This round gives it a visual identity
(dark frosted glass, a distinctive typeface), and the tools a person who judges images all
day expects: a proper full-screen viewer, every piece of metadata, a comparer, folder
trees, and a way to look at private folders without leaving traces.

## Goals / non-goals / anti-goals

- Goals: each item below ships on its own, tested in `BlazebunnyCore` where it is logic.
- Non-goals: editing images, network features, cloud sync, any write inside a scanned folder.
- Anti-goals: a UI that looks busy ("no rainbow"); anything that slows scrolling a
  23k-image library; leaving thumbnails or index data of a ghost folder on disk.

## Constraints (from AGENTS.md, owner's amendments marked)

- Read-only sources. No network. Swift 6, macOS 15.
- Third-party **code** stays out. **Owner-approved amendment (to be written into
  AGENTS.md in step 1):** free, openly licensed *resources* may be bundled (fonts under OFL,
  line icons under ISC/MIT), each listed with its licence in `NOTICE`. SF Symbols stay the
  default for icons; bundled SVGs only where SF Symbols has no good match.
- Dark-glass rules already in AGENTS.md apply; glass never over the image grid.

## Work items, in proposed order

Each gets its own short design (approaches, then approval) just before it is built.

0. **Commit the current round** (dark theme, one-row header, rename, library summary,
   footer, thumbnails alternating with metadata, summary APIs). Done in code, uncommitted.
1. **Preferences window + typeface.** A Preferences scene (it will also hold viewer
   settings). A distinctive typeface for titles, numbers and sidebar, in the spirit of the
   reference (it uses Geist and JetBrains Mono); candidates compared side by side in a
   browser mock before choosing. A toggle in Preferences falls back to the system font.
   Includes the AGENTS.md/NOTICE amendment above.
2. **Ghost (temporary) folders.** On adding a folder the owner chooses "Add as ghost".
   A ghost keeps its index and thumbnails only in a temporary location, never in
   Application Support, is not remembered across launches, and is purged when closed, on
   quit, and (for crashes) on next launch. Marked in the sidebar with a ghost icon. Meant
   for exploring folders of private or accounting documents.
   Open: ghost data in RAM-only vs a temp directory (temp directory is the proposal).
3. **Folder trees.** Adding a folder with subfolders: the parent shows everything below it;
   selecting a subfolder shows only its contents (and its own subfolders in turn). The
   sidebar shows a disclosure tree. Items already store `rel_path`, so this is a path-prefix
   filter plus a tree built from distinct directories; no re-indexing.
4. **Full-screen viewer.** Opens with double-click or Space; arrows left/right (and up/down)
   move through the current grid order; key repeat must stay smooth ("ultra fast"):
   previews from the thumbnail first, sharp image decoded behind it, neighbours prefetched.
   A mini thumbnail strip at the bottom. Default background solid black; Preferences offers
   white, cream, black, "frame" (a bordered matte) and a custom colour. Controls appear as an
   overlay only while hovering; the top bar has Fit to Screen, 100%, and related zoom
   steps. Esc/Space closes.
5. **Full-metadata inspector.** Every readable value of the file, shown in grouped,
   well laid-out sections with line icons and a restrained colour per group (not a
   rainbow). Read on demand from the original file through ImageIO (EXIF, TIFF, GPS, IPTC,
   maker notes, XMP, PNG chunks), read-only. Everything is copyable: a row, a group, or all.
6. **Comparer and saved selections.** Compare any number of images side by side. A
   collection tray in the sidebar can be filled by dragging while scrolling huge libraries;
   open it as a comparer. A tray can be saved to the sidebar next to saved searches.
   Proposal: both kinds coexist, a *saved search* (filters, live) and a *saved selection*
   (a fixed list of images, like a manual album), with different icons.
7. **More generators detected.** From the research (2026-11-17): OpenAI/ChatGPT images
   carry a C2PA manifest in a PNG `caBX` chunk (strings `OpenAI`, `ChatGPT`, `GPT-4o`,
   `c2pa.created`); Google (Gemini, Nano Banana) documents C2PA from `Google LLC` and the
   IPTC credit "Made with Google AI"; Firefly and Flux document C2PA without published
   strings; Ideogram, Leonardo, Grok, Canva have no confirmed marker. Detection: walk PNG
   chunks and JPEG APP11 segments (ImageIO cannot read C2PA), byte-search the issuer
   strings, no CBOR parsing. Rules: Midjourney and Stable Diffusion checks stay first,
   because Midjourney also writes `trainedAlgorithmicMedia` (1,129 files in the sampled
   archive). Labels say "looks like OpenAI", never "is": the manifest disappears on
   screenshots and re-saves and can be forged. SynthID cannot be detected offline.

## Approaches considered (high level)

- One big redesign branch vs small independent items. Chosen: independent items, each
  tested and shippable, because the order may change as the owner tries each one.
- Ghost data in RAM vs temp directory: temp directory (large libraries do not fit in RAM;
  purge covers it).
- Typeface: system fonts only (no character) vs bundled OFL fonts with a Preferences
  toggle. Chosen: bundled with toggle, per owner.

## Left to the builder

Exact keyboard map of the viewer, prefetch window size, tray drag UX details, icon set per
metadata group, schema for saved selections (a table next to `saved_searches`).
