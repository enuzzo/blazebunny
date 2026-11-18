import AppKit

/// Square cells that fill each row exactly: the column count comes from the
/// target size, then cells grow so every row ends flush with the margins.
///
/// The rows are laid out for `layoutWidth`, which is normally the visible width. While a side panel
/// slides in or out the grid's width changes on every frame; the layout then keeps the width it had,
/// so thumbnails do not jump from column to column mid-animation, and the grid reflows once when the
/// width rests (`GridView.Coordinator.reflow`).
final class JustifiedFlowLayout: NSCollectionViewFlowLayout {
    var targetSize: CGFloat = DS.Size.thumbnailDefault
    /// Width the rows are wrapped for; 0 until the first layout.
    var layoutWidth: CGFloat = 0
    /// Space around each section: left and right margins and the gap below.
    var margins = NSEdgeInsets(top: 0, left: DS.Space.l, bottom: DS.Space.l, right: DS.Space.l)
    private var lastVisibleWidth: CGFloat = 0

    func visibleWidth(_ cv: NSCollectionView) -> CGFloat {
        cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
    }

    override func prepare() {
        let started = Perf.now()
        defer { GridStats.layoutPasses += 1; GridStats.layoutMs += Perf.ms(since: started) }
        if let cv = collectionView {
            let visible = visibleWidth(cv)
            lastVisibleWidth = visible
            if layoutWidth <= 0 { layoutWidth = visible }
            let gap = minimumInteritemSpacing
            let inner = layoutWidth - margins.left - margins.right
            let columns = max(1, Int((inner + gap) / (targetSize + gap)))
            let side = floor((inner - CGFloat(columns - 1) * gap) / CGFloat(columns))
            if itemSize.width != side { itemSize = NSSize(width: side, height: side) }
            // Wrap for `layoutWidth` even while the view is another width: the difference goes into
            // the right margin (negative while the view is narrower; the overflow is clipped).
            let inset = NSEdgeInsets(top: margins.top, left: margins.left, bottom: margins.bottom,
                                     right: margins.right + (visible - layoutWidth))
            if sectionInset.right != inset.right || sectionInset.left != inset.left || sectionInset.bottom != inset.bottom {
                sectionInset = inset
            }
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastVisibleWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}
