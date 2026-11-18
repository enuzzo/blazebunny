import Testing
import Foundation
import CoreGraphics
@testable import Blazebunny
import BlazebunnyCore

@Suite("ThumbnailLoader") @MainActor
struct ThumbnailLoaderTests {
    /// A library on an empty folder whose packs hold `count` generated thumbnails of `side` pixels.
    func makeLibrary(side: Int, count: Int) throws -> (library: Library, locations: [ThumbnailLocation], base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-loader-" + UUID().uuidString)
        let root = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try Library(root: root, base: base.appendingPathComponent("data"))
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let jpeg = try ThumbnailMaker.encodeJPEG(context.makeImage()!)
        let locations = try (0..<count).map { _ in try library.thumbnails.append(jpeg) }
        return (library, locations, base)
    }

    func load(_ loader: ThumbnailLoader, _ id: Int64, _ location: ThumbnailLocation) async -> CGImage? {
        await withCheckedContinuation { done in loader.load(id, at: location) { done.resume(returning: $0) } }
    }

    @Test func loadsDecodesAndCaches() async throws {
        let (library, locations, base) = try makeLibrary(side: 32, count: 2)
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = ThumbnailLoader()
        loader.library = library
        #expect(loader.cached(1) == nil)
        let image = try #require(await load(loader, 1, locations[0]))
        #expect(image.width == 32)
        #expect(loader.cached(1) != nil)
        // A second request is answered from memory, at once, with no token to cancel.
        var answered = false
        let token = loader.load(1, at: locations[0]) { answered = $0 != nil }
        #expect(answered && token == nil)
    }

    @Test func aRequestFromTheOldLibraryNeverReachesTheNewOne() async throws {
        let (a, locationsA, baseA) = try makeLibrary(side: 32, count: 1)
        let (b, locationsB, baseB) = try makeLibrary(side: 48, count: 1)
        defer { try? FileManager.default.removeItem(at: baseA); try? FileManager.default.removeItem(at: baseB) }
        let loader = ThumbnailLoader()
        loader.library = a
        var stale: [CGImage?] = []
        loader.load(7, at: locationsA[0]) { stale.append($0) }
        // The user switches library while that thumbnail is still being read.
        loader.library = b
        let fresh = try #require(await load(loader, 7, locationsB[0]))
        #expect(fresh.width == 48)                // the same id now means the new library's image
        #expect(loader.cached(7)?.width == 48)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stale.isEmpty)                    // the old request was dropped, not answered late
    }

    @Test func cancellingTheOnlyWaiterDropsTheRequestButNotOthers() async throws {
        let (library, locations, base) = try makeLibrary(side: 32, count: 2)
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = ThumbnailLoader()
        loader.library = library
        var cancelledAnswered = false
        let token = loader.load(1, at: locations[0]) { _ in cancelledAnswered = true }
        loader.cancel(token)
        // Two cells wait for the same image; one leaves, the other still gets it.
        var kept: CGImage?
        let leaving = loader.load(2, at: locations[1]) { _ in cancelledAnswered = true }
        loader.load(2, at: locations[1]) { kept = $0 }
        loader.cancel(leaving)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cancelledAnswered)
        #expect(kept != nil)
    }

    @Test func thumbnailsMadeByTheScanAreKnownBeforeTheNextReload() throws {
        let loader = ThumbnailLoader()
        let item = BrowseItem(id: 5, relPath: "a.png", sortDate: 0)
        #expect(loader.location(for: item) == nil)
        var told: Set<Int64> = []
        loader.onAvailable = { told = $0 }
        let location = ThumbnailLocation(pack: 0, offset: 40, length: 10)
        loader.noteMade([(id: 5, location: location)])
        #expect(told == [5])
        #expect(loader.location(for: item) == location)
        // Once the items are read again they carry it themselves.
        loader.itemsReloaded()
        #expect(loader.location(for: item) == nil)
    }
}
