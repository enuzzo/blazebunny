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

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bbscope-" + UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let keepDB = CommandLine.arguments.contains("--keep")
defer { if keepDB { print("kept \(dir.path)") } else { try? FileManager.default.removeItem(at: dir) } }
let idx = try LibraryIndex(url: dir.appendingPathComponent("index.sqlite"))

var files: [FileRecord] = []
for t in 0..<100 { for s in 0..<10 { for f in 0..<perLeaf {
    files.append(FileRecord(relPath: "Project \(t)/Batch \(s)/img\(f).png", size: 1000, mtime: Double(1_600_000_000 + (t * 10 + s) * 86_400 + f), kind: .png))
} } }
for s in 0..<8 { for f in 0..<(bigFiles / 8) {
    files.append(FileRecord(relPath: "Big/Part \(s)/img\(f).png", size: 1000, mtime: Double(1_500_000_000 + s * 86_400 + f), kind: .png))
} }
let ingest = try ms { try idx.upsertFiles(files) }
let pending = try idx.pendingMetadata(limit: count)
var batch: [(id: Int64, metadata: ItemMetadata?)] = []
for (i, p) in pending.enumerated() {
    let mj = i % 3 != 0
    batch.append((p.id, ItemMetadata(width: 1024, height: 1024, createdAt: Date(timeIntervalSince1970: Double(1_600_000_000 + i * 60)),
                                    promptRaw: mj ? "a lantern in the fog \(i % 50) --ar 16:9 --v 7" : nil, source: mj ? .midjourney : .camera)))
}
let meta = try ms { try idx.saveMetadata(batch) }
print("generated \(count) items: insert \(Int(ingest)) ms, metadata \(Int(meta)) ms, rss \(Int(rssMB())) MB")

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

func filterReload(_ folder: Int64?, _ f: FilterState, _ text: String?) throws {
    _ = try idx.items(filter: f, search: text, sort: .newestFirst, folder: folder)
    _ = try idx.facetCounts(.source, filter: f, search: text, folder: folder)
    _ = try idx.summary(filter: f, search: text, folder: folder)
}
report("filter change inside a subtree (source)", try best { try filterReload(top, mj, nil) }, budget: 100)
report("filter change, whole library (source)", try best { try filterReload(nil, mj, nil) }, budget: 100)
report("search inside a subtree (text)", try best { try filterReload(top, q, "lantern") }, budget: 100)
report("search inside a subtree (selective text)", try best { try filterReload(top, q, "fog 17") }, budget: 100)
report("search, whole library (selective text)", try best { try filterReload(nil, q, "fog 17") }, budget: 100)
report("search, whole library (text)", try best { try filterReload(nil, q, "lantern") }, budget: 100)
report("  parts: items (source filter, subtree)", try best { _ = try idx.items(filter: mj, search: nil, sort: .newestFirst, folder: top) })
report("  parts: facetCounts(source) (subtree)", try best { _ = try idx.facetCounts(.source, filter: mj, search: nil, folder: top) })
report("  parts: summary (source filter, subtree)", try best { _ = try idx.summary(filter: mj, search: nil, folder: top) })
report("  parts: items (search, subtree)", try best { _ = try idx.items(filter: q, search: "lantern", sort: .newestFirst, folder: top) })
report("  parts: summary (search, subtree)", try best { _ = try idx.summary(filter: q, search: "lantern", folder: top) })
report("facet popover (source) in subtree", try best { _ = try idx.facetCounts(.source, filter: mj, search: nil, folder: top) })
report("month histogram in subtree", try best { _ = try idx.monthHistogram(filter: q, search: nil, folder: top) })
report("month histogram, whole library", try best { _ = try idx.monthHistogram(filter: q, search: nil) })
_ = folderAll
print("rss at end: \(Int(rssMB())) MB")
