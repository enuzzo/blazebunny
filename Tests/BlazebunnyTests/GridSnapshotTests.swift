import Testing
import Foundation
@testable import Blazebunny
import BlazebunnyCore

@Suite("GridSnapshot")
struct GridSnapshotTests {
    /// Items a day apart from a fixed date, newest first, as the index returns them.
    func items(_ ids: [Int64], thumbnails: Bool = false) -> [BrowseItem] {
        ids.map { id in
            BrowseItem(id: id, relPath: "set/img\(id).png", sortDate: 1_700_000_000 - Double(id) * 86_400, width: 64, height: 48,
                       thumbnail: thumbnails ? ThumbnailLocation(pack: 0, offset: id * 10, length: 10) : nil, source: .midjourney, aspect: "4:3")
        }
    }

    @Test func sameItemsMakeNoNewSnapshot() throws {
        let first = try #require(GridSnapshot.make(items: items([1, 2, 3]), sectioned: true, view: 1, previous: GridSnapshot()))
        #expect(GridSnapshot.make(items: items([1, 2, 3]), sectioned: true, view: 1, previous: first) == nil)
    }

    @Test func thumbnailsArrivingKeepTheStructure() throws {
        let first = try #require(GridSnapshot.make(items: items([1, 2, 3]), sectioned: true, view: 1, previous: GridSnapshot()))
        let second = try #require(GridSnapshot.make(items: items([1, 2, 3], thumbnails: true), sectioned: true, view: 1, previous: first))
        // Only thumbnails changed: the grid refreshes cells in place and must not reload.
        #expect(second.structure == first.structure)
        #expect(second.revision == first.revision + 1)
        #expect(second.items[0].hasThumbnail)
    }

    @Test func aNewOrderOrANewItemChangesTheStructure() throws {
        let first = try #require(GridSnapshot.make(items: items([1, 2, 3]), sectioned: true, view: 1, previous: GridSnapshot()))
        let more = try #require(GridSnapshot.make(items: items([1, 2, 3, 4]), sectioned: true, view: 1, previous: first))
        #expect(more.structure == first.structure + 1)
        let reordered = try #require(GridSnapshot.make(items: items([3, 2, 1, 4]), sectioned: true, view: 1, previous: more))
        #expect(reordered.structure == more.structure + 1)
    }

    @Test func aNewViewIsANewStructureEvenWithTheSameItems() throws {
        let first = try #require(GridSnapshot.make(items: items([1, 2]), sectioned: true, view: 1, previous: GridSnapshot()))
        let other = try #require(GridSnapshot.make(items: items([1, 2]), sectioned: true, view: 2, previous: first))
        #expect(other.structure != first.structure)
        #expect(other.view == 2)
    }

    @Test func positionsAndIndexPathsAgreeAcrossMonths() throws {
        // 70 items a day apart span at least three months.
        let list = items(Array(1...70))
        let snap = try #require(GridSnapshot.make(items: list, sectioned: true, view: 1, previous: GridSnapshot()))
        #expect(snap.sections.count >= 3)
        #expect(snap.sections.map(\.range.count).reduce(0, +) == 70)
        for (i, item) in list.enumerated() {
            let path = try #require(snap.indexPath(ofID: item.id))
            #expect(snap.position(of: path) == i)
            #expect(snap.item(at: path)?.id == item.id)
        }
        #expect(snap.indexPath(ofID: 999) == nil)
        #expect(snap.item(at: IndexPath(item: 0, section: 99)) == nil)
    }

    @Test func unsectionedIsOneSection() throws {
        let snap = try #require(GridSnapshot.make(items: items([5, 1, 9]), sectioned: false, view: 1, previous: GridSnapshot()))
        #expect(snap.sections.count == 1)
        #expect(snap.indexPath(ofID: 9) == IndexPath(item: 2, section: 0))
    }

    @Test func clearingKeepsTheCountersMoving() throws {
        var snap = try #require(GridSnapshot.make(items: items([1]), sectioned: true, view: 1, previous: GridSnapshot()))
        let before = snap
        snap.clear()
        #expect(snap.items.isEmpty && snap.sections.isEmpty)
        #expect(snap.revision > before.revision && snap.structure > before.structure)
    }

    @Test func sourceCountsComeFromTheItems() throws {
        var list = items([1, 2, 3])
        list[2].source = .camera
        let snap = try #require(GridSnapshot.make(items: list, sectioned: true, view: 1, previous: GridSnapshot()))
        #expect(snap.sourceCounts() == [.midjourney: 2, .camera: 1])
    }
}
