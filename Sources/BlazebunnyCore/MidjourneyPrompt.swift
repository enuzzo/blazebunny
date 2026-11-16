import Foundation

public struct PromptParameter: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
    /// `--name value`, or `--name` for flags without a value.
    public var rendered: String { value.isEmpty ? "--\(name)" : "--\(name) \(value)" }
}

/// A Midjourney `Description`: `<text> --param value … Job ID: <uuid>`.
///
/// Parameters start at the first whitespace-preceded `--` followed by a
/// letter. Each parameter takes every token up to the next such flag, so
/// multi-value parameters (`--sref 1 https://…`, `--no red, blue`) survive
/// intact. Everything before the first flag is the text, untouched.
public struct MidjourneyPrompt: Hashable, Sendable {
    public var text: String
    public var parameters: [PromptParameter]
    public var jobID: String?

    public init(text: String, parameters: [PromptParameter], jobID: String?) {
        self.text = text
        self.parameters = parameters
        self.jobID = jobID
    }

    public init(raw: String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        jobID = nil
        if let m = body.firstMatch(of: /\s*Job ID:\s*([0-9a-fA-F-]{8,})\s*$/) {
            jobID = String(m.1)
            body = String(body[..<m.range.lowerBound])
        }
        let flag = /(?:^|\s)--([A-Za-z][A-Za-z0-9_]*)/
        let matches = body.matches(of: flag)
        guard let first = matches.first else {
            text = body
            parameters = []
            return
        }
        text = String(body[..<first.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        var params: [PromptParameter] = []
        for (i, m) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].range.lowerBound : body.endIndex
            let value = String(body[m.range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            params.append(PromptParameter(name: String(m.1), value: value))
        }
        parameters = params
    }

    /// Text + parameters, without the Job ID: ready to paste into Midjourney.
    public var fullPrompt: String {
        parameters.isEmpty ? text : text + " " + parameterString
    }

    public var parameterString: String {
        parameters.map(\.rendered).joined(separator: " ")
    }

    /// The `--ar` value, if any.
    public var aspect: String? {
        parameters.last(where: { $0.name == "ar" || $0.name == "aspect" })?.value
    }
}

/// PNG `Creation Time` values, e.g. `Mon, 22 Dec 2025 22:04:32 GMT`.
public enum PNGDate {
    public static func parse(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}
