import Foundation
import BlazebunnyCore

// bbscopebench [--count N]
// Builds a generated index (no real files, no real data) and times the folder-scope paths the app uses.
// 100 top folders x 10 subfolders x (N/1000) files, plus one deep branch.

var count = 100_000
if let i = CommandLine.arguments.firstIndex(of: "--count"), i + 1 < CommandLine.arguments.count {
    count = Int(CommandLine.arguments[i + 1]) ?? count
}
// One big branch of 8 000 files (the "8k subtree" case) and the rest spread evenly.
let bigFiles = min(8_000, count / 10)
let perLeaf = max(1, (count - bigFiles) / 1000)

func ms(_ body: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}
func best(_ n: Int = 5, _ body: () throws -> Void) rethrows -> Double {
    var b = Double.infinity
    for _ in 0..<n { b = min(b, try ms(body)) }
    return b
}
func rssMB() -> Double {
    var info = mach_task_basic_info()
    var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) }
    }
    return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

// `--reuse <dir>` keeps the generated index there and uses it again on the next run (generation takes most of the time).
var reuse: URL?
if let i = CommandLine.arguments.firstIndex(of: "--reuse"), i + 1 < CommandLine.arguments.count {
    reuse = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}
let dir = reuse ?? FileManager.default.temporaryDirectory.appendingPathComponent("bbscope-" + UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let keepDB = CommandLine.arguments.contains("--keep") || reuse != nil
defer { if keepDB { print("kept \(dir.path)") } else { try? FileManager.default.removeItem(at: dir) } }
let idx = try LibraryIndex(url: dir.appendingPathComponent("index.sqlite"))

// Rows shaped like a real library's (measured on a 23k one: paths about 100 characters, prompts about
// 325, an XMP packet of about 860 bytes), so table scans cost what they cost in the app.
var rng: UInt64 = 0x9E3779B97F4A7C15
@MainActor func nextRandom() -> Int {
    rng = rng &* 6364136223846793005 &+ 1442695040888963407
    return Int(truncatingIfNeeded: rng >> 33)
}
let syllables = ["ka", "lo", "mi", "ren", "tas", "vu", "sho", "bel", "dra", "fin", "gor", "hal", "ix", "jun", "kel", "lum",
                 "mor", "nes", "ol", "pra", "qui", "ros", "sil", "tor", "ul", "ven", "wy", "xan", "yor", "zel"]
let vocabulary: [String] = (0..<3000).map { _ in (0..<(2 + nextRandom() % 3)).map { _ in syllables[nextRandom() % syllables.count] }.joined() }
let xmpPacket = String(repeating: "<rdf:Description rdf:about=\"\" xmlns:demo=\"http://ns.example.invalid/demo/1.0/\"/>", count: 10)
@MainActor func demoPrompt(_ i: Int) -> String {
    var words = (0..<42).map { _ in vocabulary[nextRandom() % vocabulary.count] }
    words.insert("lantern", at: nextRandom() % words.count)
    return "a \(words.joined(separator: " ")) in the fog \(i % 50) --ar 16:9 --v 7"
}
func demoName(_ f: Int) -> String { "demo_user_a_lantern_in_the_fog_at_dusk_wide_shot_\(String(format: "%08x-%04x-%04x", f &* 2654435761 & 0xFFFFFFFF, f & 0xFFFF, (f >> 3) & 0xFFFF)).png" }

if try idx.counts().total == 0 {
    var files: [FileRecord] = []
    for t in 0..<100 { for s in 0..<10 { for f in 0..<perLeaf {
        files.append(FileRecord(relPath: "Project \(t)/Batch \(s)/\(demoName(f))", size: 2_700_000, mtime: Double(1_600_000_000 + (t * 10 + s) * 86_400 + f), kind: .png))
    } } }
    for s in 0..<8 { for f in 0..<(bigFiles / 8) {
        files.append(FileRecord(relPath: "Big/Part \(s)/\(demoName(f))", size: 2_700_000, mtime: Double(1_500_000_000 + s * 86_400 + f), kind: .png))
    } }
    let ingest = try ms { try idx.upsertFiles(files) }
    let pending = try idx.pendingMetadata(limit: count)
    var batch: [(id: Int64, metadata: ItemMetadata?)] = []
    for (i, p) in pending.enumerated() {
        let mj = i % 3 != 0
        batch.append((p.id, ItemMetadata(width: 1024 + 64 * (i % 9), height: 1024, createdAt: Date(timeIntervalSince1970: Double(1_600_000_000 + i * 600)),
                                        promptRaw: mj ? demoPrompt(i) : nil, xmp: xmpPacket, source: mj ? .midjourney : .camera)))
    }
    let meta = try ms { try idx.saveMetadata(batch) }
    print("generated \(count) items: insert \(Int(ingest)) ms, metadata \(Int(meta)) ms, rss \(Int(rssMB())) MB")
} else {
    print("reusing \(try idx.counts().total) items in \(dir.path)")
}

let usePlannerStats = CommandLine.arguments.contains("--optimize")
if usePlannerStats { print("optimize: \(Int(try ms { try idx.optimize() })) ms") }
let top = try idx.dirID(forPath: "Big")!
let leaf = try idx.dirID(forPath: "Project 42/Batch 3")!
let q = FilterState()
var mj = FilterState(); mj.sources = [.midjourney]
let folderAll = try idx.dirID(forPath: "Project 7")!

func report(_ label: String, _ v: Double, budget: Double? = nil) {
    let flag = budget.map { v <= $0 ? "ok" : "OVER \(Int($0)) ms" } ?? ""
    print(String(format: "%-52@ %8.2f ms  %@", label as NSString, v, flag as NSString))
}

report("tree build (\(try idx.directoryTree().count) folders)", try best { _ = try idx.directoryTree() }, budget: 34)
report("dir lookup by path", try best { _ = try idx.dirID(forPath: "Project 42/Batch 3") })
// What the app does when a folder is selected.
func scopeReload(_ folder: Int64?, first: Bool) throws {
    if first { _ = try idx.items(filter: q, search: nil, sort: .newestFirst, folder: folder, limit: 400) }
    else {
        _ = try idx.items(filter: q, search: nil, sort: .newestFirst, folder: folder)
        _ = try idx.counts()
        _ = try idx.facetCounts(.source, filter: q, search: nil, folder: folder)
        _ = try idx.summary(filter: q, search: nil, folder: folder)
    }
}
// What the app's reload does since the speed pass: the items (the source counts come from them in
// memory); the summary is read only while the inspector shows it.
func gridReload(_ folder: Int64?, _ f: FilterState, _ text: String?) throws {
    _ = try idx.items(filter: f, search: text, sort: .newestFirst, folder: folder)
}
report("folder with subfolders (\(bigFiles) items): first 400 rows", try best { try scopeReload(top, first: true) }, budget: 50)
report("folder with subfolders: complete (items+counts+facets+summary)", try best { try scopeReload(top, first: false) }, budget: 150)
report("leaf folder (\(perLeaf) items): first rows", try best { try scopeReload(leaf, first: true) }, budget: 50)
report("leaf folder: complete", try best { try scopeReload(leaf, first: false) }, budget: 150)
report("whole library (nil): first 400 rows", try best { try scopeReload(nil, first: true) }, budget: 50)
report("whole library: complete", try best { try scopeReload(nil, first: false) }, budget: 150)
report("items only, whole library", try best { _ = try idx.items() })
report("items only, subtree", try best { _ = try idx.items(folder: top) })
report("items by name, subtree", try best { _ = try idx.items(sort: .name, folder: top) })
report("items oldest first, subtree", try best { _ = try idx.items(sort: .oldestFirst, folder: top) })

// Everything a view can ask for at once: the grid, the source facet and the summary. This is what one
// reload used to do; the grid no longer waits for the last two, so these lines carry no budget.
func filterReload(_ folder: Int64?, _ f: FilterState, _ text: String?) throws {
    _ = try idx.items(filter: f, search: text, sort: .newestFirst, folder: folder)
    _ = try idx.facetCounts(.source, filter: f, search: text, folder: folder)
    _ = try idx.summary(filter: f, search: text, folder: folder)
}
print("-- grid + source facet + summary together (the old reload) --")
report("filter change inside a subtree (source)", try best { try filterReload(top, mj, nil) })
report("filter change, whole library (source)", try best { try filterReload(nil, mj, nil) })
report("search inside a subtree (text)", try best { try filterReload(top, q, "lantern") })
report("search inside a subtree (selective text)", try best { try filterReload(top, q, "fog 17") })
report("search, whole library (selective text)", try best { try filterReload(nil, q, "fog 17") })
report("search, whole library (text)", try best { try filterReload(nil, q, "lantern") })
print("-- the app's reload: the grid's items (what the budgets are about) --")
report("grid reload, whole library", try best { try gridReload(nil, q, nil) }, budget: 150)
report("grid reload, source filter, whole library", try best { try gridReload(nil, mj, nil) }, budget: 100)
report("grid reload, search (word in most items)", try best { try gridReload(nil, q, "lantern") }, budget: 100)
report("grid reload, search (one letter)", try best { try gridReload(nil, q, "l") }, budget: 100)
report("grid reload, search (selective)", try best { try gridReload(nil, q, "fog 17") }, budget: 100)
report("first 400 rows, search (word in most items)", try best { _ = try idx.items(filter: q, search: "lantern", sort: .newestFirst, limit: 400) }, budget: 50)
report("first 400 rows, source filter", try best { _ = try idx.items(filter: mj, search: nil, sort: .newestFirst, limit: 400) }, budget: 50)
report("first 400 rows, by name", try best { _ = try idx.items(sort: .name, limit: 400) }, budget: 50)
report("items by name, whole library", try best { _ = try idx.items(sort: .name) })
report("summary, whole library", try best { _ = try idx.summary() })
report("summary, search (word in most items)", try best { _ = try idx.summary(filter: q, search: "lantern") })
report("counts", try best { _ = try idx.counts() })
print("-- parts --")
report("  parts: items (source filter, subtree)", try best { _ = try idx.items(filter: mj, search: nil, sort: .newestFirst, folder: top) })
report("  parts: facetCounts(source) (subtree)", try best { _ = try idx.facetCounts(.source, filter: mj, search: nil, folder: top) })
report("  parts: summary (source filter, subtree)", try best { _ = try idx.summary(filter: mj, search: nil, folder: top) })
report("  parts: items (search, subtree)", try best { _ = try idx.items(filter: q, search: "lantern", sort: .newestFirst, folder: top) })
report("  parts: summary (search, subtree)", try best { _ = try idx.summary(filter: q, search: "lantern", folder: top) })
report("facet popover (source) in subtree", try best { _ = try idx.facetCounts(.source, filter: mj, search: nil, folder: top) })
// The histogram is kept until the index changes, so the first call is the one that costs.
report("month histogram in subtree (first call)", try ms { _ = try idx.monthHistogram(filter: q, search: nil, folder: top) })
report("month histogram, whole library (first call)", try ms { _ = try idx.monthHistogram(filter: q, search: nil) })
report("month histogram, whole library (again)", try best { _ = try idx.monthHistogram(filter: q, search: nil) })
_ = folderAll
print("rss at end: \(Int(rssMB())) MB")

if CommandLine.arguments.contains("--extra") { try runContentionBench(index: idx, count: count, directory: dir, prompts: (0..<64).map(demoPrompt), xmp: xmpPacket) }
