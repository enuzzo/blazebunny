import AppKit
import SwiftUI
import BlazebunnyCore

/// The thumbnail grid: an AppKit NSCollectionView, which only creates the
/// cells on screen and scrolls smoothly over tens of thousands of items.
/// Sorted by date, it is split into months with headers pinned while scrolling.
struct GridView: NSViewRepresentable {
    let model: LibraryModel
    /// The grid's data is `model.grid`; only its revision is passed, so SwiftUI compares one number
    /// to know whether the grid changed, not a hundred thousand items.
    let revision: Int
    let cellSize: Double
    let fill: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = JustifiedFlowLayout()
        layout.targetSize = cellSize
        layout.minimumInteritemSpacing = DS.Space.s
        layout.minimumLineSpacing = DS.Space.s
        layout.sectionInset = layout.margins
        layout.itemSize = NSSize(width: cellSize, height: cellSize)
        layout.sectionHeadersPinToVisibleBounds = true

        let cv = GridCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.backgroundColors = [.clear]
        cv.register(ThumbCell.self, forItemWithIdentifier: ThumbCell.identifier)
        cv.register(MonthHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                     withIdentifier: MonthHeader.identifier)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.model = model
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.collectionView = cv
        context.coordinator.fill = fill
        GridStats.collectionView = cv
        model.thumbnails.onAvailable = { [weak coordinator = context.coordinator] ids in coordinator?.refresh(ids: ids) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let cv = c.collectionView, let layout = c.layout else { return }
        let snapshot = model.grid
        let headerHeight = snapshot.sectioned ? DS.Size.monthHeader : DS.Space.m
        if layout.headerReferenceSize.height != headerHeight { layout.headerReferenceSize = NSSize(width: 0, height: headerHeight) }
        c.setFill(fill)
        if c.snapshot.revision != snapshot.revision {
            let interval = Perf.begin("grid.apply")
            let structural = c.snapshot.structure != snapshot.structure
            let newView = c.snapshot.view != snapshot.view
            c.snapshot = snapshot
            if structural {
                GridStats.reloads += 1
                cv.reloadData()
                if newView { c.scrollToTop() }
                c.restoreSelection()
            } else {
                c.refreshVisible()
            }
            c.prioritizeVisible()
            GridStats.applyMs += interval.end()
            // Again once the new rows are laid out: right after a reload the grid does not know yet
            // which cells are on screen, and a first scan then made the thumbnails nobody was looking
            // at for several seconds (measured on 12 000 files: first thumbnail on screen after 7 s).
            DispatchQueue.main.async { [weak c] in
                MainActor.assumeIsolated {
                    c?.prioritizeVisible()
                    Perf.launchMark("gridDisplayed")
                }
            }
        }
        // After the data, so a new library is laid out at the new size without a glide.
        c.setTargetSize(cellSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: LibraryModel
        var snapshot = GridSnapshot()
        var fill = true
        weak var collectionView: NSCollectionView?
        var layout: JustifiedFlowLayout? { collectionView?.collectionViewLayout as? JustifiedFlowLayout }
        private var prioritizeScheduled = false
        /// Fires when the grid's width has stopped changing (a side panel finished sliding).
        private var widthSettle: DispatchWorkItem?
        /// A thumbnail size chosen while the previous step was still gliding.
        private var pendingTargetSize: CGFloat?
        private var sizeStepInFlight = false
        /// Where and when the grid last scrolled, to tell a fast scroll from a slow one.
        private var lastScrollY: CGFloat = 0
        private var lastScrollAt: UInt64 = 0
        private var fastScrollUntil: UInt64 = 0

        init(model: LibraryModel) { self.model = model }

        // MARK: Data source

        func numberOfSections(in cv: NSCollectionView) -> Int { snapshot.sections.count }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            snapshot.sections[section].range.count
        }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: ThumbCell.identifier, for: indexPath) as! ThumbCell
            if let item = snapshot.item(at: indexPath) { configure(cell, item: item) }
            return cell
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at indexPath: IndexPath) -> NSView {
            let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: MonthHeader.identifier, for: indexPath) as! MonthHeader
            let section = snapshot.sections[indexPath.section]
            v.set(title: snapshot.sectioned ? section.title : "", count: snapshot.sectioned ? section.range.count : nil)
            return v
        }

        func collectionView(_ cv: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            guard let cell = item as? ThumbCell else { return }
            // Off screen: its thumbnail is no longer needed, so the ones on screen come first.
            model.thumbnails.cancel(cell.loadToken)
            cell.loadToken = nil
        }

        func configure(_ cell: ThumbCell, item: BrowseItem) {
            let thumbnails = model.thumbnails
            thumbnails.cancel(cell.loadToken)
            cell.loadToken = nil
            // The same item asked again while its cell is still empty (its thumbnail has just been
            // made by the scan): the wait began when the cell first showed it, not now.
            if cell.itemID != item.id || !cell.isEmpty { cell.waitingSince = Perf.now() }
            cell.itemID = item.id
            cell.fill = fill
            cell.aspect = Self.aspect(of: item)
            cell.describe(name: item.fileName, source: item.source)
            let detail = neededDetail(for: item)
            if let image = thumbnails.best(item.id), image.detail >= detail {
                cell.show(image.image, detail: image.detail)
                GridStats.cellsShownFromCache += 1
                return
            }
            // A smaller decode of the same thumbnail is closer than its colours; with neither, the
            // colours stand in while the thumbnail is read.
            var waitsOnColours = false
            if let lesser = thumbnails.best(item.id) {
                cell.show(lesser.image, detail: lesser.detail)
            } else {
                cell.show(nil)
                let placeholder = thumbnails.placeholder(for: item.id)
                cell.showPlaceholder(placeholder)
                waitsOnColours = true
                if placeholder != nil { GridStats.placeholdersShown += 1 }
            }
            guard let location = thumbnails.location(for: item) else { return }
            let id = item.id
            cell.askedAt = Perf.now()
            cell.loadToken = thumbnails.load(id, at: location, detail: detail) { [weak cell, weak self] image in
                guard let cell, cell.itemID == id else { return }
                cell.loadToken = nil
                guard let image else { return }
                let fade = waitsOnColours && (self?.shouldFade(since: cell.waitingSince) ?? false)
                cell.show(image, detail: detail, fade: fade)
                if fade { GridStats.fades += 1 }
                if Perf.isLogging { self?.noteThumbnailShown(cell) }
            }
        }

        private static func aspect(of item: BrowseItem) -> CGFloat? {
            guard let w = item.width, let h = item.height, w > 0, h > 0 else { return nil }
            return CGFloat(w) / CGFloat(h)
        }

        /// How much of the stored thumbnail this item's cell can show: the cell's side in pixels,
        /// times the picture's long side over its short one when the picture fills the cell.
        func neededDetail(for item: BrowseItem) -> ThumbnailLoader.Detail {
            guard let layout, let cv = collectionView, !Perf.wholeThumbnailsOnly else { return .full }
            var pixels = layout.itemSize.width * (cv.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            if fill {
                // A picture of unknown shape may be much wider than the cell: do not guess.
                guard let aspect = Self.aspect(of: item) else { return .full }
                pixels *= max(aspect, 1 / aspect)
            }
            return .needed(forPixels: pixels)
        }

        /// A thumbnail that arrives late fades in over its colours; one that is there within a few
        /// frames just appears, and nothing fades while the grid scrolls fast or with Reduce Motion.
        private func shouldFade(since waiting: UInt64) -> Bool {
            Perf.ms(since: waiting) >= DS.Motion.thumbnailFadeAfter * 1000 && !isScrollingFast && !Self.reduceMotion
                && collectionView?.window != nil
        }

        /// Cells that show a half-size decode which the new cell size or mode would enlarge get the whole thumbnail.
        func upgradeVisible() {
            guard let cv = collectionView else { return }
            for case let cell as ThumbCell in cv.visibleItems() where cell.shownDetail == .small {
                if let path = cv.indexPath(for: cell), let item = snapshot.item(at: path), item.id == cell.itemID,
                   neededDetail(for: item) > .small { configure(cell, item: item) }
            }
        }

        private func noteThumbnailShown(_ cell: ThumbCell) {
            GridStats.thumbnailWaits.append(Perf.ms(since: cell.askedAt))
            Perf.launchMark("firstThumbnail")
            if let cv = collectionView, cv.visibleItems().allSatisfy({ !(($0 as? ThumbCell)?.isEmpty ?? true) }) {
                Perf.launchMark("visibleThumbnails")
            }
        }

        // MARK: Selection

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }

        private func syncSelection(_ cv: NSCollectionView) {
            model.selection = cv.selectionIndexPaths.sorted().compactMap { snapshot.item(at: $0)?.id }
        }

        func restoreSelection() {
            guard let cv = collectionView else { return }
            let paths = Set(model.selection.compactMap { snapshot.indexPath(ofID: $0) })
            cv.selectionIndexPaths = paths
            if paths.count != model.selection.count { syncSelection(cv) }
        }

        // Drag out the original files (only when the folder is online).
        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard model.isOnline, let item = snapshot.item(at: indexPath), let url = model.originalURL(item.relPath) else { return nil }
            return url as NSURL
        }

        // MARK: Thumbnails arriving

        /// The scan made thumbnails for `ids`: show the ones on screen. Nothing else is reloaded.
        func refresh(ids: Set<Int64>) {
            guard let cv = collectionView else { return }
            for case let cell as ThumbCell in cv.visibleItems() where cell.isEmpty && ids.contains(cell.itemID) {
                if let path = cv.indexPath(for: cell), let item = snapshot.item(at: path), item.id == cell.itemID { configure(cell, item: item) }
            }
        }

        /// The items were read again in the same order: fill the cells that were still empty.
        func refreshVisible() {
            guard let cv = collectionView else { return }
            for case let cell as ThumbCell in cv.visibleItems() where cell.isEmpty {
                if let path = cv.indexPath(for: cell), let item = snapshot.item(at: path) { configure(cell, item: item) }
            }
        }

        /// Scrolling faster than `DS.Motion.fastScroll`, now or a moment ago.
        var isScrollingFast: Bool { Perf.now() < fastScrollUntil }

        private func noteScroll() {
            guard let clip = collectionView?.enclosingScrollView?.contentView else { return }
            let now = Perf.now()
            let y = clip.bounds.origin.y
            let seconds = Double(now &- lastScrollAt) / 1e9
            // Two positions further apart in time than the hold say nothing about the speed now.
            if lastScrollAt != 0, seconds > 0, seconds < DS.Motion.fastScrollHold, abs(y - lastScrollY) / seconds > DS.Motion.fastScroll {
                fastScrollUntil = now + UInt64(DS.Motion.fastScrollHold * 1e9)
            }
            lastScrollY = y
            lastScrollAt = now
        }

        @objc func boundsChanged() {
            noteScroll()
            // Only a running scan cares what is on screen (it makes those thumbnails first).
            guard model.thumbnails.scanner != nil, !prioritizeScheduled else { return }
            prioritizeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    self?.prioritizeScheduled = false
                    self?.prioritizeVisible()
                }
            }
        }

        func prioritizeVisible() {
            guard model.thumbnails.scanner != nil, let cv = collectionView else { return }
            let visible = cv.indexPathsForVisibleItems().compactMap { snapshot.position(of: $0) }
            guard let first = visible.min(), let last = visible.max() else { return }
            // Visible items plus about one screen below.
            let end = min(snapshot.items.count, last + 1 + (last - first + 1))
            let ids = snapshot.items[first..<end].filter { !$0.hasThumbnail }.map(\.id)
            model.thumbnails.prioritize(ids)
        }

        func scrollToTop() {
            guard let scroll = collectionView?.enclosingScrollView else { return }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // MARK: Reflow

        /// The grid's width changed. Dragging the window edge reflows at once (it is the user's own
        /// movement). A side panel sliding in or out changes the width on every frame of its
        /// animation: the rows then stay as they are and the grid reflows once, with a glide, when
        /// the width has rested for a moment.
        @objc func frameChanged() {
            guard let cv = collectionView, let layout else { return }
            let width = layout.visibleWidth(cv)
            widthSettle?.cancel()
            guard abs(width - layout.layoutWidth) > 0.5 else { return }
            if layout.layoutWidth <= 0 || snapshot.items.isEmpty || cv.window == nil || cv.window?.inLiveResize == true {
                layout.layoutWidth = width
                layout.invalidateLayout()
                return
            }
            let settle = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let cv = self.collectionView else { return }
                    self.reflow { $0.layoutWidth = $0.visibleWidth(cv) }
                }
            }
            widthSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.reflowSettle, execute: settle)
        }

        /// The thumbnail size slider. Each step glides; while one is gliding the latest value waits,
        /// so dragging the slider reflows a few times a second instead of on every tick.
        func setTargetSize(_ size: CGFloat) {
            guard let layout, layout.targetSize != size || pendingTargetSize != nil else { return }
            if snapshot.items.isEmpty || layout.layoutWidth <= 0 || Self.reduceMotion {
                pendingTargetSize = nil
                guard layout.targetSize != size else { return }
                reflow(animated: false) { $0.targetSize = size }
                return
            }
            pendingTargetSize = size
            if !sizeStepInFlight { applyPendingTargetSize() }
        }

        private func applyPendingTargetSize() {
            guard let size = pendingTargetSize else { return }
            pendingTargetSize = nil
            guard layout?.targetSize != size else { return }
            sizeStepInFlight = true
            reflow { $0.targetSize = size }
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.reflowStep) { [weak self] in
                MainActor.assumeIsolated {
                    self?.sizeStepInFlight = false
                    self?.applyPendingTargetSize()
                }
            }
        }

        func setFill(_ newValue: Bool) {
            guard fill != newValue, let cv = collectionView else { return }
            fill = newValue
            for case let cell as ThumbCell in cv.visibleItems() { cell.setFill(newValue, animated: !Self.reduceMotion) }
            upgradeVisible()
        }

        private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// Applies a layout change in one pass and lets the cells on screen glide from where they
        /// were to where they belong (first, last, invert, play: each cell is laid out at its new
        /// place and a transform animation starts it from its old one). The image at the top left
        /// stays put, so the same pictures are on screen before and after. Cells that were not on
        /// screen fade in; nothing else is animated, and nothing is with Reduce Motion.
        func reflow(animated: Bool = true, _ change: (JustifiedFlowLayout) -> Void) {
            guard let cv = collectionView, let layout, let scroll = cv.enclosingScrollView else { return }
            let interval = Perf.begin("grid.reflow")
            // Larger cells may need the whole thumbnail where half of it was enough.
            defer { interval.end(); upgradeVisible() }
            let clip = scroll.contentView
            let animate = animated && !Self.reduceMotion && cv.window != nil
            let visible = clip.documentVisibleRect

            // First: where each cell on screen is, relative to the visible area, and the item to keep in place.
            var before: [Int64: NSRect] = [:]
            var anchor: (position: Int, id: Int64, offset: CGFloat)?
            for case let cell as ThumbCell in cv.visibleItems() where cell.itemID >= 0 {
                let frame = cell.view.frame
                guard frame.intersects(visible) else { continue }
                // A cell that is still gliding starts the next glide from where it is now.
                let shown = cell.view.layer?.presentation()?.frame ?? frame
                before[cell.itemID] = shown.offsetBy(dx: -visible.minX, dy: -visible.minY)
                guard frame.minY >= visible.minY - 1, let position = snapshot.position(ofID: cell.itemID) else { continue }
                if anchor == nil || position < anchor!.position { anchor = (position, cell.itemID, frame.minY - visible.minY) }
            }

            // Last: the new layout, without animation, scrolled so the anchor keeps its place.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                change(layout)
                layout.invalidateLayout()
                cv.layoutSubtreeIfNeeded()
                if let anchor, visible.minY > 0, let path = snapshot.indexPath(ofID: anchor.id),
                   let frame = cv.layoutAttributesForItem(at: path)?.frame {
                    let bottom = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
                    let y = min(bottom, max(0, frame.minY - anchor.offset))
                    if abs(y - clip.bounds.origin.y) > 0.5 {
                        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                        scroll.reflectScrolledClipView(clip)
                        cv.layoutSubtreeIfNeeded()
                    }
                }
            }
            guard animate else { return }

            // Invert and play.
            let now = clip.documentVisibleRect
            let timing = CAMediaTimingFunction(name: .easeOut)
            for case let cell as ThumbCell in cv.visibleItems() {
                guard let layer = cell.view.layer else { continue }
                let new = cell.view.frame
                guard new.width > 0, new.height > 0 else { continue }
                layer.removeAnimation(forKey: "reflow")
                guard let was = before[cell.itemID] else {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = DS.Motion.reflowDuration
                    fade.timingFunction = timing
                    layer.add(fade, forKey: "reflow")
                    continue
                }
                let old = was.offsetBy(dx: now.minX, dy: now.minY)
                guard abs(old.minX - new.minX) > 0.5 || abs(old.minY - new.minY) > 0.5 || abs(old.width - new.width) > 0.5 else { continue }
                let sx = old.width / new.width, sy = old.height / new.height
                // The layer scales around its anchor point, so the shift accounts for it.
                let tx = old.minX - new.minX + (sx - 1) * layer.anchorPoint.x * new.width
                let ty = old.minY - new.minY + (sy - 1) * layer.anchorPoint.y * new.height
                let glide = CABasicAnimation(keyPath: "transform")
                glide.fromValue = CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1), CATransform3DMakeTranslation(tx, ty, 0))
                glide.toValue = CATransform3DIdentity
                glide.duration = DS.Motion.reflowDuration
                glide.timingFunction = timing
                layer.add(glide, forKey: "reflow")
            }
        }
    }
}

