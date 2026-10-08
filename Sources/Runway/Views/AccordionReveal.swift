import SwiftUI

extension View {
    /// Folds a block open and shut in place: its height runs between zero and its natural height
    /// with the content pinned to the top and clipped, so whatever sits below rides the revealing
    /// edge instead of crossing over rows that are fading in. The block stays in the view tree
    /// while shut — nothing is inserted mid-animation, so nothing pops — and is hidden from clicks
    /// and assistive technologies until it opens.
    func accordionReveal(_ isOpen: Bool) -> some View {
        frame(height: isOpen ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }
}
