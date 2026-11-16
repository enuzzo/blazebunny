import Foundation
import ImageIO

public enum ItemKind: String, Sendable, CaseIterable {
    case png, jpeg, webp, heic, gif, tiff, mp4, mov, psd, other

    public init(pathExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "webp": self = .webp
        case "heic", "heif": self = .heic
        case "gif": self = .gif
        case "tif", "tiff": self = .tiff
        case "mp4", "m4v": self = .mp4
        case "mov": self = .mov
        case "psd": self = .psd
        default: self = .other
        }
    }

    public var isVideo: Bool { self == .mp4 || self == .mov }
    /// Kinds the scanner indexes.
    public var isSupported: Bool { self != .other }
    public var title: String { self == .other ? "Other" : rawValue.uppercased() }
}

public enum CreatedSource: String, Sendable {
    case pngText = "png-text", exif, xmp, file
}

public enum Orientation: String, Codable, CaseIterable, Sendable, Hashable {
    case portrait, landscape, square, wide

    public init?(width: Int?, height: Int?) {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        let r = Double(w) / Double(h)
        switch r {
        case ..<0.95: self = .portrait
        case 0.95...1.05: self = .square
        case ...1.9: self = .landscape
        default: self = .wide
        }
    }

    public var title: String { rawValue.capitalized }
}

/// Human aspect-ratio labels: snaps to common ratios, else the reduced fraction.
public enum AspectRatio {
    static let common: [(Int, Int)] = [(1, 1), (2, 3), (3, 2), (3, 4), (4, 3), (4, 5), (5, 4), (9, 16), (16, 9),
                                       (16, 10), (10, 16), (21, 9), (9, 21), (5, 7), (7, 5), (1, 2), (2, 1), (3, 1)]

    public static func label(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "?" }
        let r = Double(width) / Double(height)
        if let c = common.min(by: { abs(Double($0.0) / Double($0.1) - r) < abs(Double($1.0) / Double($1.1) - r) }),
           abs(Double(c.0) / Double(c.1) - r) / r < 0.012 {
            return "\(c.0):\(c.1)"
        }
        let g = gcd(width, height)
        let (a, b) = (width / g, height / g)
        if a <= 100 && b <= 100 { return "\(a):\(b)" }
        return r >= 1 ? String(format: "%.2f:1", r) : String(format: "1:%.2f", 1 / r)
    }
}

public struct ItemMetadata: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var createdAt: Date?
    public var createdSource: CreatedSource
    public var author: String?
    /// The prompt exactly as found (Midjourney Description, A1111 prompt, …).
    public var promptRaw: String?
    public var xmp: String?
    public var source: ItemSource
    public var camera: CameraInfo?
    public var generator: GeneratorInfo?

    public init(width: Int? = nil, height: Int? = nil, createdAt: Date? = nil, createdSource: CreatedSource = .file,
                author: String? = nil, promptRaw: String? = nil, xmp: String? = nil, source: ItemSource? = nil,
                camera: CameraInfo? = nil, generator: GeneratorInfo? = nil) {
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.createdSource = createdSource
        self.author = author
        self.promptRaw = promptRaw
        self.xmp = xmp
        self.camera = camera
        self.generator = generator
        self.source = source ?? MetadataReader.guessSource(promptRaw: promptRaw, camera: camera, generator: generator, xmp: xmp)
    }

    /// Parsed Midjourney prompt, only for Midjourney images.
    public var prompt: MidjourneyPrompt? {
        guard source == .midjourney, let raw = promptRaw, !raw.isEmpty else { return nil }
        return MidjourneyPrompt(raw: raw)
    }

    /// The prompt text without parameters, for any generator.
    public var promptText: String? {
        if let p = prompt { return p.text }
        guard let raw = promptRaw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Ready-to-paste prompt: Midjourney text + parameters without Job ID, or the raw prompt.
    public var fullPrompt: String? { prompt?.fullPrompt ?? promptText }

    public var orientation: Orientation? { Orientation(width: width, height: height) }

    /// `--ar` for Midjourney, otherwise the pixel ratio label (e.g. "16:9").
    public var aspect: String? {
        if let a = prompt?.aspect { return a }
        guard let w = width, let h = height else { return prompt != nil ? "1:1" : nil }
        return AspectRatio.label(width: w, height: h)
    }

    /// Midjourney model version, e.g. "7", "6.1", "niji 6".
    public var mjVersion: String? {
        guard let p = prompt else { return nil }
        if let n = p.parameters.last(where: { $0.name == "niji" }) { return n.value.isEmpty ? "niji" : "niji \(n.value)" }
        return p.parameters.last(where: { $0.name == "v" || $0.name == "version" })?.value
    }
}

func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

/// Reads embedded metadata with bounded reads. Never opens files for writing.
public enum MetadataReader {
    public static func read(url: URL, kind: ItemKind, fileDate: Date) throws -> ItemMetadata {
        switch kind {
        case .png:
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            let info = try PNGTextReader.read(fileHandle: fh)
            return fromPNG(info, fileDate: fileDate)
        case .mp4, .mov:
            return ItemMetadata(createdAt: fileDate, createdSource: .file, source: .unknown)
        default:
            return try fromImageIO(url: url, fileDate: fileDate)
        }
    }

