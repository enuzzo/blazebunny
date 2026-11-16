import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import BlazebunnyCore

struct MetadataReaderTests {
    let fileDate = Date(timeIntervalSince1970: 1_700_000_000)

    func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    @Test func midjourneyPNG() throws {
        let url = try write(PNGFixture.midjourney(prompt: "a fox --ar 2:3 Job ID: 00000000-0000-0000-0000-000000000001", width: 200, height: 300), ext: "png")
        let m = try MetadataReader.read(url: url, kind: .png, fileDate: fileDate)
        #expect(m.createdSource == .pngText)
        #expect(m.createdAt == Date(timeIntervalSince1970: 1_766_441_072))
        #expect(m.author == "test_author")
        #expect(m.prompt?.text == "a fox")
        #expect(m.aspect == "2:3")
        #expect(m.width == 200 && m.height == 300)
    }

    @Test func pngWithoutTextFallsBackToFileDate() throws {
        let url = try write(PNGFixture.plainPNG(width: 160, height: 90), ext: "png")
        let m = try MetadataReader.read(url: url, kind: .png, fileDate: fileDate)
        #expect(m.createdSource == .file)
        #expect(m.createdAt == fileDate)
        #expect(m.prompt == nil)
        #expect(m.aspect == "16:9")
    }

    @Test func jpegWithExifDate() throws {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+02:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "a photo --ar 4:3"],
        ]
        CGImageDestinationAddImage(dest, PNGFixture.image(width: 40, height: 30), props as CFDictionary)
        CGImageDestinationFinalize(dest)
        let url = try write(out as Data, ext: "jpg")
        let m = try MetadataReader.read(url: url, kind: .jpeg, fileDate: fileDate)
        #expect(m.createdSource == .exif)
        #expect(m.createdAt == ISO8601DateFormatter().date(from: "2024-05-06T05:08:09Z"))
        #expect(m.prompt?.aspect == "4:3")
        #expect(m.width == 40)
    }

    @Test func xmpDateFallback() {
        let x = #"<rdf:Description xmp:CreateDate="2023-01-02T03:04:05Z"/>"#
        #expect(MetadataReader.xmpDate(x) == ISO8601DateFormatter().date(from: "2023-01-02T03:04:05Z"))
    }
}
