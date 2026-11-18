import AppKit
import SwiftUI
import Observation
import BlazebunnyCore

/// The large image in the inspector (and the groundwork for the full-screen viewer).
///
/// It shows the grid's thumbnail at once, then a sharper decode of the original when the panel is
/// bigger than the thumbnail and the disk is connected. While an arrow key is held nothing is decoded
/// (each selection is replaced before its short wait ends), so key repeat only ever shows cached
/// images. When the selection rests, the neighbours in the direction of travel are decoded quietly,
/// one after the other, so the next step is already sharp.
@MainActor @Observable
final class PreviewModel {
    /// What the image is, so it can be decoded later.
    struct Request: Sendable {
        var id: Int64
        var url: URL
        var width: Int?
        var height: Int?
    }

    private(set) var image: CGImage?
    private(set) var imageID: Int64?
    /// Width over height of the selected image, from the grid's item (known before any decode).
    private(set) var aspect: CGFloat = 1
    /// True when `image` is a decode of the original at the panel's size, not the grid thumbnail.
    private(set) var isSharp = false

    /// The space the image is fitted into, in points, and the screen's scale. Set by the view.
    @ObservationIgnored var box = CGSize(width: 320, height: 300)
    @ObservationIgnored var scale: CGFloat = 2

    /// About 30 previews at 1280 px. Not an `NSCache`: that one may drop an image the moment after it
    /// was stored (seen while measuring), and a prefetched neighbour that is gone is a wasted read.
    @ObservationIgnored private var cache = ImageLRU(limit: 192 << 20)
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Bumped when the library changes: a decode that ends late is dropped.
    @ObservationIgnored private var generation = 0

    /// How long a selection must rest before its original is decoded, and before its neighbours are.
    private static let settle = Duration.milliseconds(60)
    private static let prefetchSettle = Duration.milliseconds(100)

    func reset() {
        generation += 1
        currentTask?.cancel()
        prefetchTask?.cancel()
        cache.removeAll()
        image = nil
        imageID = nil
        isSharp = false
    }

    func clear() {
        currentTask?.cancel()
        prefetchTask?.cancel()
        image = nil
        imageID = nil
        isSharp = false
    }

    /// The size originals are decoded at for this panel (a step of 256 px, so a small resize of the
    /// panel does not ask for new decodes).
    private func decodePixels(_ r: Request) -> Int {
        PreviewDecoder.pixelSize(fitting: box, scale: scale, imageWidth: r.width, imageHeight: r.height)
    }

    /// The decode of the original kept for `r`, if any. One made for a smaller panel is still better
    /// than the thumbnail, so it is shown, but `isEnough` decides whether to decode again.
    private func sharp(_ r: Request) -> CGImage? {
        cache[r.id]
    }

    /// Whether an image of `pixels` on its long side looks sharp in this panel (within a tenth).
    private func isEnough(_ pixels: Int, for r: Request) -> Bool {
        Double(pixels) >= 0.9 * PreviewDecoder.neededPixels(fitting: box, scale: scale, imageWidth: r.width, imageHeight: r.height)
    }

    private func isEnough(_ image: CGImage, for r: Request) -> Bool {
        isEnough(max(image.width, image.height), for: r)
    }

    /// Whether the grid's thumbnail already has the pixels this panel can show, so the original need
    /// not be read at all (a small panel, a non-Retina screen, a small image). Known from the
    /// image's size alone, before any thumbnail is loaded.
    private func thumbnailIsEnough(for r: Request) -> Bool {
        guard let w = r.width, let h = r.height, w > 0, h > 0 else { return false }
        return isEnough(min(Blazebunny.thumbnailMaxPixel, max(w, h)), for: r)
    }

