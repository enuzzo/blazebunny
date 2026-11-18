import Testing
import Foundation
import CoreGraphics
import ImageIO
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

    // MARK: Detail

    func load(_ loader: ThumbnailLoader, _ id: Int64, _ location: ThumbnailLocation, _ detail: ThumbnailLoader.Detail) async -> CGImage? {
        await withCheckedContinuation { done in loader.load(id, at: location, detail: detail) { done.resume(returning: $0) } }
    }

    @Test func detailNeededFollowsThePixelsACellShows() {
        // A 512-pixel thumbnail decoded at half size is 256 pixels: enough up to exactly that.
        #expect(ThumbnailLoader.Detail.needed(forPixels: 170) == .small)
        #expect(ThumbnailLoader.Detail.needed(forPixels: 256) == .small)
        #expect(ThumbnailLoader.Detail.needed(forPixels: 257) == .full)
        #expect(ThumbnailLoader.Detail.needed(forPixels: 928) == .full)
        #expect(ThumbnailLoader.Detail.small < .full)
    }

    @Test func smallCellsGetHalfTheThumbnailAndLargerOnesTheWhole() async throws {
        let (library, locations, base) = try makeLibrary(side: 512, count: 2)
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = ThumbnailLoader()
        loader.library = library
        let small = try #require(await load(loader, 1, locations[0], .small))
        #expect(small.width == 256)
        // Half is in memory: enough for a small cell, not for a large one, which still gets it meanwhile.
        #expect(loader.cached(1, detail: .small) != nil && loader.cached(1, detail: .full) == nil && loader.cached(1) == nil)
        #expect(loader.best(1)?.detail == .small)
        let whole = try #require(await load(loader, 1, locations[0], .full))
        #expect(whole.width == 512)
        #expect(loader.best(1)?.detail == .full && loader.cached(1)?.width == 512)
        // The whole one answers a small cell too, at once, and a late half-size decode never replaces it.
        var answered: CGImage?
        #expect(loader.load(1, at: locations[0], detail: .small) { answered = $0 } == nil)
        #expect(answered?.width == 512)
        // Both asked at the same time: each gets its own, the whole one stays in memory.
        async let a = load(loader, 2, locations[1], .small)
        async let b = load(loader, 2, locations[1], .full)
        let (half, full) = await (a, b)
        #expect(half?.width == 256 && full?.width == 512)
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.best(2)?.detail == .full)
    }

    @Test func decodesIntoTheWindowColourSpaceInTheLayoutALayerShows() async throws {
        let (library, locations, base) = try makeLibrary(side: 64, count: 1)
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = ThumbnailLoader()
        loader.library = library
        loader.displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        let image = try #require(await load(loader, 1, locations[0]))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(image.alphaInfo == .noneSkipFirst && image.bitmapInfo.contains(.byteOrder32Little))
        // Another display: what was decoded for the old one is dropped.
        loader.displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        #expect(loader.cached(1) == nil)
        #expect(try #require(await load(loader, 1, locations[0])).colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func aThumbnailMadeAgainIsFoundWhereTheIndexSaysItIsNow() async throws {
        let (library, locations, base) = try makeLibrary(side: 32, count: 1)
        defer { try? FileManager.default.removeItem(at: base) }
        try library.index.upsertFiles([FileRecord(relPath: "a.png", size: 1, mtime: 1, kind: .png)])
        let id = try #require(try library.index.items().first?.id)
        try library.index.saveThumbnail(id: id, locations[0])
        let loader = ThumbnailLoader()
        loader.library = library
        // The grid's item still points at bytes that are not there (an old pack, a stale offset).
        let stale = ThumbnailLocation(pack: 7, offset: 0, length: 100)
        #expect(try #require(await load(loader, id, stale)).width == 32)
        // Nothing in the index either: the cell stays as it is.
        #expect(await load(loader, id + 1, stale) == nil)
    }

    @Test func packsWithAnOlderOrNewerFormatLoadSideBySide() async throws {
        let (library, locations, base) = try makeLibrary(side: 128, count: 1)
        defer { try? FileManager.default.removeItem(at: base) }
        let context = CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        var others: [ThumbnailLocation] = []
        for type in ["public.heic", "public.png"] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            if CGImageDestinationFinalize(destination) { others.append(try library.thumbnails.append(out as Data)) }
        }
        #expect(!others.isEmpty)
        let loader = ThumbnailLoader()
        loader.library = library
        #expect(try #require(await load(loader, 1, locations[0])).width == 128)
        for (i, location) in others.enumerated() {
            let image = try #require(await load(loader, Int64(10 + i), location))
            #expect(image.width == 128 && image.height == 96)
            #expect(try #require(await load(loader, Int64(20 + i), location, .small)).width == 128)   // never enlarged
        }
    }

    // MARK: Placeholders

    /// Waits until `condition` holds (the loader reads placeholders off the main thread).
    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func placeholdersAreReadWithTheLibraryAndKeptUpByTheScan() async throws {
        let (library, locations, base) = try makeLibrary(side: 32, count: 3)
        defer { try? FileManager.default.removeItem(at: base) }
        try library.index.upsertFiles((0..<3).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        let ids = try library.index.items(sort: .oldestFirst).map(\.id)
        let red = ThumbnailPlaceholder(samples: Array(repeating: (255, 0, 0), count: 16))
        let green = ThumbnailPlaceholder(samples: Array(repeating: (0, 255, 0), count: 16))
        try library.index.saveThumbnails([(ids[0], locations[0], red), (ids[1], locations[1], red)])
        let loader = ThumbnailLoader()
        #expect(loader.placeholder(for: ids[0]) == nil)
        loader.library = library
        #expect(await eventually { loader.placeholderCount == 2 })
        #expect(loader.placeholder(for: ids[0]) == red && loader.placeholder(for: ids[2]) == nil)
        // The scan makes one more and replaces another.
        loader.notePlaceholders([(ids[2], green), (ids[0], green)])
        #expect(loader.placeholder(for: ids[2]) == green && loader.placeholder(for: ids[0]) == green)
        // Another library: none of the old colours are left.
        let (other, _, otherBase) = try makeLibrary(side: 32, count: 1)
        defer { try? FileManager.default.removeItem(at: otherBase) }
        loader.library = other
        #expect(loader.placeholder(for: ids[0]) == nil && loader.placeholderCount == 0)
    }

    @Test func aLibraryFromBeforePlaceholdersShowsItsThumbnailsAndGetsItsColoursInTheBackground() async throws {
        let (library, locations, base) = try makeLibrary(side: 64, count: 30)
        defer { try? FileManager.default.removeItem(at: base) }
        try library.index.upsertFiles((0..<30).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        let ids = try library.index.items(sort: .oldestFirst).map(\.id)
        // As an older version left it: every thumbnail made, no colours.
        try library.index.saveThumbnails(zip(ids, locations).map { (id: $0, location: Optional($1)) })
        let loader = ThumbnailLoader()
        loader.library = library
        loader.backfillPlaceholders()
        // Thumbnails load at once, colours or not.
        #expect(try #require(await load(loader, ids[4], locations[4])).width == 64)
        #expect(await eventually { loader.placeholderCount == 30 })
        let colours = try #require(loader.placeholder(for: ids[4])).sample(column: 1, row: 1)
        #expect(colours.b > 200 && colours.r < 90)                       // the fixture is blue
        #expect(try library.index.placeholders().count == 30)            // saved: the next launch reads them
        #expect(try library.index.thumbnailsWithoutPlaceholder().isEmpty)
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
