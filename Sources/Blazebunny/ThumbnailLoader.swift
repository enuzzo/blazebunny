import AppKit
import BlazebunnyCore

/// Loads thumbnails for the grid: read from the packs and decoded off the main thread, kept in a
/// memory cache bounded by size. A cell that scrolls away cancels its request, so the cells on
/// screen are never queued behind ones that left.
@MainActor
final class ThumbnailLoader {
    /// Identifies one request, so a cell can take it back.
    struct Token: Equatable {
        fileprivate let id: Int64
        fileprivate let serial: Int
    }

    var library: Library? { didSet { if library !== oldValue { reset() } } }
    weak var scanner: FolderScanner?
    /// Called with the ids whose thumbnail has just been made by the running scan.
    var onAvailable: ((Set<Int64>) -> Void)?

    private let cache = NSCache<NSNumber, CGImage>()
    private struct Flight {
        var task: Task<Void, Never>
        var waiters: [(serial: Int, completion: (CGImage?) -> Void)]
    }
    private var inFlight: [Int64: Flight] = [:]
    /// Thumbnails made since the grid's items were last read: the items do not know them yet.
    private var made: [Int64: ThumbnailLocation] = [:]
    private var serial = 0
    /// Bumped when the library changes, so a decode that finishes late is dropped.
    private var generation = 0

    init() {
        // Decoded thumbnails are up to 1 MB each (512 px, 4 bytes a pixel). The cache holds a few
        // screens' worth, sized by bytes and not by count: a sixty-fourth of the Mac's memory, between
        // 192 and 512 MB. (It used to hold 3 000 images whatever their size: up to 3 GB.)
        let budget = Int(ProcessInfo.processInfo.physicalMemory / 64)
        cache.totalCostLimit = min(512 << 20, max(192 << 20, budget))
    }

    private func reset() {
        generation += 1
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        made.removeAll()
        cache.removeAllObjects()
    }

    func cached(_ id: Int64) -> CGImage? { cache.object(forKey: NSNumber(value: id)) }

    /// Where the item's thumbnail is, if it has been made: from the item itself, or from the scan
    /// that made it after the item was read.
    func location(for item: BrowseItem) -> ThumbnailLocation? { item.thumbnail ?? made[item.id] }

    /// Loads one thumbnail. `completion` runs on the main thread, unless the request is cancelled first.
    @discardableResult
    func load(_ id: Int64, at location: ThumbnailLocation, completion: @escaping (CGImage?) -> Void) -> Token? {
        if let image = cached(id) { completion(image); return nil }
        serial += 1
        let token = Token(id: id, serial: serial)
        if inFlight[id] != nil {
            inFlight[id]!.waiters.append((serial, completion))
            return token
        }
        guard let store = library?.thumbnails else { completion(nil); return nil }
        let generation = generation
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let image = Task.isCancelled ? nil : Self.decode(store: store, location: location)
            await self?.finish(id, image, generation: generation)
        }
        inFlight[id] = Flight(task: task, waiters: [(serial, completion)])
        return token
    }

    /// Takes a request back (its cell went off screen). The read is dropped when nobody else waits for it.
    func cancel(_ token: Token?) {
        guard let token, var flight = inFlight[token.id] else { return }
        flight.waiters.removeAll { $0.serial == token.serial }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight[token.id] = nil
        } else {
            inFlight[token.id] = flight
        }
    }

    private func finish(_ id: Int64, _ image: CGImage?, generation: Int) {
        guard generation == self.generation, let flight = inFlight.removeValue(forKey: id) else { return }
        if let image { cache.setObject(image, forKey: NSNumber(value: id), cost: image.bytesPerRow * image.height) }
        for waiter in flight.waiters { waiter.completion(image) }
    }

    private nonisolated static func decode(store: ThumbnailStore, location: ThumbnailLocation) -> CGImage? {
        guard let data = try? store.data(at: location), !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decode here, not later on the main thread when the layer first draws it.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
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
}