/// Collection view that copies the selected prompts with ⌘C, opens with Return.
final class GridCollectionView: NSCollectionView {
    weak var model: LibraryModel?

    @objc func copy(_ sender: Any?) { model?.copy(.prompt) }

    // Thumbnails are decoded into the window's colour space (it changes with the display).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        noteColorSpace()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        noteColorSpace()
    }

    private func noteColorSpace() {
        guard let space = window?.colorSpace?.cgColorSpace else { return }
        model?.thumbnails.displayColorSpace = space
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { model?.openOriginal(); return }  // Return
        if event.keyCode == 53, !selectionIndexPaths.isEmpty {  // Esc: back to the library summary
            selectionIndexPaths = []
            model?.selection = []
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        // Groups, in the order people reach for them: copy, then open and locate.
        let menu = NSMenu()
        func add(_ action: AppAction, _ selector: Selector, key: String = "") {
            let item = menu.addItem(withTitle: action.title, action: selector, keyEquivalent: key)
            item.target = self
            item.image = action.nsImage
        }
        add(.copyPrompt, #selector(copyPrompt), key: "c")
        add(.copyText, #selector(copyText))
        add(.copyParameters, #selector(copyParams))
        add(.copyPath, #selector(copyPath))
        menu.addItem(.separator())
        add(.showInFinder, #selector(reveal))
        add(.openDefault, #selector(openOriginal))
        // Add to Tray / Compare / Collection join here when those features exist.
        return menu
    }

    @objc func copyPrompt() { model?.copy(.prompt) }
    @objc func copyText() { model?.copy(.text) }
    @objc func copyParams() { model?.copy(.parameters) }
    @objc func copyPath() { model?.copyPath() }
    @objc func reveal() { model?.revealInFinder() }
    @objc func openOriginal() { model?.openOriginal() }
}
