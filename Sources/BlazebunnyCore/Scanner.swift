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

    /// Whether the folder is still there as a directory. Checked before pruning and
    /// before saving each batch, so a disk that vanishes mid-scan cannot wipe the index
    /// or mark unread files as failed. Replaceable in tests.
    public var isRootReachable: @Sendable () -> Bool

    public init(root: URL, index: LibraryIndex, thumbnails: ThumbnailStore?, ioConcurrency: Int = 2) {
        let root = root.standardizedFileURL
        self.root = root
        self.index = index
        self.thumbnails = thumbnails
        self.ioConcurrency = max(1, ioConcurrency)
        self.isRootReachable = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        }
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
        // The listing reports how many entries it has seen, so the status never sits on "0".
        let listing = enumerate { seenCount in
            p.total = seenCount
            report()
        }
        try index.upsertDirectories(listing.dirs)
        for record in listing.records {
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
        // Only prune rows for files that are really gone. A listing that hit errors, an
        // unreachable root, or an empty result for a library that had files all look the
        // same as "everything was deleted", and must never wipe the index.
        let listingIsTrustworthy = listing.complete && isRootReachable() && !(seen.isEmpty && !known.isEmpty)
        let gone = known.keys.filter { !seen.contains($0) }
        if listingIsTrustworthy, !gone.isEmpty { try index.deleteFiles(relPaths: gone) }
        if listingIsTrustworthy { try index.removeDirectories(keeping: Set(listing.dirs)) }

        var counts = try index.counts()
        p.total = counts.total
        p.metadataDone = counts.metadataDone + counts.metadataFailed
        p.thumbnailsDone = counts.thumbnailsDone + counts.thumbnailsFailed
        p.phase = .metadata
        report()

        // Phases 2 and 3 alternate in time slices, so thumbnails (visible items
        // first) appear while metadata is still being read. Each round reads one
        // batch of metadata, then makes thumbnails for about as long again.
        // Metadata runs in enumeration order (close to on-disk order).
        while !isCancelled {
            let roundStart = Date()
            var didWork = false

            let pendingMeta = try index.pendingMetadata(limit: 64)
            if !pendingMeta.isEmpty {
                didWork = true
                p.phase = .metadata
                let results = await mapConcurrently(pendingMeta) { item in
                    (item.id, self.readMetadata(item))
                }
                // The disk may have vanished during this batch: do not record failures for it.
                guard isRootReachable() else { return }
                try index.saveMetadata(results)
                p.metadataDone += results.count
                report()
            }
            if isCancelled { return }

            if let thumbnails {
                // About as long as the metadata batch took, so metadata (search, filters,
                // dates) is ready soon while thumbnails still appear continuously.
                let budget = pendingMeta.isEmpty ? 0 : max(0.05, Date().timeIntervalSince(roundStart))
                let sliceStart = Date()
                repeat {
                    guard let made = try await makeThumbnailBatch(thumbnails) else { return }
                    if made == 0 { break }
                    didWork = true
                    if pendingMeta.isEmpty { p.phase = .thumbnails }
                    p.thumbnailsDone += made
                    report()
                } while !isCancelled && Date().timeIntervalSince(sliceStart) < budget
            }
            if !didWork { break }
        }
        if isCancelled { return }
        counts = try index.counts()
        p.metadataDone = counts.metadataDone + counts.metadataFailed
        p.thumbnailsDone = counts.thumbnailsDone + counts.thumbnailsFailed
        p.phase = isCancelled ? p.phase : .done
        report()
    }

    /// Makes one batch of thumbnails, the prioritised (visible) items first.
    /// Returns how many were processed; 0 means nothing is left.
    /// Returns nil when the disk vanished during the batch (nothing is recorded).
    private func makeThumbnailBatch(_ thumbnails: ThumbnailStore) async throws -> Int? {
        let wanted = lock.withLock { () -> [Int64] in
            let w = priority
            priority = []
            return w
        }
        var pending = try index.pendingThumbnails(ids: wanted)
        if pending.isEmpty { pending = try index.pendingThumbnails(limit: ioConcurrency * 4) }
        if pending.isEmpty { return 0 }
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
        guard isRootReachable() else { return nil }
        for (id, loc) in results { try index.saveThumbnail(id: id, loc) }
        return results.count
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
    /// `complete` is false when any directory could not be read.
    func enumerate(onProgress: (Int) -> Void = { _ in }) -> (records: [FileRecord], dirs: [String], complete: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let hadError = Locked(false)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in hadError.set(true); return true })
        else { return ([], [], false) }
        let rootPath = root.resolvingSymlinksInPath().path
        var out: [FileRecord] = []
        var dirs: [String] = []
        func relative(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var entries = 0
        for case let url as URL in e {
            entries += 1
            if entries % 1000 == 0 { onProgress(entries) }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let p = relative(url)
                if !p.isEmpty { dirs.append(p) }
                continue
            }
            let kind = ItemKind(pathExtension: url.pathExtension)
            guard kind.isSupported,
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(FileRecord(relPath: relative(url), size: Int64(v.fileSize ?? 0),
                                  mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, kind: kind))
        }
        return (out, dirs, !hadError.value)
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
