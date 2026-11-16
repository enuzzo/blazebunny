import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import BlazebunnyCore

struct SourceDetectionTests {
    let fileDate = Date(timeIntervalSince1970: 1_700_000_000)

    func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    func readPNG(_ chunks: [PNGFixture.TextChunk], width: Int = 64, height: Int = 48) throws -> ItemMetadata {
        try MetadataReader.read(url: write(PNGFixture.make(width: width, height: height, text: chunks), ext: "png"), kind: .png, fileDate: fileDate)
    }

    @Test func midjourney() throws {
        let m = try readPNG([.init(type: "tEXt", key: "Description", value: "a cat --ar 1:1 --v 7 Job ID: 00000000-0000-0000-0000-000000000000")])
        #expect(m.source == .midjourney)
        #expect(m.mjVersion == "7")
        #expect(m.fullPrompt == "a cat --ar 1:1 --v 7")
    }

    @Test func nijiVersion() throws {
        let m = try readPNG([.init(type: "tEXt", key: "Description", value: "a fox --niji 6 Job ID: 00000000-0000-0000-0000-000000000000")])
        #expect(m.mjVersion == "niji 6")
    }

    @Test func automatic1111() throws {
        let raw = "a castle on a hill, oil painting\nNegative prompt: blurry, lowres\nSteps: 30, Sampler: DPM++ 2M, CFG scale: 6.5, Seed: 1234, Model: sdxl_base"
        let m = try readPNG([.init(type: "tEXt", key: "parameters", value: raw)])
        #expect(m.source == .stableDiffusion)
        #expect(m.promptText == "a castle on a hill, oil painting")
        #expect(m.generator?.steps == 30)
        #expect(m.generator?.cfg == 6.5)
        #expect(m.generator?.model == "sdxl_base")
        #expect(m.generator?.negativePrompt == "blurry, lowres")
        #expect(m.prompt == nil)  // not parsed as Midjourney
    }

    @Test func comfyUI() throws {
        let graph = #"{"3":{"class_type":"KSampler","inputs":{"steps":20,"cfg":7,"sampler_name":"euler","seed":42}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"flux1-dev.safetensors"}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a glass whale"}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"ugly"}}}"#
        let m = try readPNG([.init(type: "tEXt", key: "prompt", value: graph)])
        #expect(m.source == .stableDiffusion)
        #expect(m.promptText == "a glass whale")
        #expect(m.generator?.model == "flux1-dev.safetensors")
        #expect(m.generator?.steps == 20)
        #expect(m.generator?.tool == "ComfyUI")
    }

    @Test func screenshotPNG() throws {
        let m = try readPNG([.init(type: "iTXt", key: "XML:com.adobe.xmp", value: "<exif:UserComment><rdf:Alt><rdf:li>Screenshot</rdf:li></rdf:Alt></exif:UserComment>")])
        #expect(m.source == .screenshot)
    }

    @Test func plainPNGIsUnknown() throws {
        let m = try readPNG([], width: 300, height: 100)
        #expect(m.source == .unknown)
        #expect(m.orientation == .wide)
        #expect(m.aspect == "3:1")
    }

    @Test func cameraJPEG() throws {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X100V"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.0, kCGImagePropertyExifExposureTime: 0.004,
                                             kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifLensModel: "23mm f/2"],
        ]
        CGImageDestinationAddImage(dest, PNGFixture.image(width: 60, height: 40), props as CFDictionary)
        CGImageDestinationFinalize(dest)
        let m = try MetadataReader.read(url: write(out as Data, ext: "jpg"), kind: .jpeg, fileDate: fileDate)
        #expect(m.source == .camera)
        #expect(m.camera?.camera == "Fujifilm X100V")
        #expect(m.camera?.exposureSummary == "ƒ/2 · 1/250 s · ISO 200")
        #expect(m.aspect == "3:2")
        #expect(m.orientation == .landscape)
    }

    @Test func aspectLabels() {
        #expect(AspectRatio.label(width: 1688, height: 3000) == "9:16")
        #expect(AspectRatio.label(width: 1504, height: 2048) == "47:64")
        #expect(AspectRatio.label(width: 6000, height: 4000) == "3:2")
        #expect(AspectRatio.label(width: 1000, height: 333) == "3:1")
    }
}