    /// Shows `request` now with the best image at hand and upgrades it when the selection rests.
    /// `thumbnail` is the grid's cached thumbnail, if any; `loadThumbnail` fetches it when it is not
    /// cached. `decodeOriginal` is false for videos and when the disk is not connected.
    func show(_ request: Request, thumbnail: CGImage?, decodeOriginal: Bool, neighbours: [Request],
              loadThumbnail: ((@escaping (CGImage?) -> Void) -> Void)? = nil) {
        currentTask?.cancel()
        prefetchTask?.cancel()
        let id = request.id
        let asked = Perf.now()
        var ratio: CGFloat = 1
        if let w = request.width, let h = request.height, w > 0, h > 0 { ratio = CGFloat(w) / CGFloat(h) }
        if ratio != aspect { aspect = ratio }
        if let sharpImage = sharp(request) {
            set(sharpImage, id: id, sharp: true, animated: false)
            if isEnough(sharpImage, for: request) {
                Perf.log("preview.sharp.ready", 0)
                schedulePrefetch(neighbours, enabled: decodeOriginal)
                return
            }
        } else if let thumbnail {
            set(thumbnail, id: id, sharp: false, animated: false)
        } else {
            set(nil, id: id, sharp: false, animated: false)
            loadThumbnail? { [weak self] image in
                guard let self, self.imageID == id, !self.isSharp, let image else { return }
                self.set(image, id: id, sharp: false, animated: false)
            }
        }
        guard decodeOriginal else { return }
        // The thumbnail already has the pixels this panel can show: reading the original would only cost disk time.
        if thumbnailIsEnough(for: request) {
            schedulePrefetch(neighbours, enabled: true)
            return
        }
        let pixels = decodePixels(request)
        let generation = generation
        currentTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)  // skipped while arrowing quickly through the grid
            if Task.isCancelled { return }
            let started = Perf.now()
            let decoded = await Self.decode(request.url, pixels)
            guard let self, generation == self.generation, let decoded else { return }
            self.store(decoded, id: id)
            Perf.log("preview.decode", Perf.ms(since: started))
            if !Task.isCancelled, self.imageID == id {
                self.set(decoded, id: id, sharp: true, animated: true)
                Perf.log("preview.sharp.after", Perf.ms(since: asked))
                self.schedulePrefetch(neighbours, enabled: true)
            }
        }
    }

    private func schedulePrefetch(_ neighbours: [Request], enabled: Bool) {
        prefetchTask?.cancel()
        guard enabled, !neighbours.isEmpty else { return }
        let generation = generation
        // The waiting is done at the caller's priority (a low-priority timer may fire late); only the
        // decoding itself is low priority, so it never competes with what is on screen.
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prefetchSettle)
            // One at a time, in order: gentle on a spinning disk, and the nearest image comes first.
            for r in neighbours {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                if self.thumbnailIsEnough(for: r) { continue }
                if let have = self.sharp(r), self.isEnough(have, for: r) { continue }
                let pixels = self.decodePixels(r)
                let started = Perf.now()
                if let decoded = await Self.decode(r.url, pixels, priority: .utility),
                   generation == self.generation {
                    self.store(decoded, id: r.id)
                    Perf.log("preview.prefetched", Perf.ms(since: started))
                }
            }
        }
    }

    private func store(_ image: CGImage, id: Int64) {
        cache[id] = image
    }

    private func set(_ new: CGImage?, id: Int64, sharp: Bool, animated: Bool) {
        // A short cross-fade when the same image gets sharper; a different image appears at once.
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { apply(new, id, sharp) }
        } else {
            apply(new, id, sharp)
        }
    }

    private func apply(_ new: CGImage?, _ id: Int64, _ sharp: Bool) {
        image = new
        imageID = id
        isSharp = sharp
    }

    private nonisolated static func decode(_ url: URL, _ pixels: Int, priority: TaskPriority = .userInitiated) async -> CGImage? {
        await Task.detached(priority: priority) { PreviewDecoder.decode(url: url, maxPixel: pixels) }.value
    }
}

/// A small cache of decoded images that forgets the least recently used ones once their bytes pass
/// `limit`, and nothing before that.
struct ImageLRU {
    let limit: Int
    private var images: [Int64: CGImage] = [:]
    /// Ids from the least to the most recently used.
    private var order: [Int64] = []
    private(set) var bytes = 0

    init(limit: Int) { self.limit = limit }

    var count: Int { images.count }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    subscript(id: Int64) -> CGImage? {
        mutating get {
            guard let image = images[id] else { return nil }
            touch(id)
            return image
        }
        set {
            if let old = images.removeValue(forKey: id) {
                bytes -= Self.cost(old)
                order.removeAll { $0 == id }
            }
            guard let newValue else { return }
            images[id] = newValue
            order.append(id)
            bytes += Self.cost(newValue)
            // The newest image always stays, even when it alone is over the limit.
            while bytes > limit, order.count > 1 {
                let oldest = order.removeFirst()
                if let dropped = images.removeValue(forKey: oldest) { bytes -= Self.cost(dropped) }
            }
        }
    }

    private mutating func touch(_ id: Int64) {
        guard order.last != id, let i = order.firstIndex(of: id) else { return }
        order.remove(at: i)
        order.append(id)
    }

    mutating func removeAll() {
        images.removeAll()
        order.removeAll()
        bytes = 0
    }
}
