import Foundation

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case enumerating, metadata, thumbnails, done }
    public var phase: Phase
    public var total = 0
    public var metadataDone = 0
    public var thumbnailsDone = 0
    public var bytesRead: Int64 = 0
    public var elapsed: TimeInterval = 0
    public init(phase: Phase) { self.phase = phase }
}

/// Indexes a folder in three resumable phases: enumerate, metadata,
/// thumbnails. Source files are only ever opened for reading.
public final class FolderScanner: @unchecked Sendable {
    public let root: URL
    let index: LibraryIndex
    let thumbnails: ThumbnailStore?
    let ioConcurrency: Int

    private let lock = NSLock()
    private var priority: [Int64] = []
    private var cancelled = false
    private var _metadataReads = 0
    private var _bytesRead: Int64 = 0

    /// Number of files whose metadata was read (for tests and benchmarks).
    public var metadataReads: Int { lock.withLock { _metadataReads } }

    public init(root: URL, index: LibraryIndex, thumbnails: ThumbnailStore?, ioConcurrency: Int = 2) {
        self.root = root.standardizedFileURL
        self.index = index
        self.thumbnails = thumbnails
        self.ioConcurrency = max(1, ioConcurrency)
    }

    public func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } || Task.isCancelled }

    /// Thumbnails for these items are made before any other.
    public func prioritize(ids: [Int64]) {
        lock.withLock { priority = ids }
    }

    public func run(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws {
        let start = Date()
        var p = ScanProgress(phase: .enumerating)
        func report() {
            p.elapsed = Date().timeIntervalSince(start)
            p.bytesRead = lock.withLock { _bytesRead }
            progress(p)
        }

        // Phase 1: enumerate.
        report()
        let known = try index.knownFiles()
        var seen = Set<String>()
        var batch: [FileRecord] = []
        for record in enumerate() {
            if isCancelled { return }
            seen.insert(record.relPath)
            if let k = known[record.relPath], k.size == record.size, k.mtime == record.mtime { continue }
            batch.append(record)
            if batch.count >= 500 {
                try index.upsertFiles(batch)
                batch.removeAll(keepingCapacity: true)
                p.total = seen.count
                report()
            }
        }
        try index.upsertFiles(batch)
        let gone = known.keys.filter { !seen.contains($0) }
        if !gone.isEmpty { try index.deleteFiles(relPaths: gone) }

        var counts = try index.counts()
        p.total = counts.total
        p.metadataDone = counts.metadataDone + counts.metadataFailed
        p.thumbnailsDone = counts.thumbnailsDone + counts.thumbnailsFailed
        p.phase = .metadata
        report()

        // Phase 2: metadata, in enumeration order (close to on-disk order).
        while !isCancelled {
            let pending = try index.pendingMetadata(limit: 64)
            if pending.isEmpty { break }
            let results = await mapConcurrently(pending) { item in
                (item.id, self.readMetadata(item))
            }
            try index.saveMetadata(results)
            p.metadataDone += results.count
            report()
        }
        if isCancelled { return }

        // Phase 3: thumbnails, visible items first.
        if let thumbnails {
            p.phase = .thumbnails
            report()
            while !isCancelled {
                let wanted = lock.withLock { () -> [Int64] in
                    let w = priority
                    priority = []
                    return w
                }
                var pending = try index.pendingThumbnails(ids: wanted)
                if pending.isEmpty { pending = try index.pendingThumbnails(limit: ioConcurrency * 4) }
                if pending.isEmpty { break }
                let results = await mapConcurrently(pending) { item -> (Int64, ThumbnailLocation?) in
                    let url = self.root.appendingPathComponent(item.relPath)
                    do {
                        let data = try await ThumbnailMaker.make(from: url, kind: item.kind)
                        self.addBytes(url)
                        return (item.id, try thumbnails.append(data))
                    } catch {
                        return (item.id, nil)
                    }
                }
                for (id, loc) in results { try index.saveThumbnail(id: id, loc) }
                p.thumbnailsDone += results.count
                report()
            }
        }
        counts = try index.counts()
        p.metadataDone = counts.metadataDone + counts.metadataFailed
        p.thumbnailsDone = counts.thumbnailsDone + counts.thumbnailsFailed
        p.phase = isCancelled ? p.phase : .done
        report()
    }

    func readMetadata(_ item: PendingItem) -> ItemMetadata? {
        lock.withLock { _metadataReads += 1 }
        let url = root.appendingPathComponent(item.relPath)
        return try? MetadataReader.read(url: url, kind: item.kind, fileDate: Date(timeIntervalSince1970: item.mtime))
    }

    private func addBytes(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        lock.withLock { _bytesRead += Int64(size) }
    }

    /// Lists supported files in directory order, skipping hidden files and packages.
    func enumerate() -> [FileRecord] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootPath = root.resolvingSymlinksInPath().path
        var out: [FileRecord] = []
        for case let url as URL in e {
            let kind = ItemKind(pathExtension: url.pathExtension)
            guard kind.isSupported,
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            var path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(FileRecord(relPath: path, size: Int64(v.fileSize ?? 0),
                                  mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, kind: kind))
        }
        return out
    }

    /// Runs `body` over `items` with at most `ioConcurrency` in flight, keeping order.
    func mapConcurrently<T: Sendable, R: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(ioConcurrency, items.count) {
                let i = next, item = items[i]
                group.addTask { (i, await body(item)) }
                next += 1
            }
            for await (i, r) in group {
                results[i] = r
                if next < items.count {
                    let j = next, item = items[j]
                    group.addTask { (j, await body(item)) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}
