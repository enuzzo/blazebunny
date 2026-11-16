import Foundation

/// Where an image comes from, detected from its embedded metadata.
public enum ItemSource: String, Codable, CaseIterable, Sendable, Hashable {
    case camera, midjourney, stableDiffusion, screenshot, unknown

    public var title: String {
        switch self {
        case .camera: return "Camera"
        case .midjourney: return "Midjourney"
        case .stableDiffusion: return "Stable Diffusion"
        case .screenshot: return "Screenshot"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .camera: return "camera"
        case .midjourney: return "sparkle"
        case .stableDiffusion: return "wand.and.sparkles"
        case .screenshot: return "macwindow"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    public var isGenerated: Bool { self == .midjourney || self == .stableDiffusion }
}

/// Generation settings of a Stable Diffusion / ComfyUI image.
public struct GeneratorInfo: Codable, Hashable, Sendable {
    public var model: String?
    public var steps: Int?
    public var cfg: Double?
    public var seed: String?
    public var sampler: String?
    public var negativePrompt: String?
    public var tool: String?  // "A1111", "ComfyUI"

    public init(model: String? = nil, steps: Int? = nil, cfg: Double? = nil, seed: String? = nil,
                sampler: String? = nil, negativePrompt: String? = nil, tool: String? = nil) {
        self.model = model
        self.steps = steps
        self.cfg = cfg
        self.seed = seed
        self.sampler = sampler
        self.negativePrompt = negativePrompt
        self.tool = tool
    }
}

/// Camera exposure, from EXIF.
public struct CameraInfo: Codable, Hashable, Sendable {
    public var camera: String?
    public var lens: String?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var iso: Int?
    public var focalLength: Double?

    public init(camera: String? = nil, lens: String? = nil, fNumber: Double? = nil, exposureTime: Double? = nil,
                iso: Int? = nil, focalLength: Double? = nil) {
        self.camera = camera
        self.lens = lens
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.focalLength = focalLength
    }

    /// e.g. "ƒ/2.8 · 1/250 s · ISO 200 · 35 mm"
    public var exposureSummary: String? {
        var parts: [String] = []
        if let f = fNumber { parts.append("ƒ/" + Self.trim(f)) }
        if let t = exposureTime {
            parts.append(t >= 1 ? Self.trim(t) + " s" : "1/\(Int((1 / t).rounded())) s")
        }
        if let i = iso { parts.append("ISO \(i)") }
        if let fl = focalLength { parts.append(Self.trim(fl) + " mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}

/// AUTOMATIC1111-style `parameters` text:
/// `<prompt>\nNegative prompt: <neg>\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Model: sdxl`.
public struct A1111Parameters: Sendable {
    public var prompt: String
    public var info: GeneratorInfo

    public init(raw: String) {
        var lines = raw.components(separatedBy: "\n")
        var settings = ""
        if let last = lines.last, last.contains("Steps:") {
            settings = last
            lines.removeLast()
        }
        var negative: String?
        if let i = lines.firstIndex(where: { $0.hasPrefix("Negative prompt:") }) {
            negative = lines[i...].joined(separator: "\n").replacingOccurrences(of: "Negative prompt:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines = Array(lines[..<i])
        }
        prompt = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var kv: [String: String] = [:]
        for part in settings.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { kv[pair[0]] = pair[1] }
        }
        info = GeneratorInfo(model: kv["Model"], steps: kv["Steps"].flatMap { Int($0) }, cfg: kv["CFG scale"].flatMap { Double($0) },
                             seed: kv["Seed"], sampler: kv["Sampler"], negativePrompt: negative, tool: "A1111")
    }
}

/// ComfyUI stores its graph as JSON in a `prompt` text chunk. The first
/// CLIPTextEncode node's text is taken as the prompt.
enum ComfyUIGraph {
    static func parse(_ json: String) -> (prompt: String?, info: GeneratorInfo) {
        var info = GeneratorInfo(tool: "ComfyUI")
        guard let data = json.data(using: .utf8),
              let graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, info) }
        var prompts: [(Int, String)] = []
        for (key, value) in graph {
            guard let node = value as? [String: Any], let cls = node["class_type"] as? String,
                  let inputs = node["inputs"] as? [String: Any] else { continue }
            if cls.hasPrefix("CLIPTextEncode"), let t = inputs["text"] as? String { prompts.append((Int(key) ?? 0, t)) }
            if cls.contains("KSampler") {
                info.steps = inputs["steps"] as? Int
                info.cfg = inputs["cfg"] as? Double ?? (inputs["cfg"] as? Int).map(Double.init)
                info.sampler = inputs["sampler_name"] as? String
                if let s = inputs["seed"] as? Int { info.seed = String(s) }
            }
            if cls.contains("CheckpointLoader"), let m = inputs["ckpt_name"] as? String { info.model = m }
        }
        prompts.sort { $0.0 < $1.0 }
        return (prompts.first?.1, info)
    }
}
