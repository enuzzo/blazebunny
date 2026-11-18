import AppKit
import BlazebunnyCore

/// The header above each month, pinned while its month scrolls by.
final class MonthHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("MonthHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// The window colour, almost opaque, so thumbnails scrolling under a pinned header do not show through the text.
    private static let veil = NSColor(DS.Palette.window).withAlphaComponent(DS.Palette.headerVeil).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = Typeface.nsFont(size: DS.TextStyle.headline.size, weight: DS.TextStyle.headline.weight, role: .text)
        count.font = Typeface.nsFont(size: DS.TextStyle.meta.size - DS.TextStyle.meta.monoAdjust, weight: .regular, role: .number)
        count.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, count])
        stack.spacing = DS.Space.s
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.l),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title t: String, count n: Int?) {
        title.stringValue = t
        count.stringValue = n.map { $0.formatted() } ?? ""
        layer?.backgroundColor = t.isEmpty ? nil : Self.veil
    }
}

final class ThumbCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbCell")
    var itemID: Int64 = -1
    /// The thumbnail request in flight for this cell, taken back when the cell leaves the screen.
    var loadToken: ThumbnailLoader.Token?
    /// When the cell asked for its thumbnail (for the bench).
    var askedAt: UInt64 = 0
    private let imageLayer = CALayer()
    private let badge = NSImageView()
    private var source: ItemSource?
    private(set) var isEmpty = true
    var fill = true { didSet { if fill != oldValue { imageLayer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect } } }

    private var cellView: CellView { view as! CellView }

    override func loadView() {
        let v = CellView()
        v.wantsLayer = true
        v.layer?.cornerRadius = DS.Radius.cell
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = DS.Palette.cellPlaceholder.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = DS.Radius.cell
        // A new image replaces the old one at once: no implicit cross-fade while scrolling.
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        v.layer?.addSublayer(imageLayer)
        v.onLayout = { [weak self] bounds in self?.layoutImage(in: bounds) }
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = DS.Palette.badgeScrim.cgColor
        badge.layer?.cornerRadius = DS.Radius.small
        badge.imageScaling = .scaleNone
        badge.isHidden = true
        badge.setAccessibilityElement(false)  // the cell's own label already names the source
        v.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -DS.Space.s),
            badge.topAnchor.constraint(equalTo: v.topAnchor, constant: DS.Space.s),
            badge.widthAnchor.constraint(equalToConstant: DS.Size.cellBadge),
            badge.heightAnchor.constraint(equalToConstant: DS.Size.cellBadge),
        ])
        view = v
    }

    /// Name and source, read only when a tooltip or VoiceOver asks: nothing is built while scrolling.
    func describe(name: Substring, source: ItemSource?) {
        cellView.name = name
        cellView.sourceTitle = source.flatMap { $0 == .unknown ? nil : $0.title }
        setSource(source)
    }

    func show(_ image: CGImage?) {
        imageLayer.contents = image
        isEmpty = image == nil
    }

    /// Fill or fit, with a short fade when the cell is on screen.
    func setFill(_ newValue: Bool, animated: Bool) {
        guard fill != newValue else { return }
        if animated, !isEmpty {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = DS.Motion.reflowDuration
            imageLayer.add(fade, forKey: "fill")
        }
        fill = newValue
    }

    private static var badgeImages: [ItemSource: NSImage] = [:]

    private func setSource(_ s: ItemSource?) {
        guard s != source || badge.image == nil else { return }
        source = s
        guard let s, s != .unknown else { badge.isHidden = true; return }
        badge.isHidden = false
        if Self.badgeImages[s] == nil {
            Self.badgeImages[s] = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: DS.Size.cellBadgeGlyph, weight: .semibold))
        }
        badge.image = Self.badgeImages[s]
        badge.toolTip = s.title
    }

    /// The image fills the cell; when selected it insets inside an accent ring.
    func layoutImage(in bounds: NSRect) {
        let inset = isSelected ? DS.Size.selectionInset : 0
        imageLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        imageLayer.cornerRadius = DS.Radius.cell - inset
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            view.layer?.borderWidth = isSelected ? DS.Size.selectionRing : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            layoutImage(in: view.bounds)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        view.layer?.removeAllAnimations()
        show(nil)
        itemID = -1
    }
}

/// The cell's view: tells the cell when it is laid out, and answers tooltips and VoiceOver on demand.
final class CellView: NSView, NSViewToolTipOwner {
    var onLayout: ((NSRect) -> Void)?
    var name: Substring = ""
    var sourceTitle: String?
    private var toolTipBounds = NSRect.zero

    override func layout() {
        super.layout()
        onLayout?(bounds)
        if toolTipBounds != bounds {
            toolTipBounds = bounds
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        String(name)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { sourceTitle.map { "\(name), \($0)" } ?? String(name) }
}
