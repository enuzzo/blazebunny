import Foundation
import BlazebunnyCore

// What the UI feels while the index is busy: point lookups (the inspector) and thumbnail reads (the
// grid) measured while a scan writes metadata or a reload reads the whole library.

private final class Samples: @unchecked Sendable {
    private var v: [Double] = []
    private let lock = NSLock()
    func add(_ x: Double) { lock.withLock { v.append(x) } }
    func summary() -> String {
        let s = lock.withLock { v.sorted() }
        guard !s.isEmpty else { return "no samples" }
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
        return String(format: "n=%d  p50 %.3f  p99 %.3f  max %.3f ms", s.count, q(0.5), q(0.99), s.last!)
    }
}

private final class Flag: @unchecked Sendable {
    private var on = true
    private let lock = NSLock()
    var isOn: Bool { lock.withLock { on } }
    func stop() { lock.withLock { on = false } }
}

private enum Load: String, CaseIterable {
    case idle = "idle", writer = "during scan writes", reader = "during a full reload"
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Runs `body` on `threads` threads at once while a background load keeps the index busy.
private func underLoad(_ load: Load, index idx: LibraryIndex, count: Int, prompts: [String], xmp: String, threads: Int,
                       _ body: @escaping @Sendable (Int) -> Void) -> Double {
    let flag = Flag()
    let bg = Thread {
        var n = 0
        while flag.isOn {
            switch load {
            case .idle: Thread.sleep(forTimeInterval: 0.01)
            case .writer:
                // What a scan does: a batch of 64 metadata rows in one transaction.
                let slice = (0..<64).map { k -> (id: Int64, metadata: ItemMetadata?) in
                    let id = Int64(1 + (n * 64 + k) % count)
                    return (id, ItemMetadata(width: 1024, height: 1024,
                                             createdAt: Date(timeIntervalSince1970: Double(1_600_000_000 + Int(id) * 60)),
                                             promptRaw: prompts[(n + k) % prompts.count], xmp: xmp, source: .midjourney))
                }
                try? idx.saveMetadata(slice)
            case .reader:
                _ = try? idx.items()
            }
            n += 1
        }
    }
    bg.start()
    Thread.sleep(forTimeInterval: 0.05)
    let group = DispatchGroup()
    let t0 = now()
    for t in 0..<threads {
        group.enter()
        Thread { body(t); group.leave() }.start()
    }
    group.wait()
    let total = Double(now() - t0) / 1e6
    flag.stop()
    while !bg.isFinished { Thread.sleep(forTimeInterval: 0.005) }
    return total
}

/// `prompts` and `xmp` give the rows the writer rewrites the same shape as the generated ones.
func runContentionBench(index idx: LibraryIndex, count: Int, directory dir: URL, prompts: [String], xmp: String) throws {
    print("\n-- point lookup (detail) latency on one thread, as the inspector does --")
    for load in Load.allCases {
        let s = Samples()
        _ = underLoad(load, index: idx, count: count, prompts: prompts, xmp: xmp, threads: 1) { _ in
            for i in 0..<400 {
                let t = now()
                _ = try? idx.detail(id: Int64(1 + (i * 97) % count))
                s.add(Double(now() - t) / 1e6)
                usleep(500)
            }
        }
        print(String(format: "detail, %-22@ %@", load.rawValue as NSString, s.summary() as NSString))
    }

    print("\n-- thumbnail read path: 8 threads x 1000 reads of 40 KB --")
    let store = try ThumbnailStore(directory: dir.appendingPathComponent("thumbs"))
    let blob = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let thumbCount = min(8_000, count)
    var table: [Int64: ThumbnailLocation] = [:]
    for id in 1...thumbCount {
        let loc = try store.append(blob)
        table[Int64(id)] = loc
        try idx.saveThumbnail(id: Int64(id), loc)
    }
    let locations = table
    for load in Load.allCases {
        let s = Samples()
        let total = underLoad(load, index: idx, count: count, prompts: prompts, xmp: xmp, threads: 8) { t in
            for i in 0..<1000 {
                let id = Int64(1 + (t * 1000 + i * 7) % thumbCount)
                let t0 = now()
                // The grid item carries its location; here it is looked up to keep the bench self-contained.
                if let loc = locations[id] { _ = try? store.data(at: loc) }
                s.add(Double(now() - t0) / 1e6)
            }
        }
        print(String(format: "thumbnail read, %-22@ total %.0f ms  %@", load.rawValue as NSString, total, s.summary() as NSString))
    }
}
