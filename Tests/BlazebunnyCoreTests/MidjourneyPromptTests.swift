import Foundation
import Testing
@testable import BlazebunnyCore

struct MidjourneyPromptTests {
    let job = "0f8e1c2a-1111-4222-8333-944455556666"

    @Test func splitsTextParametersAndJobID() {
        let p = MidjourneyPrompt(raw: "a cat in the rain, neon light --ar 16:9 --v 7 Job ID: \(job)")
        #expect(p.text == "a cat in the rain, neon light")
        #expect(p.parameters == [.init(name: "ar", value: "16:9"), .init(name: "v", value: "7")])
        #expect(p.jobID == job)
        #expect(p.aspect == "16:9")
        #expect(p.fullPrompt == "a cat in the rain, neon light --ar 16:9 --v 7")
        #expect(p.parameterString == "--ar 16:9 --v 7")
    }

    @Test func flagWithoutValue() {
        let p = MidjourneyPrompt(raw: "a dog --raw --stylize 250 --hd Job ID: \(job)")
        #expect(p.parameters == [.init(name: "raw", value: ""), .init(name: "stylize", value: "250"), .init(name: "hd", value: "")])
        #expect(p.fullPrompt == "a dog --raw --stylize 250 --hd")
    }

    @Test func multiValueParameters() {
        let p = MidjourneyPrompt(raw: "portrait --sref 12345 https://x.test/a.png --no red, blue --v 6.1")
        #expect(p.parameters == [
            .init(name: "sref", value: "12345 https://x.test/a.png"),
            .init(name: "no", value: "red, blue"),
            .init(name: "v", value: "6.1"),
        ])
        #expect(p.jobID == nil)
    }

    @Test func leadingImageURLAndWeightsStayInText() {
        let p = MidjourneyPrompt(raw: "https://x.test/i.png a dog::2 a hat::-0.5 {red, blue} --v 6 Job ID: \(job)")
        #expect(p.text == "https://x.test/i.png a dog::2 a hat::-0.5 {red, blue}")
        #expect(p.parameters == [.init(name: "v", value: "6")])
    }

    @Test func noParameters() {
        let p = MidjourneyPrompt(raw: "just words")
        #expect(p.text == "just words")
        #expect(p.parameters.isEmpty)
        #expect(p.aspect == nil)
        #expect(p.fullPrompt == "just words")
        #expect(p.parameterString == "")
    }

    @Test func hyphenatedWordsAreNotFlags() {
        let p = MidjourneyPrompt(raw: "a well-lit room -- quiet --ar 3:2")
        #expect(p.text == "a well-lit room -- quiet")
        #expect(p.parameters == [.init(name: "ar", value: "3:2")])
    }

    @Test func parsesPNGDate() {
        let d = PNGDate.parse("Mon, 22 Dec 2025 22:04:32 GMT")
        #expect(d == Date(timeIntervalSince1970: 1_766_441_072))
        #expect(PNGDate.parse("not a date") == nil)
    }
}
