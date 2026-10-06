import AppKit

/// Pure mapping from flattened-image coordinates into the existing status-button coordinate space.
/// The regions use the button's full height for an easy native hover target while preserving their
/// per-segment horizontal boundaries.
enum StatusItemToolTipGeometry {
    static func buttonRects(
        for regions: [MenuBarToolTipRegion],
        imageSize: NSSize,
        imageRect: NSRect,
        buttonBounds: NSRect
    ) -> [NSRect] {
        guard imageSize.width > 0, imageRect.width > 0 else { return [] }
        let horizontalScale = imageRect.width / imageSize.width
        return regions.map { region in
            let minX = max(buttonBounds.minX, imageRect.minX + region.rect.minX * horizontalScale)
            let maxX = min(buttonBounds.maxX, imageRect.minX + region.rect.maxX * horizontalScale)
            return NSRect(
                x: minX,
                y: buttonBounds.minY,
                width: max(0, maxX - minX),
                height: buttonBounds.height
            )
        }
    }
}

/// Owns AppKit's tooltip tags and their string providers. Re-applying first removes the old tags so
/// style changes, data-width changes, renames, privacy concealment, and provider disappearance cannot
/// leave stale hover regions behind.
@MainActor
final class StatusItemToolTipCoordinator {
    private weak var button: NSStatusBarButton?
    private var tags: [NSView.ToolTipTag] = []
    private var owners: [StatusItemToolTipOwner] = []

    func apply(
        _ regions: [MenuBarToolTipRegion],
        imageSize: NSSize,
        to button: NSStatusBarButton
    ) {
        clear()
        self.button = button
        guard !regions.isEmpty else { return }

        button.layoutSubtreeIfNeeded()
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let rects = StatusItemToolTipGeometry.buttonRects(
            for: regions,
            imageSize: imageSize,
            imageRect: imageRect,
            buttonBounds: button.bounds
        )
        for (region, rect) in zip(regions, rects) where !rect.isEmpty {
            let owner = StatusItemToolTipOwner(displayName: region.displayName)
            owners.append(owner)
            tags.append(button.addToolTip(rect, owner: owner, userData: nil))
        }
    }

    private func clear() {
        if let button {
            for tag in tags {
                button.removeToolTip(tag)
            }
        }
        tags.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
        button = nil
    }
}

/// One retained owner per tooltip region. AppKit asks it for the account title only after its native
/// hover delay, so the status item pays no custom mouse-tracking or popover cost.
@MainActor
private final class StatusItemToolTipOwner: NSObject, NSViewToolTipOwner {
    private let displayName: String

    init(displayName: String) {
        self.displayName = displayName
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        displayName
    }
}
