import Foundation
import Testing
@testable import BlazebunnyCore

struct LibrarySummaryTests {
    func makeIndex(at name: String = "index.sqlite") throws -> (LibraryIndex, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        return (try LibraryIndex(url: url), url)
    }

    @Test func summarisesKindsSourcesSizeAndDates() throws {
        let (idx, _) = try makeIndex()
        try idx.upsertFiles([
            FileRecord(relPath: "a.png", size: 100, mtime: 1_000, kind: .png),
            FileRecord(relPath: "b.png", size: 200, mtime: 3_000, kind: .png),
            FileRecord(relPath: "c.jpg", size: 300, mtime: 2_000, kind: .jpeg),
        ])
        let s = try idx.summary()
        #expect(s.total == 3)
        #expect(s.totalBytes == 600)
        #expect(s.kinds.first == FacetValue(value: "png", count: 2))
        #expect(s.kinds.contains(FacetValue(value: "jpeg", count: 1)))
        #expect(s.oldest == Date(timeIntervalSince1970: 1_000))
        #expect(s.newest == Date(timeIntervalSince1970: 3_000))
        #expect(s.withPrompt == 0)
    }

    @Test func summaryFollowsFilter() throws {
        let (idx, _) = try makeIndex()
        try idx.upsertFiles([
            FileRecord(relPath: "a.png", size: 100, mtime: 1, kind: .png),
            FileRecord(relPath: "c.jpg", size: 300, mtime: 2, kind: .jpeg),
        ])
        var f = FilterState()
        f.types = ["jpeg"]
        let s = try idx.summary(filter: f)
        #expect(s.total == 1)
        #expect(s.totalBytes == 300)
    }

    @Test func emptyLibraryHasNoDates() throws {
        let (idx, _) = try makeIndex()
        let s = try idx.summary()
        #expect(s.total == 0)
        #expect(s.oldest == nil && s.newest == nil)
    }

    @Test func creationDateIsStableAcrossReopen() throws {
        let (idx, url) = try makeIndex()
        let first = try #require(try idx.createdAt())
        #expect(abs(first.timeIntervalSinceNow) < 60)
        let again = try LibraryIndex(url: url)
        #expect(try again.createdAt() == first)
    }
}
