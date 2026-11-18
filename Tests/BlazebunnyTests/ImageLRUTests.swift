import Testing
import CoreGraphics
@testable import Blazebunny

@Suite("ImageLRU")
struct ImageLRUTests {
    /// A blank image of `side` x `side` pixels: side * side * 4 bytes.
    func image(_ side: Int) -> CGImage {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @Test func keepsEverythingUnderTheLimit() {
        var cache = ImageLRU(limit: 10 * 100 * 100 * 4)
        for id in 1...10 { cache[Int64(id)] = image(100) }
        #expect(cache.count == 10 && cache.bytes == 10 * 40_000)
        for id in 1...10 { #expect(cache[Int64(id)] != nil) }
    }

    @Test func dropsTheLeastRecentlyUsedFirst() {
        var cache = ImageLRU(limit: 3 * 40_000)
        for id in 1...3 { cache[Int64(id)] = image(100) }
        _ = cache[1]                 // 1 was just looked at: 2 is now the oldest
        cache[4] = image(100)
        #expect(cache[2] == nil)
        #expect(cache[1] != nil && cache[3] != nil && cache[4] != nil)
        #expect(cache.bytes == 3 * 40_000)
    }

    @Test func replacingAnImageCountsItOnce() {
        var cache = ImageLRU(limit: 1_000_000)
        cache[1] = image(100)
        cache[1] = image(50)
        #expect(cache.count == 1 && cache.bytes == 10_000)
        cache[1] = nil
        #expect(cache.count == 0 && cache.bytes == 0)
    }

    @Test func anImageLargerThanTheLimitIsStillKept() {
        var cache = ImageLRU(limit: 1_000)
        cache[1] = image(10)
        cache[2] = image(100)        // far over the limit on its own
        #expect(cache[2] != nil && cache[1] == nil)
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0 && cache[2] == nil)
    }
}
