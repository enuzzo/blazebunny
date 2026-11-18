import Foundation
import SQLite3
import Testing
@testable import BlazebunnyCore

/// Tests for the speed pass: reads that do not wait for the scanner, thumbnails read without a
/// shared lock, the browse index, month sections, the scanner's cancel and priority, the preview maths.
struct SpeedPassTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-speed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeIndex(_ dir: URL) throws -> LibraryIndex { try LibraryIndex(url: dir.appendingPathComponent("index.sqlite")) }

    func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Double {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!.timeIntervalSince1970
    }

    // MARK: - Month sections

    @Test func monthSectionsSplitSortedDatesByCalendarMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let dates = [date(2025, 3, 30, calendar: cal), date(2025, 3, 2, calendar: cal), date(2025, 2, 28, calendar: cal),
                     date(2024, 12, 31, calendar: cal), date(2024, 12, 1, calendar: cal)]
        let sections = MonthSections.split(dates, calendar: cal)
        #expect(sections.map(\.range) == [0..<2, 2..<3, 3..<5])
        #expect(sections.map { MonthSections.key($0.monthStart, calendar: cal) } == ["2025-03", "2025-02", "2024-12"])
        #expect(MonthSections.split([Double](), calendar: cal).isEmpty)
    }

    @Test func monthSectionsRespectTheTimeZoneAtMidnight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var zurich = utc
        zurich.timeZone = TimeZone(identifier: "Europe/Zurich")!
        // 23:30 UTC on 31 January is already February in Zurich.
        let t = utc.date(from: DateComponents(year: 2025, month: 1, day: 31, hour: 23, minute: 30))!.timeIntervalSince1970
        #expect(MonthSections.key(MonthSections.split([t], calendar: utc)[0].monthStart, calendar: utc) == "2025-01")
        #expect(MonthSections.key(MonthSections.split([t], calendar: zurich)[0].monthStart, calendar: zurich) == "2025-02")
    }

    @Test func monthHistogramCountsPerMonthAndFollowsWrites() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        let cal = Calendar.current
        try idx.upsertFiles([
            FileRecord(relPath: "a.png", size: 1, mtime: date(2025, 1, 10, calendar: cal), kind: .png),
            FileRecord(relPath: "b.png", size: 1, mtime: date(2025, 1, 20, calendar: cal), kind: .png),
            FileRecord(relPath: "c.png", size: 1, mtime: date(2025, 3, 5, calendar: cal), kind: .png),
        ])
        let months = try idx.monthHistogram(filter: FilterState(), search: nil)
        #expect(months == [MonthCount(month: "2025-01", count: 2), MonthCount(month: "2025-03", count: 1)])
        // The answer is kept until the index changes: a new file must show up at once.
        try idx.upsertFiles([FileRecord(relPath: "d.png", size: 1, mtime: date(2025, 3, 6, calendar: cal), kind: .png)])
        #expect(try idx.monthHistogram(filter: FilterState(), search: nil).last == MonthCount(month: "2025-03", count: 2))
    }

    // MARK: - Index

    @Test func itemsCarryTheirThumbnailLocation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        try idx.upsertFiles([FileRecord(relPath: "a.png", size: 1, mtime: 2, kind: .png), FileRecord(relPath: "b.png", size: 1, mtime: 1, kind: .png)])
        let ids = Dictionary(uniqueKeysWithValues: try idx.items().map { ($0.relPath, $0.id) })
        #expect(try idx.items().allSatisfy { !$0.hasThumbnail })
        let location = ThumbnailLocation(pack: 2, offset: 4096, length: 777)
        try idx.saveThumbnails([(ids["a.png"]!, location), (ids["b.png"]!, nil)])
        let items = Dictionary(uniqueKeysWithValues: try idx.items().map { ($0.relPath, $0) })
        #expect(items["a.png"]?.thumbnail == location)
        #expect(items["b.png"]?.thumbnail == nil)          // a failed thumbnail has no location
        let c = try idx.counts()
        #expect(c.thumbnailsDone == 1 && c.thumbnailsFailed == 1 && c.total == 2)
        #expect(try idx.items()[0].fileName == "a.png")
    }

    @Test func countsMatchWhatWasSaved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        try idx.upsertFiles((0..<5).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        let pending = try idx.pendingMetadata(limit: 10)
        try idx.saveMetadata([(pending[0].id, ItemMetadata(promptRaw: "a lantern --v 7")), (pending[1].id, ItemMetadata()), (pending[2].id, nil)])
        let c = try idx.counts()
        #expect(c.total == 5 && c.metadataDone == 2 && c.metadataFailed == 1 && c.withPrompt == 1)
    }

    @Test func aBroadSearchAndASelectiveOneReturnTheSameRowsInOrder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        // More matches than `selectiveMatchLimit`, so the broad search walks the browse index while
        // the selective one starts from its matches: both must give the same rows, newest first.
        let n = LibraryIndex.selectiveMatchLimit + 200
        try idx.upsertFiles((0..<n).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        try idx.saveMetadata(try idx.pendingMetadata(limit: n).enumerated().map { i, p in
            (p.id, ItemMetadata(createdAt: Date(timeIntervalSince1970: Double(i)), promptRaw: i % 100 == 0 ? "common rare" : "common"))
        })
        let broad = try idx.items(search: "common")
        #expect(broad.count == n)
        #expect(broad.map(\.sortDate) == broad.map(\.sortDate).sorted(by: >))
        let rare = try idx.items(search: "rare")
        #expect(rare.count == n / 100 + (n % 100 == 0 ? 0 : 1))
        #expect(rare.map(\.id) == broad.filter { Int($0.sortDate) % 100 == 0 }.map(\.id))
        #expect(try idx.items(search: "common", limit: 7).map(\.id) == Array(broad.prefix(7).map(\.id)))
        #expect(try idx.summary(search: "common").total == n)
        #expect(try idx.summary(search: "rare").total == rare.count)
    }

    @Test func summaryWithSearchAndFacets() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        let job = " Job ID: 00000000-0000-0000-0000-000000000000"
        try idx.upsertFiles([
            FileRecord(relPath: "a.png", size: 100, mtime: 0, kind: .png), FileRecord(relPath: "b.png", size: 200, mtime: 0, kind: .png),
            FileRecord(relPath: "c.jpg", size: 400, mtime: 0, kind: .jpeg), FileRecord(relPath: "d.jpg", size: 800, mtime: 0, kind: .jpeg),
        ])
        let ids = Dictionary(uniqueKeysWithValues: try idx.pendingMetadata(limit: 10).map { ($0.relPath, $0.id) })
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        try idx.saveMetadata([
            (ids["a.png"]!, ItemMetadata(width: 1600, height: 900, createdAt: d(1_000), promptRaw: "red lantern --ar 16:9 --v 7" + job)),
            (ids["b.png"]!, ItemMetadata(width: 800, height: 1200, createdAt: d(2_000), promptRaw: "blue lantern --ar 2:3 --v 7" + job)),
            (ids["c.jpg"]!, ItemMetadata(width: 6000, height: 4000, createdAt: d(3_000), camera: CameraInfo(camera: "Demo Cam"))),
            (ids["d.jpg"]!, ItemMetadata(width: 800, height: 1200, createdAt: d(4_000), promptRaw: "green lantern, plain text")),
        ])
        // Search alone.
        var s = try idx.summary(search: "lantern")
        #expect(s.total == 3 && s.totalBytes == 1_100 && s.withPrompt == 3)
        #expect(s.oldest == d(1_000) && s.newest == d(4_000))
        #expect(s.kinds == [FacetValue(value: "png", count: 2), FacetValue(value: "jpeg", count: 1)])
        // Search plus a facet: only the Midjourney lanterns.
        var f = FilterState(); f.sources = [.midjourney]
        s = try idx.summary(filter: f, search: "lantern")
        #expect(s.total == 2 && s.totalBytes == 300)
        #expect(s.sources == [FacetValue(value: "midjourney", count: 2)])
        // Search plus two facets: portrait Midjourney lanterns.
        f.orientations = [.portrait]
        s = try idx.summary(filter: f, search: "lantern")
        #expect(s.total == 1 && s.newest == d(2_000))
        // A search that matches nothing.
        s = try idx.summary(filter: f, search: "nothing")
        #expect(s.total == 0 && s.kinds.isEmpty && s.oldest == nil)
        // Facet counts under the same search ignore their own selection.
        #expect(Set(try idx.facetCounts(.source, filter: f, search: "lantern").map(\.value)) == ["midjourney", "unknown"])
    }

    @Test func migratesAV3IndexToTheBrowseIndexWithoutLosingAnything() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        // Build a current index, then put it back to how version 3 left it.
        do {
            let idx = try LibraryIndex(url: url)
            try idx.upsertFiles([FileRecord(relPath: "set/a.png", size: 10, mtime: 5, kind: .png), FileRecord(relPath: "b.png", size: 20, mtime: 9, kind: .png)])
            let p = try idx.pendingMetadata(limit: 5)
            try idx.saveMetadata([(p[0].id, ItemMetadata(width: 640, height: 480, promptRaw: "a lantern --v 7"))])
            try idx.saveThumbnail(id: p[0].id, ThumbnailLocation(pack: 0, offset: 0, length: 10))
        }
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, """
        DROP INDEX items_browse; DROP INDEX items_name;
        CREATE INDEX items_sort ON items(coalesce(created_at, file_mtime));
        UPDATE library SET value = '3' WHERE key = 'schema_version';
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let idx = try LibraryIndex(url: url)
        #expect(try idx.value(forKey: "schema_version") == "5")
        let items = try idx.items()
        #expect(items.map(\.relPath) == ["b.png", "set/a.png"])
        #expect(items[1].thumbnail == ThumbnailLocation(pack: 0, offset: 0, length: 10))   // thumbnails kept
        #expect(items[1].width == 640)                                                    // metadata kept
        #expect(try idx.items(search: "lantern").count == 1)
        #expect(try idx.items(sort: .name).map(\.relPath) == ["set/a.png", "b.png"])
        #expect(try idx.counts().withPrompt == 1)
    }

    @Test func readersSeeEveryWriteAndWorkWhileTheScannerWrites() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = try makeIndex(dir)
        try idx.upsertFiles((0..<400).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: Double($0), kind: .png) })
        let pending = try idx.pendingMetadata(limit: 400)
        // A writer saving batches, as a scan does, while readers ask for items and details.
        let writer = Task.detached {
            for start in stride(from: 0, to: 400, by: 20) {
                try idx.saveMetadata(pending[start..<start + 20].map { ($0.id, ItemMetadata(width: 10, height: 10, promptRaw: "lantern \($0.id)")) })
            }
        }
        let reads = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var ok = 0
                    for i in 0..<100 {
                        if (try? idx.items(limit: 50))?.count == 50, (try? idx.detail(id: pending[i].id)) != nil { ok += 1 }
                    }
                    return ok
                }
            }
            return await group.reduce(0, +)
        }
        try await writer.value
        #expect(reads == 400)
        // Read-your-writes across the connections: the moment a save returns, readers see it.
        #expect(try idx.counts().metadataDone == 400)
        #expect(try idx.items(search: "lantern").count == 400)
        #expect(try idx.detail(id: pending[399].id)?.metadata?.promptRaw == "lantern \(pending[399].id)")
    }

    // MARK: - Thumbnail store

    @Test func thumbnailsAreReadCorrectlyFromManyThreadsWhileAppending() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ThumbnailStore(directory: dir, maxPackSize: 64 << 10)   // small packs: several files
        func blob(_ i: Int) -> Data { Data(repeating: UInt8(i % 251), count: 900 + i % 300) }
        let first = try (0..<300).map { try store.append(blob($0)) }
        #expect(Set(first.map(\.pack)).count > 1)
        let appender = Task.detached { try (300..<600).map { try store.append(blob($0)) } }
        let wrong = await withTaskGroup(of: Int.self) { group in
            for t in 0..<8 {
                group.addTask {
                    var bad = 0
                    for k in 0..<300 {
                        let i = (k * 7 + t * 13) % 300
                        if (try? store.data(at: first[i])) != blob(i) { bad += 1 }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        #expect(wrong == 0)
        let later = try await appender.value
        for (k, loc) in later.enumerated() { #expect(try store.data(at: loc) == blob(300 + k)) }
        // A location that points past the end is an error, not garbage.
        #expect(throws: (any Error).self) { try store.data(at: ThumbnailLocation(pack: later.last!.pack, offset: 1 << 30, length: 10)) }
        #expect(throws: (any Error).self) { try store.data(at: ThumbnailLocation(pack: 999, offset: 0, length: 10)) }
    }

    // MARK: - Scanner

    func makeFolder(_ dir: URL, count: Int) throws -> URL {
        let folder = dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = PNGFixture.midjourney(prompt: "an invented lantern --ar 3:2 --v 7 Job ID: 00000000-0000-0000-0000-000000000000", width: 60, height: 40)
        for i in 0..<count { try png.write(to: folder.appendingPathComponent(String(format: "img_%04d.png", i))) }
        return folder
    }

    @Test func cancelMidBatchLeavesAResumableIndex() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(dir, count: 200)
        let lib = try Library(root: folder, base: dir.appendingPathComponent("libs"))
        let scanner = FolderScanner(root: folder, index: lib.index, thumbnails: lib.thumbnails, ioConcurrency: 2)
        // Cancel as soon as the first batch of metadata is reported: more batches are still to come.
        try await scanner.run { p in if p.phase == .metadata, p.metadataDone > 0 { scanner.cancel() } }

        let partial = try lib.index.counts()
        #expect(partial.total == 200)                                        // the listing was complete
        #expect(partial.metadataDone > 0 && partial.metadataDone < 200)      // stopped in the middle
        #expect(partial.metadataFailed == 0 && partial.thumbnailsFailed == 0) // nothing unread was marked failed
        // Every thumbnail recorded so far is really in the packs.
        for item in try lib.index.items() where item.hasThumbnail { #expect(try lib.thumbnails.data(at: item.thumbnail!).count > 0) }

        // A new scan picks up where the first stopped and finishes everything, reading no file twice.
        let again = FolderScanner(root: folder, index: lib.index, thumbnails: lib.thumbnails, ioConcurrency: 2)
        try await again.run()
        let done = try lib.index.counts()
        #expect(done.metadataDone == 200 && done.thumbnailsDone == 200)
        #expect(again.metadataReads == 200 - partial.metadataDone)
    }

    @Test func prioritizedThumbnailsAreMadeFirstAndReportedWithTheirLocation() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(dir, count: 120)
        let lib = try Library(root: folder, base: dir.appendingPathComponent("libs"))
        // A first pass without thumbnails gives every file its id.
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        let ids = try lib.index.items(sort: .name).map(\.id)
        let wanted = Array(ids.suffix(5))   // the last files by name: far from where a plain scan starts

        let scanner = FolderScanner(root: folder, index: lib.index, thumbnails: lib.thumbnails, ioConcurrency: 2)
        let made = Locked<[[(id: Int64, location: ThumbnailLocation)]]>([])
        scanner.onThumbnails = { batch in made.withLock { $0.append(batch) } }
        scanner.prioritize(ids: wanted)
        try await scanner.run()

        let batches = made.withLock { $0 }
        #expect(Set(try #require(batches.first).map(\.id)) == Set(wanted))   // what is on screen comes first
        let all = batches.flatMap { $0 }
        #expect(all.count == 120 && Set(all.map(\.id)).count == 120)         // every thumbnail reported once
        // The reported locations are the ones stored in the index and readable from the packs.
        let stored = Dictionary(uniqueKeysWithValues: try lib.index.items().map { ($0.id, $0.thumbnail) })
        for entry in all {
            #expect(stored[entry.id] == entry.location)
            #expect(try lib.thumbnails.data(at: entry.location).count == entry.location.length)
        }
    }

    @Test func volumeKindOfATemporaryFolderGivesASafeConcurrency() throws {
        let kind = VolumeKind(of: FileManager.default.temporaryDirectory)
        #expect((2...12).contains(kind.recommendedIOConcurrency))
        #expect(VolumeKind.rotational.recommendedIOConcurrency == 2 && VolumeKind.unknown.recommendedIOConcurrency == 2)
        // A solid-state disk: by the number of cores, between 6 and 12.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(VolumeKind.solidState.recommendedIOConcurrency == min(12, max(6, cores - 2)))
        #expect((6...12).contains(VolumeKind.solidState.recommendedIOConcurrency))
        // A path that does not exist is unknown, never a crash.
        #expect(VolumeKind(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x")) == .unknown)
    }

    // MARK: - Preview

    @Test func previewPixelSizeFitsTheBoxAndNeverExceedsTheImage() {
        let box = CGSize(width: 320, height: 300)
        // Square image in a 320 x 300 box at 2x: 300 pt high, 600 px, rounded up to a 256 step.
        #expect(PreviewDecoder.pixelSize(fitting: box, scale: 2, imageWidth: 2048, imageHeight: 2048) == 768)
        // Wide image: 320 pt wide, 640 px.
        #expect(PreviewDecoder.pixelSize(fitting: box, scale: 2, imageWidth: 4000, imageHeight: 2250) == 768)
        // A small image is not blown up.
        #expect(PreviewDecoder.pixelSize(fitting: box, scale: 2, imageWidth: 200, imageHeight: 100) == 256)
        // Unknown dimensions: the box's long side.
        #expect(PreviewDecoder.pixelSize(fitting: box, scale: 2, imageWidth: nil, imageHeight: nil) == 768)
        #expect(PreviewDecoder.pixelSize(fitting: CGSize(width: 500, height: 300), scale: 2, imageWidth: 4000, imageHeight: 2250) == 1024)
        // The exact need, before rounding: what decides whether the 512 px thumbnail is already enough.
        #expect(PreviewDecoder.neededPixels(fitting: box, scale: 2, imageWidth: 2048, imageHeight: 2048) == 600)
        #expect(PreviewDecoder.neededPixels(fitting: box, scale: 1, imageWidth: 2048, imageHeight: 2048) == 300)   // non-Retina: the thumbnail does
        #expect(PreviewDecoder.neededPixels(fitting: box, scale: 2, imageWidth: 200, imageHeight: 100) == 200)
    }

    @Test func previewNeighboursFollowTheDirectionOfTravel() {
        #expect(PreviewDecoder.neighbours(of: 10, count: 100, direction: 1) == [11, 12, 9])
        #expect(PreviewDecoder.neighbours(of: 10, count: 100, direction: -1) == [9, 8, 11])
        #expect(PreviewDecoder.neighbours(of: 10, count: 100, direction: 0) == [11, 9, 12, 8])
        #expect(PreviewDecoder.neighbours(of: 0, count: 3, direction: -1) == [1])       // nothing before the first
        #expect(PreviewDecoder.neighbours(of: 2, count: 3, direction: 1) == [1])        // nothing after the last
        #expect(PreviewDecoder.neighbours(of: 0, count: 1, direction: 1).isEmpty)
        #expect(PreviewDecoder.neighbours(of: 5, count: 0, direction: 1).isEmpty)
    }

    @Test func previewDecodeIsBoundedAndOnlyReads() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.png")
        try PNGFixture.plainPNG(width: 800, height: 400).write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let image = try #require(PreviewDecoder.decode(url: url, maxPixel: 256))
        #expect(image.width == 256 && image.height == 128)
        #expect(PreviewDecoder.decode(url: dir.appendingPathComponent("missing.png"), maxPixel: 256) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["big.png"])   // nothing written next to it
    }
}
