import Testing
import Foundation
import CoreGraphics
import ImageIO
import SQLite3
@testable import BlazebunnyCore

/// Thumbnail placeholders (schema 5), the decoder the grid uses, and packs that hold more than one format.
@Suite("Thumbnail placeholders and formats")
struct ThumbnailFormatTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-thumbs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A picture whose left half is `left` and right half is `right`, with a white band along the top.
    func picture(width: Int, height: Int, left: (CGFloat, CGFloat, CGFloat) = (1, 0, 0), right: (CGFloat, CGFloat, CGFloat) = (0, 0, 1)) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height - height / 4, width: width, height: height / 4))   // the top quarter
        return context.makeImage()!
    }

    func encode(_ image: CGImage, type: String) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Placeholder

    @Test func placeholderKeepsItsSamplesThroughTheIndexBytes() throws {
        var samples: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for i in 0..<16 { samples.append((r: UInt8(i * 16), g: UInt8(255 - i * 16), b: UInt8(i * 7))) }
        let placeholder = ThumbnailPlaceholder(samples: samples)
        let data = placeholder.data
        #expect(data.count == ThumbnailPlaceholder.byteCount && data.count == 32)
        #expect(ThumbnailPlaceholder(data: data) == placeholder)
        // Five or six bits a channel: each sample comes back within one step of what went in.
        for (i, s) in samples.enumerated() {
            let back = placeholder.sample(column: i % 4, row: i / 4)
            #expect(abs(Int(back.r) - Int(s.r)) <= 8 && abs(Int(back.g) - Int(s.g)) <= 4 && abs(Int(back.b) - Int(s.b)) <= 8)
        }
        #expect(ThumbnailPlaceholder(samples: Array(repeating: (255, 255, 255), count: 16)).sample(column: 2, row: 1) == (255, 255, 255))
        #expect(ThumbnailPlaceholder(data: Data(count: 31)) == nil)
        #expect(ThumbnailPlaceholder(data: Data()) == nil)
    }

    @Test func placeholderHoldsThePictureColoursWhereTheyAre() throws {
        let placeholder = try #require(ThumbnailPlaceholder(image: picture(width: 512, height: 384)))
        // Row 0 is the top: the white band. Below it, red on the left and blue on the right.
        let top = placeholder.sample(column: 1, row: 0)
        #expect(top.r > 240 && top.g > 240 && top.b > 240)
        let left = placeholder.sample(column: 0, row: 3), right = placeholder.sample(column: 3, row: 3)
        #expect(left.r > 240 && left.g < 16 && left.b < 16)
        #expect(right.b > 240 && right.r < 16 && right.g < 16)
        // The image a cell draws is those sixteen samples, top row first.
        let image = try #require(placeholder.makeImage())
        #expect(image.width == 4 && image.height == 4)
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        #expect(pixels[0] > 240 && pixels[1] > 240 && pixels[2] > 240)             // top left: white
        #expect(pixels[12 * 4] > 240 && pixels[12 * 4 + 2] < 16)                  // bottom left: red
        #expect(pixels[15 * 4 + 2] > 240 && pixels[15 * 4] < 16)                  // bottom right: blue
    }

    // MARK: Index

    @Test func thumbnailsAreSavedWithTheirColoursAndLoseThemWithTheFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try LibraryIndex(url: dir.appendingPathComponent("index.sqlite"))
        try idx.upsertFiles(["a.png", "b.png", "c.png"].map { FileRecord(relPath: $0, size: 1, mtime: 1, kind: .png) })
        let ids = Dictionary(uniqueKeysWithValues: try idx.items(sort: .name).map { ($0.relPath, $0.id) })
        let red = ThumbnailPlaceholder(samples: Array(repeating: (255, 0, 0), count: 16))
        let blue = ThumbnailPlaceholder(samples: Array(repeating: (0, 0, 255), count: 16))
        try idx.saveThumbnails([
            (ids["a.png"]!, ThumbnailLocation(pack: 0, offset: 0, length: 9), red),
            (ids["b.png"]!, ThumbnailLocation(pack: 0, offset: 9, length: 9), nil),   // made, colours unknown
            (ids["c.png"]!, nil, blue),                                               // failed: nothing is kept
        ])
        #expect(try idx.placeholders() == [ids["a.png"]!: red])
        // The grid's rows are what they were: the colours travel apart from them.
        #expect(try idx.items(sort: .name).map(\.thumbnail?.offset) == [0, 9, nil])
        #expect(try idx.thumbnailsWithoutPlaceholder().map(\.id) == [ids["b.png"]!])
        // Colours worked out later; an item with no thumbnail (or no row any more) is skipped.
        try idx.savePlaceholders([(ids["b.png"]!, blue), (ids["c.png"]!, blue), (9_999, blue)])
        #expect(try idx.placeholders() == [ids["a.png"]!: red, ids["b.png"]!: blue])
        #expect(try idx.thumbnailsWithoutPlaceholder().isEmpty)
        // A newer thumbnail replaces the colours; a deleted file takes them with it.
        try idx.saveThumbnail(id: ids["a.png"]!, ThumbnailLocation(pack: 0, offset: 30, length: 9), placeholder: blue)
        try idx.deleteFiles(relPaths: ["b.png"])
        #expect(try idx.placeholders() == [ids["a.png"]!: blue])
    }

    @Test func migratesAV4IndexAddingPlaceholdersBesideTheBrowseIndex() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        // Build a current index, then put it back to how version 4 left it.
        do {
            let idx = try LibraryIndex(url: url)
            try idx.upsertFiles([FileRecord(relPath: "set/a.png", size: 10, mtime: 5, kind: .png), FileRecord(relPath: "b.png", size: 20, mtime: 9, kind: .png)])
            let p = try idx.pendingMetadata(limit: 5)
            try idx.saveMetadata([(p[0].id, ItemMetadata(width: 640, height: 480, promptRaw: "a lantern --v 7"))])
            try idx.saveThumbnail(id: p[0].id, ThumbnailLocation(pack: 0, offset: 0, length: 10))
        }
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DROP TABLE item_placeholders; UPDATE library SET value = '4' WHERE key = 'schema_version';", nil, nil, nil) == SQLITE_OK)
        func text(_ sql: String) -> String {
            var statement: OpaquePointer?
            var out = ""
            if sqlite3_prepare_v2(raw, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW { out += String(cString: sqlite3_column_text(statement, 0)) + "\n" }
            }
            sqlite3_finalize(statement)
            return out
        }
        let browseBefore = text("SELECT sql FROM sqlite_master WHERE name = 'items_browse'")
        sqlite3_close(raw)

        let idx = try LibraryIndex(url: url)
        #expect(try idx.value(forKey: "schema_version") == "5")
        let items = try idx.items()
        #expect(items.map(\.relPath) == ["b.png", "set/a.png"])
        #expect(items[1].thumbnail == ThumbnailLocation(pack: 0, offset: 0, length: 10))   // thumbnails kept: nothing is made again
        #expect(items[1].width == 640)
        #expect(try idx.counts().thumbnailsDone == 1)
        #expect(try idx.placeholders().isEmpty)                                            // starts empty, filled from the packs later
        #expect(try idx.thumbnailsWithoutPlaceholder().map(\.id) == [items[1].id])
        // The browse index is untouched (the colours are not in it), and the grid's query still walks only it.
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(text("SELECT sql FROM sqlite_master WHERE name = 'items_browse'") == browseBefore)
        #expect(!browseBefore.isEmpty && !browseBefore.contains("colors"))
        var statement: OpaquePointer?
        var detail = ""
        #expect(sqlite3_prepare_v2(raw, """
        EXPLAIN QUERY PLAN SELECT id, rel_path, coalesce(items.created_at, items.file_mtime), width, height, thumb_pack, thumb_offset, thumb_length, source, aspect
        FROM items INDEXED BY items_browse WHERE 1 ORDER BY coalesce(items.created_at, items.file_mtime) DESC, items.id DESC
        """, -1, &statement, nil) == SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW { detail += String(cString: sqlite3_column_text(statement, 3)) + "\n" }
        sqlite3_finalize(statement)
        #expect(detail.contains("COVERING INDEX items_browse") && !detail.contains("item_placeholders"))
    }

    // MARK: Backfill

    @Test func backfillWorksOutColoursFromThePacksAndNothingElse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The folder does not exist: a library whose disk is away still gets its colours.
        let lib = try Library(root: dir.appendingPathComponent("not-attached"), base: dir.appendingPathComponent("libs"))
        try lib.index.upsertFiles((0..<40).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        let items = try lib.index.items(sort: .oldestFirst)
        let redBlue = try ThumbnailMaker.encodeJPEG(picture(width: 512, height: 384))
        let greenYellow = try ThumbnailMaker.encodeJPEG(picture(width: 384, height: 512, left: (0, 1, 0), right: (1, 1, 0)))
        // Thumbnails as an older version saved them: locations only. One of them is not an image.
        var saved: [(id: Int64, location: ThumbnailLocation?)] = []
        for (i, item) in items.enumerated() {
            let data = i == 7 ? Data("not an image at all".utf8) : (i % 2 == 0 ? redBlue : greenYellow)
            saved.append((item.id, try lib.thumbnails.append(data)))
        }
        try lib.index.saveThumbnails(saved)
        #expect(try lib.index.placeholders().isEmpty)

        let batches = Locked(0)
        let count = try PlaceholderBackfill.run(index: lib.index, thumbnails: lib.thumbnails, batchSize: 16, onBatch: { _ in batches.withLock { $0 += 1 } })
        #expect(count == 39 && batches.withLock { $0 } == 3)
        let table = try lib.index.placeholders()
        #expect(table.count == 39 && table[items[7].id] == nil)
        let even = try #require(table[items[0].id]), odd = try #require(table[items[1].id])
        #expect(even.sample(column: 0, row: 3).r > 200 && even.sample(column: 3, row: 3).b > 200)
        #expect(odd.sample(column: 0, row: 3).g > 200 && odd.sample(column: 0, row: 3).r < 60 && odd.sample(column: 3, row: 3).r > 200)
        // Every thumbnail is where it was, and a second run has only the broken one left to try.
        #expect(try lib.index.items(sort: .oldestFirst).map(\.thumbnail) == saved.map(\.location))
        #expect(try PlaceholderBackfill.run(index: lib.index, thumbnails: lib.thumbnails) == 0)
        // Stopped at once, it saves nothing and can be run again.
        try lib.index.saveThumbnail(id: items[7].id, try lib.thumbnails.append(redBlue))
        #expect(try PlaceholderBackfill.run(index: lib.index, thumbnails: lib.thumbnails, isCancelled: { true }) == 0)
        #expect(try PlaceholderBackfill.run(index: lib.index, thumbnails: lib.thumbnails) == 1)
    }

    @Test func aScanSavesColoursWithEachThumbnailAndReportsThem() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<12 { try PNGFixture.plainPNG(width: 96, height: 64).write(to: folder.appendingPathComponent("p\(i).png")) }
        let lib = try Library(root: folder, base: dir.appendingPathComponent("libs"))
        let scanner = FolderScanner(root: folder, index: lib.index, thumbnails: lib.thumbnails, ioConcurrency: 2)
        let events = Locked<[String]>([])
        let reported = Locked<[Int64: ThumbnailPlaceholder]>([:])
        scanner.onPlaceholders = { batch in
            events.withLock { $0.append("colours") }
            reported.withLock { for entry in batch { $0[entry.id] = entry.placeholder } }
        }
        scanner.onThumbnails = { _ in events.withLock { $0.append("thumbnails") } }
        try await scanner.run()
        let table = try lib.index.placeholders()
        #expect(table.count == 12 && table == reported.withLock { $0 })
        // The fixture is orange with a blue quarter at the bottom left.
        let one = try #require(table.values.first)
        #expect(one.sample(column: 0, row: 3).b > 150 && one.sample(column: 3, row: 0).r > 200)
        // Colours are reported before the thumbnails they belong to, so a cell has them when it asks.
        let order = events.withLock { $0 }
        #expect(!order.isEmpty && order.count % 2 == 0)
        for i in stride(from: 0, to: order.count, by: 2) { #expect(order[i] == "colours" && order[i + 1] == "thumbnails") }
        #expect(try lib.index.thumbnailsWithoutPlaceholder().isEmpty)
    }

    // MARK: Decoding and formats

    @Test func decoderGivesTheSizeAskedForAndNeverEnlarges() throws {
        let jpeg = try ThumbnailMaker.encodeJPEG(picture(width: 512, height: 384))
        let whole = try #require(ThumbnailDecoder.decode(jpeg))
        #expect(whole.width == 512 && whole.height == 384)
        let small = try #require(ThumbnailDecoder.decode(jpeg, maxPixel: ThumbnailDecoder.smallPixel))
        #expect(small.width == 256 && small.height == 192)
        let tiny = try ThumbnailMaker.encodeJPEG(picture(width: 96, height: 64))
        #expect(try #require(ThumbnailDecoder.decode(tiny, maxPixel: 256)).width == 96)
        #expect(ThumbnailDecoder.decode(Data("nothing".utf8)) == nil)
        #expect(ThumbnailDecoder.placeholder(of: Data("nothing".utf8)) == nil)
        let colours = try #require(ThumbnailDecoder.placeholder(of: jpeg))
        #expect(colours.sample(column: 0, row: 3).r > 200 && colours.sample(column: 3, row: 3).b > 200)
    }

    @Test func decodeForLayerUsesTheLayoutAndColourSpaceALayerShowsAsItIs() throws {
        let jpeg = try ThumbnailMaker.encodeJPEG(picture(width: 512, height: 384))
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        for (space, name) in [(nil, CGColorSpace.sRGB), (p3, CGColorSpace.displayP3)] as [(CGColorSpace?, CFString)] {
            let image = try #require(ThumbnailDecoder.decodeForLayer(jpeg, maxPixel: 256, colorSpace: space))
            #expect(image.width == 256 && image.height == 192)
            #expect(image.bitsPerPixel == 32 && image.alphaInfo == .noneSkipFirst && image.bitmapInfo.contains(.byteOrder32Little))
            #expect(image.colorSpace?.name == name)
        }
        // The colours are converted, not relabelled: sRGB red is not the reddest red of Display P3.
        let converted = try #require(ThumbnailDecoder.decodeForLayer(jpeg, colorSpace: p3))
        let bytes = try #require(converted.dataProvider?.data) as Data
        let at = (converted.height - 8) * converted.bytesPerRow + 8 * 4    // bottom left: red, stored blue, green, red
        #expect(bytes[at + 2] > 200 && bytes[at + 2] < 250 && bytes[at + 1] > 20)
        // A colour space no bitmap can be made in falls back to sRGB.
        let grey = try #require(ThumbnailDecoder.decodeForLayer(jpeg, colorSpace: CGColorSpaceCreateDeviceGray()))
        #expect(grey.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func packsMayHoldThumbnailsOfDifferentFormats() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ThumbnailStore(directory: dir, maxPackSize: 20_000)   // small packs: the thumbnails spread over several
        let image = picture(width: 320, height: 240)
        var stored: [(format: String, location: ThumbnailLocation)] = []
        stored.append(("jpeg", try store.append(try ThumbnailMaker.encodeJPEG(image))))
        // Whatever else this Mac can write: a later version may store another format next to today's.
        for type in ["public.heic", "public.png", "public.avif"] {
            if let data = encode(image, type: type) { stored.append((type, try store.append(data))) }
        }
        stored.append(("jpeg again", try store.append(try ThumbnailMaker.encodeJPEG(image))))
        #expect(stored.count >= 3)
        for (format, location) in stored {
            let data = try store.data(at: location)
            let whole = try #require(ThumbnailDecoder.decodeForLayer(data), "\(format)")
            #expect(whole.width == 320 && whole.height == 240, "\(format)")
            #expect(try #require(ThumbnailDecoder.decode(data, maxPixel: 160)).width == 160, "\(format)")
            let colours = try #require(ThumbnailDecoder.placeholder(of: data), "\(format)")
            #expect(colours.sample(column: 0, row: 3).r > 200 && colours.sample(column: 3, row: 3).b > 200, "\(format)")
        }
    }

    @Test func makerReturnsTheThumbnailAndItsColours() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("p.png")
        try PNGFixture.plainPNG(width: 1200, height: 800).write(to: file)
        let made = try await ThumbnailMaker.makeWithPlaceholder(from: file, kind: .png)
        let image = try #require(ThumbnailDecoder.decode(made.data))
        #expect(image.width == Blazebunny.thumbnailMaxPixel && image.height == 341)
        #expect(made.data.prefix(2) == Data([0xFF, 0xD8]))   // still JPEG
        let colours = try #require(made.placeholder)
        #expect(colours.sample(column: 0, row: 3).b > 150 && colours.sample(column: 3, row: 0).r > 200)   // blue quarter bottom left, orange elsewhere
        // The plain call is the same thumbnail.
        #expect(try await ThumbnailMaker.make(from: file, kind: .png) == made.data)
    }
}
