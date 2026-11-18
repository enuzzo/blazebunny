import AppKit
import BlazebunnyCore

/// Loads thumbnails for the grid: read from the packs and decoded off the main thread, kept in a
/// memory cache bounded by size. A cell that scrolls away cancels its request, so the cells on
/// screen are never queued behind ones that left. It also holds each thumbnail's colours
/// (`ThumbnailPlaceholder`), which a cell draws while its thumbnail is on the way.
@MainActor
final class ThumbnailLoader {
    /// How much of a stored thumbnail a cell needs: small cells get it decoded at half size (a
    /// quarter of the memory and of the work), larger ones whole.
    enum Detail: Int, Comparable, Sendable {
        case small, full

        static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }

        /// The least detail that is not enlarged when shown `pixels` wide on its long side.
        static func needed(forPixels pixels: CGFloat) -> Detail {
            pixels <= CGFloat(ThumbnailDecoder.smallPixel) ? .small : .full
        }

        var maxPixel: Int? { self == .small ? ThumbnailDecoder.smallPixel : nil }
    }

    /// Identifies one request, so a cell can take it back.
    struct Token: Equatable {
        fileprivate let key: Key
        fileprivate let serial: Int
    }

    fileprivate struct Key: Hashable {
        let id: Int64
        let detail: Detail
    }

    private final class Entry {
        let image: CGImage
        let detail: Detail
        init(_ image: CGImage, _ detail: Detail) { self.image = image; self.detail = detail }
    }

    var library: Library? { didSet { if library !== oldValue { reset(); loadPlaceholders() } } }
    weak var scanner: FolderScanner?
    /// Called with the ids whose thumbnail has just been made by the running scan.
    var onAvailable: ((Set<Int64>) -> Void)?

    /// The colour space of the window the grid is in. Thumbnails are decoded into it, so showing one
    /// costs the main thread nothing (see `ThumbnailDecoder.decodeForLayer`). When the window moves to
    /// a display with another profile the decoded ones are dropped; cells on screen keep theirs.
    var displayColorSpace: CGColorSpace? {
        didSet { if displayColorSpace != oldValue { cache.removeAllObjects() } }
    }

    private let cache = NSCache<NSNumber, Entry>()
    private struct Flight {
        var task: Task<Void, Never>
        var waiters: [(serial: Int, completion: (CGImage?) -> Void)]
    }
    private var inFlight: [Key: Flight] = [:]
    /// Thumbnails made since the grid's items were last read: the items do not know them yet.
    private var made: [Int64: ThumbnailLocation] = [:]
    /// Every thumbnail's colours, read once when the library opens and kept up by the scan.
    private var placeholders: [Int64: ThumbnailPlaceholder] = [:]
    private var placeholderTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var serial = 0
    /// Bumped when the library changes, so a decode that finishes late is dropped.
    private var generation = 0

    init() {
        // A decoded thumbnail is up to 1 MB whole (512 px, 4 bytes a pixel) and 256 KB at half size.
        // The cache holds a few screens' worth, sized by bytes and not by count: a sixty-fourth of
        // the Mac's memory, between 192 and 512 MB. (It used to hold 3 000 images whatever their size: up to 3 GB.)
        let budget = Int(ProcessInfo.processInfo.physicalMemory / 64)
        cache.totalCostLimit = min(512 << 20, max(192 << 20, budget))
    }

    private func reset() {
        generation += 1
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        made.removeAll()
        cache.removeAllObjects()
        placeholderTask?.cancel()
        backfillTask?.cancel()
        backfillTask = nil
        placeholders.removeAll()
    }

    /// The decoded thumbnail in memory, if it has at least `detail`.
    func cached(_ id: Int64, detail: Detail = .full) -> CGImage? {
        guard let entry = cache.object(forKey: NSNumber(value: id)), entry.detail >= detail else { return nil }
        return entry.image
    }

    /// Whatever is in memory for the item, however small.
    func best(_ id: Int64) -> (image: CGImage, detail: Detail)? {
        cache.object(forKey: NSNumber(value: id)).map { ($0.image, $0.detail) }
    }

    /// Where the item's thumbnail is, if it has been made: from the item itself, or from the scan
    /// that made it after the item was read.
    func location(for item: BrowseItem) -> ThumbnailLocation? { item.thumbnail ?? made[item.id] }

    /// Loads one thumbnail. `completion` runs on the main thread, unless the request is cancelled first.
    @discardableResult
    func load(_ id: Int64, at location: ThumbnailLocation, detail: Detail = .full, completion: @escaping (CGImage?) -> Void) -> Token? {
        if let image = cached(id, detail: detail) { completion(image); return nil }
        serial += 1
        let key = Key(id: id, detail: detail)
        let token = Token(key: key, serial: serial)
        if inFlight[key] != nil {
            inFlight[key]!.waiters.append((serial, completion))
            return token
        }
        guard let library else { completion(nil); return nil }
        let generation = generation
        let space = displayColorSpace
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            if let delay = Perf.thumbnailDelay { try? await Task.sleep(for: delay) }
            let image = Task.isCancelled ? nil : Self.decode(library: library, id: id, location: location, detail: detail, colorSpace: space)
            await self?.finish(key, image, generation: generation)
        }
        inFlight[key] = Flight(task: task, waiters: [(serial, completion)])
        return token
    }

    /// Takes a request back (its cell went off screen). The read is dropped when nobody else waits for it.
    func cancel(_ token: Token?) {
        guard let token, var flight = inFlight[token.key] else { return }
        flight.waiters.removeAll { $0.serial == token.serial }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight[token.key] = nil
        } else {
            inFlight[token.key] = flight
        }
    }

    private func finish(_ key: Key, _ image: CGImage?, generation: Int) {
        guard generation == self.generation, let flight = inFlight.removeValue(forKey: key) else { return }
        // A whole image already in memory is never replaced by a half-size one.
        if let image, (best(key.id)?.detail ?? .small) <= key.detail {
            cache.setObject(Entry(image, key.detail), forKey: NSNumber(value: key.id), cost: image.bytesPerRow * image.height)
        }
        for waiter in flight.waiters { waiter.completion(image) }
    }

    private nonisolated static func decode(library: Library, id: Int64, location: ThumbnailLocation, detail: Detail,
                                           colorSpace: CGColorSpace?) -> CGImage? {
        func read(_ location: ThumbnailLocation) -> CGImage? {
            guard let data = try? library.thumbnails.data(at: location), !Task.isCancelled else { return nil }
            // Decoded here, not later on the main thread when the layer first draws it.
            return ThumbnailDecoder.decodeForLayer(data, maxPixel: detail.maxPixel, colorSpace: colorSpace)
        }
        if let image = read(location) { return image }
        // The bytes were not there or not an image: the thumbnail may have been made again since
        // the grid's items were read. Ask the index where it is now.
        guard !Task.isCancelled, let current = try? library.index.thumbnailLocation(id: id), current != location else { return nil }
        return read(current)
    }

    /// The running scan made these thumbnails: remember where they are and tell the grid.
    func noteMade(_ batch: [(id: Int64, location: ThumbnailLocation)]) {
        for (id, location) in batch { made[id] = location }
        onAvailable?(Set(batch.map(\.id)))
    }

    /// The grid's items were read again and carry their own locations: forget the ones kept meanwhile.
    func itemsReloaded() { made.removeAll(keepingCapacity: true) }

    /// Asks the scanner to make these thumbnails first.
    func prioritize(_ ids: [Int64]) {
        scanner?.prioritize(ids: ids.filter { made[$0] == nil })
    }

    // MARK: - Placeholders

    /// The item's colours, to draw while its thumbnail loads; nil when they are not known (yet).
    func placeholder(for id: Int64) -> ThumbnailPlaceholder? { placeholders[id] }

    var placeholderCount: Int { placeholders.count }

    /// The scan (or the backfill) worked out these colours.
    func notePlaceholders(_ batch: [(id: Int64, placeholder: ThumbnailPlaceholder)]) {
        for (id, placeholder) in batch { placeholders[id] = placeholder }
    }

    /// Reads the library's placeholders, off the main thread (one pass over a small table).
    private func loadPlaceholders() {
        guard let library else { return }
        let generation = generation
        placeholderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let started = Perf.now()
            guard let table = try? library.index.placeholders(), !Task.isCancelled else { return }
            await self?.adopt(table, generation: generation, readMs: Perf.ms(since: started))
        }
    }

    private func adopt(_ table: [Int64: ThumbnailPlaceholder], generation: Int, readMs: Double) {
        guard generation == self.generation else { return }
        // Colours the scan reported meanwhile are newer than the table.
        if placeholders.isEmpty { placeholders = table } else { placeholders.merge(table) { current, _ in current } }
        Perf.log("placeholders.read", readMs)
        Perf.log("placeholders.count \(placeholders.count)")
    }

    /// Works out the colours of thumbnails made before placeholders existed, from the packs, in the
    /// background. Call it once the grid is up; it does nothing when none is missing.
    func backfillPlaceholders() {
        guard let library, backfillTask == nil else { return }
        let generation = generation
        backfillTask = Task.detached(priority: .utility) { [weak self] in
            let started = Perf.now()
            let saved = try? PlaceholderBackfill.run(index: library.index, thumbnails: library.thumbnails, onBatch: { batch in
                Task { @MainActor in
                    guard let self, generation == self.generation else { return }
                    self.notePlaceholders(batch)
                }
            })
            if let saved, saved > 0 {
                Perf.log("placeholders.backfill.count \(saved)")
                Perf.log("placeholders.backfill", Perf.ms(since: started))
            }
        }
    }
}
