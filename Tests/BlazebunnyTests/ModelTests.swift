import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Blazebunny
import BlazebunnyCore

@Suite("LibraryModel", .serialized) @MainActor
struct ModelTests {
    /// A folder of small generated PNGs. Nothing real.
    func makeFolder(count: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bb-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = context.makeImage()!
        for i in 0..<count {
            let url = folder.appendingPathComponent(i % 2 == 0 ? "img\(i).png" : "sub/img\(i).png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return folder
    }

    func wait(_ what: String, timeout: Double = 20, until done: () -> Bool) async throws {
        let start = Date()
        while !done() {
            if Date().timeIntervalSince(start) > timeout { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Every file under `folder` with its size and modification date: the folder must come out as it went in.
    func listing(_ folder: URL) -> [String] {
        let fm = FileManager.default
        return (fm.subpaths(atPath: folder.path) ?? []).sorted().map { path in
            let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(path).path)
            return "\(path) \(attrs?[.size] ?? 0) \(attrs?[.modificationDate] ?? "")"
        }
    }

    @Test func aGhostIsScannedShownAndLeavesNothingBehind() async throws {
        let folder = try makeFolder(count: 6)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = listing(folder)
        let model = LibraryModel()
        let savedBefore = model.saved

        model.open(folder, ghost: true)
        let ghost = try #require(model.ghosts.first { $0.path == folder.standardizedFileURL.path })
        let base = try #require(ghost.ghostBase)
        #expect(model.currentIsGhost)
        #expect(model.saved == savedBefore)   // a ghost is never among the saved libraries

        try await wait("the scan") { model.scanFinished && model.grid.items.count == 6 && !model.isPartialPage }
        #expect(model.counts.total == 6)
        #expect(model.contentState == .grid)
        #expect(model.folderTree.nodes["sub"]?.subtreeCount == 3)
        // Everything it stored is under its own temporary directory.
        #expect(FileManager.default.fileExists(atPath: base.path))
        try await wait("thumbnails in the items") { model.grid.items.allSatisfy(\.hasThumbnail) }

        // Selecting shows the detail; a folder scope narrows the grid; the library shows all again.
        model.selection = [model.grid.items[0].id]
        #expect(model.detail?.id == model.grid.items[0].id)
        model.selectSidebar(.folder("sub"))
        #expect(model.selection.isEmpty)
        try await wait("the folder") { model.grid.items.count == 3 && !model.isPartialPage }
        model.selectSidebar(.library(ghost.path))
        try await wait("the library") { model.grid.items.count == 6 }

        model.closeGhost(ghost)
        #expect(model.ghosts.isEmpty && model.library == nil && model.grid.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        #expect(model.saved == savedBefore)
        #expect(listing(folder) == before)   // the scanned folder is exactly as it was
    }

    @Test func aScanThatOnlyMakesThumbnailsDoesNotReloadTheGrid() async throws {
        let folder = try makeFolder(count: 40)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LibraryModel()
        model.open(folder, ghost: true)
        let ghost = try #require(model.ghosts.first)
        defer { model.closeGhost(ghost) }
        try await wait("the scan") { model.scanFinished && model.grid.items.count == 40 && model.grid.items.allSatisfy(\.hasThumbnail) }
        // Every reload that changed the order or the items is a full grid reload. A scan of 40 files
        // lists once and reads metadata in one batch: the thumbnails that follow must not add reloads.
        #expect(model.grid.structure <= 4)
    }
}
