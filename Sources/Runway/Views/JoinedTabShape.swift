import SwiftUI

/// One surface for a selected tab and the panel it opens: the tab rises from the panel's top edge
/// like a folder tab, with rounded outer corners and concave fillets where the two meet. The shape
/// itself says which tab the panel belongs to.
///
/// The tab is one of `tabCount` equal slots laid out with `tabSpacing` between them — the same
/// arithmetic as an `HStack` of equal-width tiles — and `tabPosition` is animatable, so a selection
/// change slides the tab along the panel. Where the tab reaches the panel's left or right edge, the
/// fillet and the panel's corner on that side shrink to nothing together and the edge runs straight.
struct JoinedTabShape: Shape {
    /// The selected slot, 0-based. Fractional values place the tab between slots mid-animation.
    var tabPosition: Double
    var tabCount: Int
    var tabSpacing: CGFloat
    /// The tab's height: the distance from the shape's top to the panel's top edge.
    var tabHeight: CGFloat
    var tabCornerRadius: CGFloat = 10
    var filletRadius: CGFloat = 8
    var panelCornerRadius: CGFloat = Theme.cardCornerRadius

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(tabPosition, tabHeight) }
        set {
            tabPosition = newValue.first
            tabHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let count = CGFloat(max(1, tabCount))
        let tabWidth = max(0, (rect.width - tabSpacing * (count - 1)) / count)
        let left = rect.minX + CGFloat(tabPosition) * (tabWidth + tabSpacing)
        let right = min(rect.maxX, left + tabWidth)
        let top = rect.minY
        let seam = min(rect.maxY, top + max(0, tabHeight))
        let bottom = rect.maxY

        let tabRadius = min(tabCornerRadius, tabWidth / 2, (seam - top) / 2)
        let panelRadius = min(panelCornerRadius, (bottom - seam) / 2)
        // The room beside the tab is shared by the fillet and the panel's top corner on that side.
        let leftRoom = max(0, left - rect.minX)
        let rightRoom = max(0, rect.maxX - right)
        let leftFillet = min(filletRadius, leftRoom / 2, panelRadius)
        let rightFillet = min(filletRadius, rightRoom / 2, panelRadius)
        let leftCorner = min(panelRadius, leftRoom / 2)
        let rightCorner = min(panelRadius, rightRoom / 2)

        var path = Path()
        path.move(to: CGPoint(x: left + tabRadius, y: top))
        path.addLine(to: CGPoint(x: right - tabRadius, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: seam), radius: tabRadius)
        path.addLine(to: CGPoint(x: right, y: seam - rightFillet))
        path.addArc(tangent1End: CGPoint(x: right, y: seam), tangent2End: CGPoint(x: rect.maxX, y: seam), radius: rightFillet)
        path.addLine(to: CGPoint(x: rect.maxX - rightCorner, y: seam))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: seam), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: rightCorner)
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - panelRadius))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: panelRadius)
        path.addLine(to: CGPoint(x: rect.minX + panelRadius, y: bottom))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: seam), radius: panelRadius)
        path.addLine(to: CGPoint(x: rect.minX, y: seam + leftCorner))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: seam), tangent2End: CGPoint(x: left, y: seam), radius: leftCorner)
        path.addLine(to: CGPoint(x: left - leftFillet, y: seam))
        path.addArc(tangent1End: CGPoint(x: left, y: seam), tangent2End: CGPoint(x: left, y: top), radius: leftFillet)
        path.addLine(to: CGPoint(x: left, y: top + tabRadius))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: tabRadius)
        path.closeSubpath()
        return path
    }
}
