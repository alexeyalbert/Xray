import SwiftUI

/// A flow layout that places subviews horizontally and wraps to the next line when needed.
/// Oversized subviews can optionally be constrained so their content wraps within the layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8
    var constrainOversizedSubviews = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity

        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var measuredMaxRowWidth: CGFloat = 0

        for subview in subviews {
            let subviewSize = size(for: subview, constrainedTo: maxWidth)

            if currentRowWidth > 0 && currentRowWidth + spacing + subviewSize.width > maxWidth {
                // Wrap to next line
                measuredMaxRowWidth = max(measuredMaxRowWidth, currentRowWidth)
                totalHeight += currentRowHeight + rowSpacing
                currentRowWidth = subviewSize.width
                currentRowHeight = subviewSize.height
            } else {
                // Stay on current line
                currentRowWidth += (currentRowWidth == 0 ? 0 : spacing) + subviewSize.width
                currentRowHeight = max(currentRowHeight, subviewSize.height)
            }
        }

        measuredMaxRowWidth = max(measuredMaxRowWidth, currentRowWidth)
        totalHeight += currentRowHeight

        let width = maxWidth.isInfinite ? measuredMaxRowWidth : maxWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = size(for: subview, constrainedTo: maxWidth)
            let requiredWidth = (cursor.x > bounds.minX ? spacing : 0) + subviewSize.width

            if cursor.x + requiredWidth > bounds.minX + maxWidth {
                // Wrap to the next line
                cursor.x = bounds.minX
                cursor.y += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            if cursor.x > bounds.minX { cursor.x += spacing }
            subview.place(at: CGPoint(x: cursor.x, y: cursor.y), proposal: ProposedViewSize(subviewSize))
            cursor.x += subviewSize.width
            currentRowHeight = max(currentRowHeight, subviewSize.height)
        }
    }

    private func size(for subview: LayoutSubview, constrainedTo maxWidth: CGFloat) -> CGSize {
        let idealSize = subview.sizeThatFits(.unspecified)
        guard constrainOversizedSubviews,
              maxWidth.isFinite,
              maxWidth > 0,
              idealSize.width > maxWidth else {
            return idealSize
        }

        return subview.sizeThatFits(
            ProposedViewSize(width: maxWidth, height: nil)
        )
    }
}
