import Foundation
import Testing
@testable import BlazebunnyCore

struct PNGTextReaderTests {
    func temp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        return url
    }

    func read(_ data: Data) throws -> PNGTextInfo {
        let url = try temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try PNGTextReader.read(fileHandle: fh)
    }

    @Test func readsTextChunksAndSize() throws {
        let info = try read(PNGFixture.midjourney(prompt: "a cat --v 7 Job ID: 00000000-0000-0000-0000-000000000000", width: 120, height: 80))
        #expect(info.width == 120)
        #expect(info.height == 80)
        #expect(info.text["Creation Time"] == "Mon, 22 Dec 2025 22:04:32 GMT")
        #expect(info.text["Author"] == "test_author")
        #expect(info.text["Description"]?.hasPrefix("a cat --v 7") == true)
        #expect(info.text["XML:com.adobe.xmp"]?.contains("xmpmeta") == true)
    }

    @Test func decodesCompressedChunks() throws {
        let info = try read(PNGFixture.make(text: [
            .init(type: "zTXt", key: "Comment", value: "zipped latin1 café"),
            .init(type: "iTXt", key: "Title", value: "compressed ünïcode ✓", compressed: true),
            .init(type: "iTXt", key: "Plain", value: "plain ✓"),
        ]))
        #expect(info.text["Comment"] == "zipped latin1 café")
        #expect(info.text["Title"] == "compressed ünïcode ✓")
        #expect(info.text["Plain"] == "plain ✓")
    }

    @Test func findsChunksBeyondInitialWindow() throws {
        let info = try read(PNGFixture.make(text: [.init(type: "tEXt", key: "Description", value: "far away")], padding: 40_000))
        #expect(info.text["Description"] == "far away")
    }

    @Test func plainPNGHasNoText() throws {
        let info = try read(PNGFixture.plainPNG(width: 10, height: 20))
        #expect(info.text.isEmpty)
        #expect(info.width == 10 && info.height == 20)
    }

    @Test func rejectsNonPNG() throws {
        #expect(throws: PNGTextReader.Error.notPNG) {
            try read(Data((0..<500).map { UInt8($0 % 251) }))
        }
    }

    @Test func rejectsTruncated() throws {
        let png = PNGFixture.make(text: [.init(type: "tEXt", key: "Description", value: String(repeating: "x", count: 5000))])
        #expect(throws: PNGTextReader.Error.self) {
            try read(png.prefix(3000))
        }
    }
}
