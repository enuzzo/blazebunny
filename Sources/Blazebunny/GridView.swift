import AppKit
import SwiftUI
import BlazebunnyCore

/// The thumbnail grid: an AppKit NSCollectionView, which only creates the
/// cells on screen and scrolls smoothly over tens of thousands of items.
/// Sorted by date, it is split into months with headers pinned while scrolling.
struct GridView: NSViewRepresentable {
    let model: LibraryModel
    let items: [BrowseItem]
    let cellSize: Double
    let fill: Bool
    let sections: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = JustifiedFlowLayout()
        layout.targetSize = cellSize
        layout.minimumInteritemSpacing = DS.Space.s
        layout.minimumLineSpacing = DS.Space.s
        layout.sectionInset = NSEdgeInsets(top: 0, left: DS.Space.l, bottom: DS.Space.l, right: DS.Space.l)
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
        model.thumbnails.onAvailable = { [weak coordinator = context.coordinator] ids in coordinator?.refresh(ids: ids) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let cv = c.collectionView, let layout = cv.collectionViewLayout as? JustifiedFlowLayout else { return }
        if layout.targetSize != cellSize { layout.targetSize = cellSize; layout.invalidateLayout() }
        let headerHeight: CGFloat = sections ? 40 : 12
        if layout.headerReferenceSize.height != headerHeight { layout.headerReferenceSize = NSSize(width: 0, height: headerHeight) }
        if c.fill != fill {
            c.fill = fill
            for case let cell as ThumbCell in cv.visibleItems() { cell.fill = fill }
        }
        if c.items != items || c.sectioned != sections {
            let sameOrder = c.sectioned == sections && c.items.map(\.id) == items.map(\.id)
            c.setItems(items, sections: sections)
            if sameOrder {
                c.refreshVisible()
            } else {
                cv.reloadData()
                c.restoreSelection()
            }
            c.prioritizeVisible()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: LibraryModel
        var items: [BrowseItem] = []
        var fill = true
        var sectioned = true
        /// Sections: title and range into `items`.
        var sections: [(title: String, range: Range<Int>)] = []
        var pathByID: [Int64: IndexPath] = [:]
        weak var collectionView: NSCollectionView?
        private var prioritizeScheduled = false

        init(model: LibraryModel) { self.model = model }

        static let monthFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f }()

        func setItems(_ new: [BrowseItem], sections split: Bool) {
            items = new
            sectioned = split
            sections = []
            func title(_ i: Int) -> String { Self.monthFormatter.string(from: Date(timeIntervalSince1970: new[i].sortDate)) }
            if split {
                var start = 0
                var currentKey = -1
                let cal = Calendar.current
                for (i, it) in new.enumerated() {
                    let d = Date(timeIntervalSince1970: it.sortDate)
                    let key = cal.component(.year, from: d) * 100 + cal.component(.month, from: d)
                    if key != currentKey {
                        if i > start { sections.append((title(start), start..<i)) }
                        start = i
                        currentKey = key
                    }
                }
                if start < new.count { sections.append((title(start), start..<new.count)) }
            } else if !new.isEmpty {
                sections = [("", 0..<new.count)]
            }
            pathByID = [:]
            for (s, sec) in sections.enumerated() {
                for i in sec.range { pathByID[new[i].id] = IndexPath(item: i - sec.range.lowerBound, section: s) }
            }
        }

        func item(at p: IndexPath) -> BrowseItem? {
            guard p.section < sections.count else { return nil }
            let i = sections[p.section].range.lowerBound + p.item
            return i < items.count ? items[i] : nil
        }

        func numberOfSections(in cv: NSCollectionView) -> Int { sections.count }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].range.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: ThumbCell.identifier, for: indexPath) as! ThumbCell
            if let it = item(at: indexPath) { configure(cell, item: it) }
            return cell
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at indexPath: IndexPath) -> NSView {
            let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: MonthHeader.identifier, for: indexPath) as! MonthHeader
            let sec = sections[indexPath.section]
            v.set(title: sectioned ? sec.title : "", count: sectioned ? sec.range.count : nil)
            return v
        }

        func configure(_ cell: ThumbCell, item: BrowseItem) {
            cell.itemID = item.id
            cell.fill = fill
            cell.setSource(item.source)
            cell.view.toolTip = (item.relPath as NSString).lastPathComponent
            if let img = model.thumbnails.cached(item.id) {
                cell.show(img)
                return
            }
            cell.show(nil)
            guard item.hasThumbnail else { model.thumbnails.markMissing(item.id); return }
            model.thumbnails.load(item.id) { [weak cell] img in
                guard let cell, cell.itemID == item.id else { return }
                cell.show(img)
            }
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }

        private func syncSelection(_ cv: NSCollectionView) {
            model.selection = cv.selectionIndexPaths.sorted().compactMap { item(at: $0)?.id }
        }

        func restoreSelection() {
            guard let cv = collectionView else { return }
            let paths = Set(model.selection.compactMap { pathByID[$0] })
            cv.selectionIndexPaths = paths
            if paths.count != model.selection.count { syncSelection(cv) }
        }

        // Drag out the original files (only when the folder is online).
        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard model.isOnline, let it = item(at: indexPath), let url = model.originalURL(it.relPath) else { return nil }
            return url as NSURL
        }

        func refresh(ids: Set<Int64>) {
            guard let cv = collectionView else { return }
            for case let cell as ThumbCell in cv.visibleItems() where ids.contains(cell.itemID) {
                if let p = pathByID[cell.itemID], let it = item(at: p) { configure(cell, item: it) }
            }
        }

        func refreshVisible() {
            guard let cv = collectionView else { return }
            for case let cell as ThumbCell in cv.visibleItems() where cell.isEmpty {
                if let p = pathByID[cell.itemID], let it = item(at: p) { configure(cell, item: it) }
            }
        }

        @objc func frameChanged() {
            collectionView?.collectionViewLayout?.invalidateLayout()
        }

        @objc func boundsChanged() {
            guard !prioritizeScheduled else { return }
            prioritizeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    self?.prioritizeScheduled = false
                    self?.prioritizeVisible()
                }
            }
        }

        func prioritizeVisible() {
            guard let cv = collectionView else { return }
            let visible = cv.indexPathsForVisibleItems().compactMap { p -> Int? in
                guard p.section < sections.count else { return nil }
                return sections[p.section].range.lowerBound + p.item
            }.sorted()
            guard let first = visible.first, let last = visible.last else { return }
            // Visible items plus about one screen below.
            let end = min(items.count, last + 1 + (last - first + 1))
            let ids = items[first..<end].filter { !$0.hasThumbnail }.map(\.id)
            model.thumbnails.prioritize(ids)
        }
    }
}

