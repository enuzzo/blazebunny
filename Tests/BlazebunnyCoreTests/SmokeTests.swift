import Testing
@testable import BlazebunnyCore

@Test func versionIsSet() {
    #expect(!Blazebunny.version.isEmpty)
}
