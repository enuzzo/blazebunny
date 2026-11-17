# M5 stage 1: folder tree inside one-folder libraries

Spec: `docs/superpowers/specs/2026-11-17-libraries-and-folders-design.md` (approved; not reopened).
Scope: stage 1 only. No library migration, no multi-folder libraries.

## Decisions

- **Schema v3.** `dirs(id, parent_id, name, path UNIQUE, depth)`; `items.dir_id`. The library root is a
  row with `path = ''` and no parent. `dirs` has an index on `parent_id`, `items` one on `dir_id`
  and one on `(dir_id, date)` so a single-folder scope is an ordered index range.
- **Migration** fills `dirs` and `dir_id` from `rel_path` in one transaction, no disk access;
  thumbnails and metadata are untouched.
- **Scope = integer match.** `items.dir_id IN (subtree)`, the subtree being a recursive CTE over `dirs`
  (a few thousand rows at most). A leaf folder uses `dir_id = ?`. No `rel_path` prefix. The planner
  choice is measured (see `docs/MILESTONES.md`) and an `INDEXED BY` hint is used if it picks the date index.
- **Saved searches** remember the scope as a relative folder *path* (`SearchQuery.folder`), resolved to an id
  at query time, so it survives a rebuilt `dirs` table.
- **Tree API** `LibraryIndex.directoryTree()` returns flat nodes (id, parent, name, path, depth,
  `directCount`, `subtreeCount`): one `GROUP BY dir_id` over the index plus an in-memory roll-up.
- **Scanner** records every enumerated directory (so empty folders exist), sets `dir_id` on upsert,
  and prunes vanished directories only under the existing trustworthy-listing rule.
- **App**: sidebar Folders section (disclosure tree, counts, expanded state in UserDefaults per library),
  `LibraryModel.scope` feeds every query, the context line and the saved-search sheet. Sidebar made lively
  per DESIGN-SYSTEM.md.

## Steps

1. Core tests first (`FolderScopeTests`): migration from a hand-built v2 file; tree and counts; nested scope;
   rename/move between folders on rescan; empty folders; unicode and deep paths; scope + filter + search;
   facet counts and histogram with scope; saved-search scope round trip; 100k budget test.
2. Core implementation until green; keep the 62 existing tests passing.
3. Benchmark target `bbscopebench` (generated 100k index, release): scope change, filter change, tree, memory.
4. App: model, sidebar, header context line, save-search scope, alive sidebar styling, DS tokens.
5. Build the app, generate a nested demo folder in the scratchpad (fake PNGs), check by screenshot.
6. Record numbers in `docs/MILESTONES.md`, update `docs/DESIGN-SYSTEM.md`. Leave uncommitted.