/// Collection view that copies the selected prompts with ⌘C, opens with Return.
final class GridCollectionView: NSCollectionView {
    weak var model: LibraryModel?

    @objc func copy(_ sender: Any?) { model?.copy(.prompt) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { model?.openOriginal(); return }  // Return
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Prompt", action: #selector(copyPrompt), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Text Only", action: #selector(copyText), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Parameters", action: #selector(copyParams), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open", action: #selector(openOriginal), keyEquivalent: "").target = self
        return menu
    }

    @objc func copyPrompt() { model?.copy(.prompt) }
    @objc func copyText() { model?.copy(.text) }
    @objc func copyParams() { model?.copy(.parameters) }
    @objc func reveal() { model?.revealInFinder() }
    @objc func openOriginal() { model?.openOriginal() }
}

final class MonthHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("MonthHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, count])
        stack.spacing = 8
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title t: String, count n: Int?) {
        title.stringValue = t
        count.stringValue = n.map { $0.formatted() } ?? ""
        layer?.backgroundColor = t.isEmpty ? nil : NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    }
}

final class ThumbCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbCell")
    var itemID: Int64 = -1
    private let imageLayer = CALayer()
    private let badge = NSImageView()
    private(set) var isEmpty = true
    var fill = true { didSet { imageLayer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect } }

    override func loadView() {
        let v = CellView()
        v.wantsLayer = true
        v.layer?.cornerRadius = DS.Radius.cell
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = DS.Radius.cell
        v.layer?.addSublayer(imageLayer)
        v.onLayout = { [weak self] bounds in
            self?.layoutImage(in: bounds)
        }
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badge.layer?.cornerRadius = 4
        badge.imageScaling = .scaleNone
        v.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            badge.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
        ])
        view = v
    }

    func show(_ image: NSImage?) {
        imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        isEmpty = image == nil
    }

    func setSource(_ s: ItemSource?) {
        guard let s, s != .unknown else { badge.isHidden = true; return }
        badge.isHidden = false
        badge.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        badge.toolTip = s.title
    }

    /// The image fills the cell; when selected it insets inside an accent ring.
    func layoutImage(in bounds: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = isSelected ? bounds.insetBy(dx: 4, dy: 4) : bounds
        imageLayer.cornerRadius = isSelected ? DS.Radius.cell - 4 : DS.Radius.cell
        CATransaction.commit()
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            layoutImage(in: view.bounds)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        show(nil)
        itemID = -1
    }
}

/// Square cells that fill each row exactly: the column count comes from the
/// target size, then cells grow so every row ends flush with the margins.
final class JustifiedFlowLayout: NSCollectionViewFlowLayout {
    var targetSize: CGFloat = 160
    private var lastWidth: CGFloat = 0

    override func prepare() {
        if let cv = collectionView {
            let width = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
            let inner = width - sectionInset.left - sectionInset.right
            let cols = max(1, Int((inner + minimumInteritemSpacing) / (targetSize + minimumInteritemSpacing)))
            let side = floor((inner - CGFloat(cols - 1) * minimumInteritemSpacing) / CGFloat(cols))
            if itemSize.width != side { itemSize = NSSize(width: side, height: side) }
            lastWidth = width
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

final class CellView: NSView {
    var onLayout: ((NSRect) -> Void)?
    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
}
