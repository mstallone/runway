import SwiftUI

/// The dashboard's drag-to-reorder: whole cards by their header, and rows within a card.
extension WidgetGroupedListView {
    func providerDragGesture(for card: ResolvedCard, in section: DashboardSection) -> some Gesture {
        reorderDragGesture(
            id: card.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: card, value: $0) },
            orderedIDs: { providerTargetIDs(for: card, in: section) },
            reorder: { reorderProvider(card, in: section, target: $0) }
        )
    }

    /// What a dragged card can be dropped on, in display order. Separate cards: every card.
    /// Grouped: an account trades places only with its provider's other accounts, and a provider
    /// with one card moves among the sections, where a grouped provider is one target as a whole.
    /// Dropping onto a single account of another provider would change the saved order without
    /// changing the layout (the provider's accounts are gathered at its first card either way),
    /// so the next drag event would undo it, and the two would alternate under a resting pointer.
    private func providerTargetIDs(for card: ResolvedCard, in section: DashboardSection) -> [String] {
        guard groupsAccounts else { return groups.map(\.provider.id) }
        guard section.cards.count == 1 else { return section.cards.map(\.id) }
        return sections.map(\.dropTargetID)
    }

    private func reorderProvider(_ card: ResolvedCard, in section: DashboardSection, target: String) -> Bool {
        guard groupsAccounts else { return layout.reorderProvider(dragged: card.id, target: target) }
        guard section.cards.count == 1 else {
            // Among the provider's own slots, so its card stays where it is.
            return layout.reorderProvider(dragged: card.id, target: target, among: section.cards.map(\.id))
        }
        let sections = sections
        guard let from = sections.firstIndex(where: { $0.id == section.id }),
              let to = sections.firstIndex(where: { $0.dropTargetID == target })
        else { return false }
        // Past the whole provider: after its last account going down, before its first going up.
        let edge = from < to ? sections[to].cards.last : sections[to].cards.first
        return edge.map { layout.reorderProvider(dragged: card.id, target: $0.id) } ?? false
    }

    func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: { metricTargetIDs(for: providerID) },
            reorder: { target in
                let current = metricTargetIDs(for: providerID)
                if current.contains(expandedDividerID(for: providerID)) {
                    guard let next = LayoutStore.reordered(current, dragged: descriptor.id, target: target) else {
                        return false
                    }
                    return layout.applyMetricDividerOrder(
                        next,
                        dragged: descriptor.id,
                        dividerID: expandedDividerID(for: providerID),
                        in: providerID
                    )
                }
                return layout.reorderMetric(dragged: descriptor.id, target: target, in: providerID)
            }
        )
    }

    private func metricTargetIDs(for providerID: String) -> [String] {
        guard let group = groups.first(where: { $0.provider.id == providerID }) else {
            return []
        }
        let message = usageUnavailableMessage(for: group)
        let rows = promotedRowsIfNeeded(
            alwaysRows: resolvedRows(group.alwaysShownWidgets, hidingEmptyRows: message != nil),
            expandedRows: resolvedRows(group.expandedWidgets, hidingEmptyRows: message != nil),
            hasNotice: message != nil
        )
        let alwaysShown = rows.always.map(\.descriptor.id)
        let expanded = rows.expanded.map(\.descriptor.id)
        // The divider is a drop target whenever the expanded section is open — including a
        // links-only section (buttons but no expanded metrics), so a metric can be dragged past
        // it to tuck it below the fold even when only buttons are showing there.
        let hasExpandedContent = !expanded.isEmpty || !group.provider.visibleLinks.isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    /// The floating preview matches what the card shows: its notice when that is on screen, its
    /// Always Visible rows, and its On Demand rows under the divider when the card is open, on the
    /// same tile columns.
    private func makeProviderLift(for card: ResolvedCard, value: DragGesture.Value) -> ReorderLift? {
        let providerID = card.id
        let rows = card.isExpanded ? card.alwaysRows + card.expandedRows : card.alwaysRows
        return ReorderLift.make(
            id: providerID,
            payload: .dashboardProvider(
                provider: card.group.provider,
                plan: dataStore.plan(for: providerID),
                rows: rows.map(\.data),
                expandBoundaryIndex: card.isExpanded && !card.expandedRows.isEmpty ? card.alwaysRows.count : nil,
                limitColumns: card.limitColumns,
                errorMessage: card.message,
                errorIsConnectPrompt: dataStore.noticeIsConnectPrompt(for: providerID),
                errorAllowsRefresh: dataStore.headerNoticeAction(for: providerID) == .refresh
            ),
            value: value,
            frames: rowFrames.frames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: rowFrames.frames
        )
    }
}