    static func guessSource(promptRaw: String?, camera: CameraInfo?, generator: GeneratorInfo?, xmp: String?) -> ItemSource {
        if generator != nil { return .stableDiffusion }
        if let p = promptRaw, !p.isEmpty {
            if p.range(of: #"Job ID:\s*[0-9a-fA-F-]{8,}"#, options: .regularExpression) != nil { return .midjourney }
            if p.range(of: #"(^|\s)--(ar|v|niji|stylize|s|raw|sref|cref|chaos|q|style)\b"#, options: .regularExpression) != nil { return .midjourney }
        }
        if let x = xmp, x.range(of: "Screenshot", options: .caseInsensitive) != nil { return .screenshot }
        if camera?.camera != nil { return .camera }
        if let x = xmp, x.contains("trainedAlgorithmicMedia") { return .midjourney }
        return .unknown
    }

    static func fromPNG(_ info: PNGTextInfo, fileDate: Date) -> ItemMetadata {
        var m = ItemMetadata(width: info.width, height: info.height)
        m.author = info.text["Author"]
        m.xmp = info.text["XML:com.adobe.xmp"]
        if let a1111 = info.text["parameters"] {
            let p = A1111Parameters(raw: a1111)
            m.promptRaw = p.prompt
            m.generator = p.info
        } else if let comfy = info.text["prompt"] ?? info.text["workflow"], comfy.hasPrefix("{") {
            let g = ComfyUIGraph.parse(comfy)
            m.promptRaw = g.prompt
            m.generator = g.info
        } else {
            m.promptRaw = info.text["Description"]
        }
        m.source = guessSource(promptRaw: m.promptRaw, camera: nil, generator: m.generator, xmp: m.xmp)
        if let s = info.text["Creation Time"], let d = PNGDate.parse(s) {
            m.createdAt = d
            m.createdSource = .pngText
        } else if let x = m.xmp, let d = xmpDate(x) {
            m.createdAt = d
            m.createdSource = .xmp
        } else {
            m.createdAt = fileDate
            m.createdSource = .file
        }
        return m
    }

    static func fromImageIO(url: URL, fileDate: Date) throws -> ItemMetadata {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        var m = ItemMetadata()
        m.width = props[kCGImagePropertyPixelWidth] as? Int
        m.height = props[kCGImagePropertyPixelHeight] as? Int
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5, let w = m.width, let h = m.height {
            m.width = h
            m.height = w
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let data = CGImageMetadataCreateXMPData(meta, nil) {
            m.xmp = String(data: data as Data, encoding: .utf8)
        }
        m.author = (tiff?[kCGImagePropertyTIFFArtist] as? String) ?? (iptc?[kCGImagePropertyIPTCByline] as? [String])?.first
        m.promptRaw = (tiff?[kCGImagePropertyTIFFImageDescription] as? String)
            ?? (iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String)

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if make != nil || model != nil {
            var name = model ?? make!
            if let make, let model, !model.lowercased().hasPrefix(make.lowercased().components(separatedBy: " ").first ?? "") {
                name = make.capitalized + " " + model
            }
            m.camera = CameraInfo(camera: name,
                                  lens: exif?[kCGImagePropertyExifLensModel] as? String,
                                  fNumber: exif?[kCGImagePropertyExifFNumber] as? Double,
                                  exposureTime: exif?[kCGImagePropertyExifExposureTime] as? Double,
                                  iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
                                  focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double)
        }
        let userComment = exif?[kCGImagePropertyExifUserComment] as? String
        if userComment?.localizedCaseInsensitiveContains("screenshot") == true {
            m.source = .screenshot
        } else {
            m.source = guessSource(promptRaw: m.promptRaw, camera: m.camera, generator: nil, xmp: m.xmp)
        }
        if m.source == .camera || m.source == .screenshot, m.promptRaw != nil, m.source != .midjourney {
            m.promptRaw = nil  // camera descriptions are captions, not prompts
        }

        if let s = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
           let d = exifDate(s, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) {
            m.createdAt = d
            m.createdSource = .exif
        } else if let x = m.xmp, let d = xmpDate(x) {
            m.createdAt = d
            m.createdSource = .xmp
        } else {
            m.createdAt = fileDate
            m.createdSource = .file
        }
        return m
    }

    /// EXIF `yyyy:MM:dd HH:mm:ss`, local time unless an offset is given.
    static func exifDate(_ s: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let off = offset, !off.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return f.date(from: s + off)
        }
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    /// First of DateTimeOriginal / CreateDate / DateCreated in an XMP packet.
    static func xmpDate(_ xmp: String) -> Date? {
        let keys = ["exif:DateTimeOriginal", "xmp:CreateDate", "photoshop:DateCreated"]
        for key in keys {
            let attr = try? Regex("\(key)=\"([^\"]+)\"")
            let elem = try? Regex("<\(key)>([^<]+)</\(key)>")
            for r in [attr, elem].compactMap({ $0 }) {
                if let m = xmp.firstMatch(of: r), let v = m.output[1].substring {
                    if let d = iso8601(String(v)) { return d }
                }
            }
        }
        return nil
    }

    static func iso8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
                                                   [.withFullDate, .withTime, .withColonSeparatorInTime]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
