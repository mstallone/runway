import SwiftUI

extension View {
    /// Folds a block open and shut in place: its height runs between zero and its natural height
    /// with the content pinned to the top and clipped, so whatever sits below rides the revealing
    /// edge instead of crossing over rows that are fading in. The block stays in the view tree
    /// while shut — nothing is inserted mid-animation, so nothing pops — and is disabled and hidden
    /// from assistive technologies until it opens, so a control inside it can't take keyboard
    /// focus or a click while invisible.
    func accordionReveal(_ isOpen: Bool) -> some View {
        frame(height: isOpen ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isOpen ? 1 : 0)
            // Clipping does not clip hit-testing: the shut block's rows still overflow its zero
            // height, so they must not take clicks meant for whatever now sits there.
            .allowsHitTesting(isOpen)
            .disabled(!isOpen)
            .accessibilityHidden(!isOpen)
    }
}
