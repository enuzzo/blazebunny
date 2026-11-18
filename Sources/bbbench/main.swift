import Foundation
import BlazebunnyCore

// bbbench <folder> [--io N] [--no-thumbs] [--limit N] [--keep]
// Scans a folder into a throwaway library and prints timings.
// The source folder is only read. Without --io the number of files read at once
// follows the kind of disk the folder is on, as in the app.

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let ioOption = Int(option("--io") ?? "")
let limit = Int(option("--limit") ?? "") ?? Int.max
let noThumbs = flag("--no-thumbs")
let keep = flag("--keep")
guard let path = args.first else {
    FileHandle.standardError.write("usage: bbbench <folder> [--io N] [--no-thumbs] [--limit N] [--keep]\n".data(using: .utf8)!)
    exit(2)
}

let folder = URL(fileURLWithPath: path)
let volume = VolumeKind(of: folder)
let io = ioOption ?? volume.recommendedIOConcurrency
let base = FileManager.default.temporaryDirectory.appendingPathComponent("bbbench-" + UUID().uuidString)
let library = try Library(root: folder, base: base)
let scanner = FolderScanner(root: folder, index: library.index, thumbnails: noThumbs ? nil : library.thumbnails, ioConcurrency: io)

final class Timings: @unchecked Sendable {
    var phaseStart: [ScanProgress.Phase: TimeInterval] = [:]
    var last = ScanProgress(phase: .enumerating)
    var lastPrint: TimeInterval = -10
    var metaAtStart = 0
}
let t = Timings()

print("bbbench: \(folder.path)  disk=\(volume.rawValue) io=\(io) thumbs=\(!noThumbs) limit=\(limit == .max ? "none" : String(limit))")
try await scanner.run { p in
    if t.phaseStart[p.phase] == nil {
        t.phaseStart[p.phase] = p.elapsed
        print(String(format: "[%7.1fs] phase %@  (files: %d)", p.elapsed, p.phase.rawValue, p.total))
    }
    if p.phase == .enumerating { t.metaAtStart = p.metadataDone }
    // --limit caps the thumbnails made (or the metadata read with --no-thumbs).
    let done = noThumbs ? (p.phase == .metadata ? p.metadataDone - t.metaAtStart : 0) : (p.phase == .thumbnails ? p.thumbnailsDone : 0)
    if done >= limit { scanner.cancel() }
    if p.elapsed - t.lastPrint >= 5 {
        t.lastPrint = p.elapsed
        print(String(format: "[%7.1fs] %@ meta %d/%d  thumbs %d  read %.1f MB", p.elapsed, p.phase.rawValue,
                     p.metadataDone, p.total, p.thumbnailsDone, Double(p.bytesRead) / 1e6))
    }
    t.last = p
}

let p = t.last
let c = try library.index.counts()
func span(_ a: ScanProgress.Phase, _ b: ScanProgress.Phase?) -> TimeInterval {
    let s = t.phaseStart[a] ?? 0
    let e = b.flatMap { t.phaseStart[$0] } ?? p.elapsed
    return e - s
}
let enumTime = span(.enumerating, .metadata)
let metaTime = span(.metadata, noThumbs ? nil : .thumbnails)
print("")
print(String(format: "files              %d", c.total))
print(String(format: "enumerate          %.1f s", enumTime))
print(String(format: "metadata           %.1f s  (%d read, %.1f files/s)", metaTime, scanner.metadataReads,
             Double(scanner.metadataReads) / max(metaTime, 0.001)))
if !noThumbs {
    let thumbTime = span(.thumbnails, nil)
    print(String(format: "thumbnails         %.1f s  (%d done, %.1f/s, %.1f MB/s)", thumbTime, c.thumbnailsDone,
                 Double(c.thumbnailsDone) / max(thumbTime, 0.001), Double(p.bytesRead) / 1e6 / max(thumbTime, 0.001)))
}
print(String(format: "with prompt        %d", c.withPrompt))
print(String(format: "metadata failed    %d", c.metadataFailed))
print(String(format: "thumbnails failed  %d", c.thumbnailsFailed))
let size = (try? FileManager.default.subpathsOfDirectory(atPath: library.directory.path))?.reduce(Int64(0)) { acc, name in
    acc + (((try? FileManager.default.attributesOfItem(atPath: library.directory.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value ?? 0)
} ?? 0
print(String(format: "library size       %.1f MB", Double(size) / 1e6))
if keep {
    print("library kept at    \(library.directory.path)")
} else {
    try? FileManager.default.removeItem(at: base)
}
