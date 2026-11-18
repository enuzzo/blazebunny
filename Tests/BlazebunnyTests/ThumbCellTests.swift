import Testing
import AppKit
@testable import Blazebunny
import BlazebunnyCore

/// The grid cell's placeholder: where the colours go, and that the image takes their place.
@Suite("ThumbCell") @MainActor
struct ThumbCellTests {
    func makeCell(side: CGFloat = 200) -> ThumbCell {
        let cell = ThumbCell()
        cell.view.frame = NSRect(x: 0, y: 0, width: side, height: side)
        cell.view.layoutSubtreeIfNeeded()
        cell.layoutImage(in: cell.view.bounds)
        return cell
    }

    func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        return context.makeImage()!
    }

    let colours = ThumbnailPlaceholder(samples: Array(repeating: (40, 90, 200), count: 16))

    @Test func coloursFillTheCellShowingTheirMiddleWhenThePictureFillsIt() {
        let cell = makeCell()
        cell.fill = true
        cell.aspect = 2   // twice as wide as high: the cell shows the middle half
        cell.showPlaceholder(colours)
        let area = try! #require(cell.placeholderArea)
        #expect(area.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(area.part == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        cell.aspect = 0.5  // twice as high as wide
        #expect(cell.placeholderArea?.part == CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
    }

    @Test func coloursTakeThePictureShapeWhenItFits() {
        let cell = makeCell()
        cell.fill = false
        cell.aspect = 2
        cell.showPlaceholder(colours)
        #expect(cell.placeholderArea?.frame == CGRect(x: 0, y: 50, width: 200, height: 100))
        #expect(cell.placeholderArea?.part == CGRect(x: 0, y: 0, width: 1, height: 1))
        cell.aspect = 0.5
        #expect(cell.placeholderArea?.frame == CGRect(x: 50, y: 0, width: 100, height: 200))
        // Back to Fill while the colours are still showing: they follow.
        cell.fill = true
        #expect(cell.placeholderArea?.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        // A picture of unknown shape: the whole cell, all the samples.
        cell.aspect = nil
        cell.fill = false
        #expect(cell.placeholderArea?.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(cell.placeholderArea?.part == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func theImageTakesThePlaceOfTheColoursAndReuseLeavesNothingBehind() {
        let cell = makeCell()
        #expect(cell.isEmpty && cell.placeholderArea == nil && cell.shownDetail == nil)
        cell.showPlaceholder(colours)
        #expect(cell.isEmpty && cell.placeholderArea != nil)          // colours are not a thumbnail: the cell still wants one
        cell.show(image(256, 256), detail: .small)
        #expect(!cell.isEmpty && cell.placeholderArea == nil && cell.shownDetail == .small)
        cell.show(image(512, 512), detail: .full)
        #expect(cell.shownDetail == .full)
        // With a fade the colours stay underneath until it ends.
        cell.showPlaceholder(colours)
        cell.show(image(512, 512), detail: .full, fade: true)
        #expect(!cell.isEmpty && cell.placeholderArea != nil)
        cell.prepareForReuse()
        #expect(cell.isEmpty && cell.placeholderArea == nil && cell.shownDetail == nil && cell.aspect == nil)
        // No colours known: nothing is drawn, and nothing breaks.
        cell.showPlaceholder(nil)
        #expect(cell.placeholderArea == nil)
    }
}
