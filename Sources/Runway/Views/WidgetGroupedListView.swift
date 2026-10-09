import SwiftUI

/// The dashboard display: one inset group per provider (System Settings style). A provider's icon + name
/// sits above a rounded container holding its metric rows, so heterogeneous metric sets read as belonging
/// to their provider. Rows are the shared `WidgetRowView`, fed by the same `WidgetDataStore` the menu bar
/// uses.
///
/// Reordering works here directly (no Customize needed): drag any metric row to reorder it within its
/// provider, or drag a provider's header line to reorder whole providers. Customize stays the discoverable,
/// obvious place to do the same plus toggle metrics on/off. Both surfaces use the same local gesture/geometry
/// helper so they work inside the menu-bar popover without a system drag/drop session.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) var layout
    @Environment(WidgetDataStore.self) var dataStore
    @Environment(\.colorScheme) private var colorScheme
    let groups: [ProviderGroup]
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    // Not `private`: the reorder gestures live in `WidgetGroupedListView+Reorder.swift`.
    @State var rowFrames = ReorderFrameStore()
    @State var activeProviderID: String?
    @State var activeMetricID: String?
    /// The card the "Rename…" alert is currently editing; `nil` when the alert is closed.
    @State private var renameCardID: String?
    @State private var renameDraft = ""
    @AppStorage(AccountCardGrouping.key) var groupsAccounts = false
    private let density = DensitySetting.compact

    var body: some View {
        // Provider-section spacing is noticeably wider than the in-card row rhythm (so groups
        // still read as groups); the exact step comes from the compact layout definition.
        VStack(alignment: .leading, spacing: density.dashboardSectionSpacing) {
            ForEach(sections) { section in
                if section.cards.count > 1 {
                    familySection(section)
                } else if let card = section.cards.first {
                    self.section(card, in: section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.spring, value: groups.map(\.provider.id))
        .alert("Rename Card", isPresented: isRenamePresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renameCardID {
                    // A cleared field resets the card back to its derived name.
                    container.accounts.rename(cardID: renameCardID, to: renameDraft)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave the name empty to go back to the default.")
        }
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { renameCardID != nil },
            set: { if !$0 { renameCardID = nil } }
        )
    }

    /// The cards as dashboard sections: one per card, or one per provider when **Group Accounts
    /// by Provider** is on.
    var sections: [DashboardSection] {
        AccountCardGrouping.sections(resolvedCards, cardID: \.id, enabled: groupsAccounts).map { cards in
            // Grouped, a section is its provider whichever account comes first: keyed by the
            // account, reordering two accounts would replace the section mid-drag and strand the
            // gesture that is doing the reordering.
            let id = groupsAccounts ? DashboardSection.familyID(of: cards[0].id) : cards[0].id
            return DashboardSection(id: id, cards: cards)
        }
    }

    /// Every card resolved once per render, with the tile column count its provider's accounts
    /// share — which only exists once all of them are resolved.
    var resolvedCards: [ResolvedCard] {
        var cards = groups.map(resolveCard)
        let columns = MeterTileLayout.limitColumnsByFamily(cards.map {
            (family: ProviderAccountID.family(of: $0.id), limits: $0.limitGridSize)
        })
        for index in cards.indices {
            cards[index].limitColumns = columns[ProviderAccountID.family(of: cards[index].id)]
        }
        return cards
    }

    /// Several accounts of one provider in a single card: the provider named once above it, then
    /// each account's own sub-header and rows, separated by a hairline. Every account keeps what
    /// its own card had — its plan, notices, expansion, context menu, and drag-to-reorder — and all of
    /// their meters share one set of columns.
    private func familySection(_ section: DashboardSection) -> some View {
        let cards = section.cards
        let accounts = cards.map(\.group)
        let family = ProviderAccountID.family(of: accounts[0].provider.id)
        let familyName = ProviderAccountID.familyDisplayName(family) ?? accounts[0].provider.displayName
        return VStack(alignment: .leading, spacing: density.groupedHeaderToCardSpacing) {
            ProviderFamilyHeader(
                provider: accounts[0].provider,
                name: familyName,
                accountCount: accounts.count,
                usableCount: cards.count { AccountAvailability.isUsable($0) }
            )
            VStack(spacing: 0) {
                ForEach(cards) { card in
                    VStack(spacing: 0) {
                        if card.id != cards.first?.id {
                            // Inset to the rows' edge, so it reads as a rule between accounts
                            // rather than a second card border.
                            Rectangle()
                                .fill(.separator)
                                .frame(height: 1)
                                .padding(.horizontal, MeterTileLayout.horizontalPadding)
                        }
                        // The account's whole block is its expand target, its title line included:
                        // inside the shared card that line is part of the account's box, the way
                        // a separate card's box is everything under its header.
                        expandable(card) {
                            VStack(spacing: 0) {
                                header(card, in: section, accountTitle: accountTitle(card, familyName: familyName))
                                cardContent(card)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, density.groupedAccountPadding)
                            .padding(.bottom, density.groupedAccountPadding - MeterTileLayout.bottomPadding / 2)
                        }
                    }
                    .opacity(activeProviderID == card.id ? 0 : 1)
                    .reorderFrame(id: card.id, in: reorderSpaceName, store: rowFrames)
                }
            }
            .cardOutline()
        }
        // The whole provider is one drop target for a card dragged from outside it.
        .reorderFrame(id: section.id, in: reorderSpaceName, store: rowFrames)
    }

    /// An account's title inside its provider's card. A name the user gave the card is shown as
    /// written; only the derived default drops the provider prefix the header already carries.
    private func accountTitle(_ card: ResolvedCard, familyName: String) -> String {
        if let custom = container.accounts.record(backingCardID: card.id)?.customLabel?.nilIfEmpty {
            return custom
        }
        return AccountCardGrouping.accountTitle(
            displayName: container.displayName(for: card.group.provider),
            familyName: familyName
        )
    }

    private func section(_ card: ResolvedCard, in section: DashboardSection) -> some View {
        let group = card.group
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(card, in: section)
            // Same card builder the lifted preview uses, so the floating chip can't drift from the live card.
            expandable(card) {
                DashboardMetricCard {
                    cardContent(card)
                }
            }
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: reorderSpaceName, store: rowFrames)
    }

    private func header(_ card: ResolvedCard, in section: DashboardSection, accountTitle: String? = nil) -> some View {
        let group = card.group
        // Only a notice a refresh can actually move gets the clickable triangle. A `.wait` notice
        // (Claude's "manual refreshes will make it worse" during an Anthropic rate limit) keeps the
        // inert glyph, so the app never offers the action its own tooltip warns against.
        let canRefreshNotice = dataStore.headerNoticeAction(for: group.provider.id) == .refresh
        return ProviderSectionHeader(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.headerNotice(for: group.provider.id),
            noticeIsConnectPrompt: dataStore.noticeIsConnectPrompt(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id),
            onWarningRefresh: canRefreshNotice ? { refreshProvider(group.provider.id) } : nil,
            accountTitle: accountTitle,
            isUnavailable: AccountAvailability.isExhausted(card.alwaysRows)
        )
        .highPriorityGesture(providerDragGesture(for: card, in: section))
        .contextMenu {
            let name = container.displayName(for: group.provider)
            // Hides the whole provider section (the Customize provider list brings it back). Mirrors
            // the per-metric "Hide" but one level up, so the verb order reads the same on a header as a row.
            Button("Hide \(name)") {
                container.enablement.setEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(name)") {
                refreshProvider(group.provider.id)
            }
            // Renaming needs an account record to write to, so it only shows on account-model cards
            // whose identity has been observed at least once.
            if container.canRename(group.provider.id) {
                Button("Rename…") {
                    // Seed with the STORED rename (empty when none), not the derived title —
                    // confirming an untouched field must stay "no rename", not freeze the derived
                    // name into a custom label that future account-label updates can't refresh.
                    renameDraft = container.accounts
                        .record(backingCardID: group.provider.id)?.customLabel ?? ""
                    renameCardID = group.provider.id
                }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard. The appearance is
    /// taken from the popover's own `colorScheme` — this view is hosted in the popover panel, whose
    /// appearance is `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System) — so
    /// the export matches the card on screen instead of guessing from `NSApp.effectiveAppearance`. The
    /// same render path backs the footer's "Share Screenshot" submenu, which reaches it without a
    /// right-click.
    private func shareCard(_ group: ProviderGroup) -> Bool {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme,
            displayName: container.displayName(for: group.provider)
        )
    }

    /// Judge the card's placed, applicable metrics so hidden metrics cannot mask missing usage.
    func usageUnavailableMessage(for group: ProviderGroup) -> String? {
        let placed = (group.alwaysShownWidgets + group.expandedWidgets).compactMap { widget -> WidgetDescriptor? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return descriptor
        }
        return dataStore.usageUnavailableMessage(for: group.provider.id, placedDescriptors: placed)
    }

    private func errorBody(message: String, providerID: String) -> some View {
        ProviderErrorCardView(
            message: message,
            isRefreshing: dataStore.refreshingProviderIDs.contains(providerID),
            showsRefreshAction: dataStore.headerNoticeAction(for: providerID) == .refresh,
            style: dataStore.noticeIsConnectPrompt(for: providerID) ? .connect : .warning,
            onRefresh: { refreshProvider(providerID) }
        )
    }

    /// The one forced refresh every user-initiated control on this screen runs: the header and row
    /// context menus, the error card's Refresh button, and the header's warning triangle. Interactive
    /// and forced because it is an explicit user action — the one that may legitimately raise a
    /// Keychain approval prompt, which background refreshes must never do.
    private func refreshProvider(_ providerID: String) {
        Task { await dataStore.refresh(providerID: providerID, force: true, interactive: true) }
    }

    private func resolveCard(_ group: ProviderGroup) -> ResolvedCard {
        let isExpanded = layout.isProviderExpanded(group.provider.id)
        let message = usageUnavailableMessage(for: group)
        let resolvedAlwaysRows = resolvedRows(group.alwaysShownWidgets, alwaysVisible: true, hidingEmptyRows: message != nil)
        let resolvedExpandedRows = resolvedRows(group.expandedWidgets, hidingEmptyRows: message != nil)
        let (alwaysRows, expandedRows) = promotedRowsIfNeeded(
            alwaysRows: resolvedAlwaysRows,
            expandedRows: resolvedExpandedRows,
            hasNotice: message != nil
        )
        return ResolvedCard(
            group: group,
            message: message,
            isExpanded: isExpanded,
            hasExpandedContent: !expandedRows.isEmpty || !group.provider.visibleLinks.isEmpty,
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            // The caret separates Always Visible and On Demand rows, so text-row condensing should
            // not bridge across it. Each side tightens only against rows on the same side.
            condensedIDs: visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        )
    }

    @ViewBuilder
    private func cardContent(_ card: ResolvedCard) -> some View {
        let providerID = card.id
        if let message = card.message {
            errorBody(message: message, providerID: providerID)
        }
        // One stable list (see `ResolvedCard.rows`) keeps the drag-owning metric row alive when it
        // crosses the caret boundary. Separate always-shown/expanded loops can tear that source view
        // down before `onEnded` fires, leaving the lift overlay visible until another drag forces a reset.
        ForEach(card.rows) { cardRow in
            switch cardRow {
            case .metric(let entry):
                row(entry.descriptor, data: entry.data, in: providerID,
                    condensedTop: card.condensedIDs.contains(entry.descriptor.id))
            case .tiles(let grid):
                MetricTileGrid(grid: grid, id: \.descriptor.id) { entry in
                    tile(entry, in: providerID)
                }
            case .links(let links):
                ProviderLinksView(links: links)
            case .divider:
                expandedSeparator(providerID: providerID)
            }
        }
    }

    func resolvedRows(_ widgets: [PlacedWidget], alwaysVisible: Bool = false, hidingEmptyRows: Bool = false) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            let data = dataStore.data(for: descriptor)
            guard !hidingEmptyRows || data.hasData else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor,
                               data: alwaysVisible ? WeeklyQuotaVisibility.presentation(data, descriptor: descriptor) : data)
        }
    }

    /// The dashboard promises at least one Always Visible row. Account-aware filtering can remove every
    /// row on that side (for example, a Business Copilot seat whose org metrics were saved On Demand),
    /// so promote the applicable On Demand rows rather than rendering a header-only card. A compact
    /// notice already supplies visible content, so On Demand rows stay behind the caret in that case.
    func promotedRowsIfNeeded(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow],
        hasNotice: Bool = false
    ) -> (always: [ResolvedRow], expanded: [ResolvedRow]) {
        !hasNotice && alwaysRows.isEmpty && !expandedRows.isEmpty
            ? (expandedRows, [])
            : (alwaysRows, expandedRows)
    }

    /// Makes a card's body its own expand control: clicking anywhere on it — a tile, a row, the
    /// space between — reveals (or hides) its On Demand rows and quick links. There is no caret;
    /// the card is the target, and it takes keyboard focus so Space does the same (Return stays
    /// the dashboard's Customize shortcut).
    /// Focus is button-style (`.activate`): only keyboard navigation focuses the card, so a click
    /// toggles it without leaving a focus ring behind.
    /// Buttons inside the card (quick links, a notice's Refresh) take their own clicks. A card
    /// with nothing more to show keeps the same view structure and simply does nothing: branching
    /// on that would rebuild the whole card, and every row's state, whenever it changed.
    private func expandable(_ card: ResolvedCard, @ViewBuilder body: () -> some View) -> some View {
        let toggle = {
            guard card.hasExpandedContent else { return }
            toggleExpansion(providerID: card.id, isExpanded: card.isExpanded)
        }
        return body()
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .focusable(card.hasExpandedContent, interactions: .activate)
            .onKeyPress(keys: [.space]) { _ in
                toggle()
                return card.hasExpandedContent ? .handled : .ignored
            }
            .accessibilityActions {
                if card.hasExpandedContent {
                    Button(card.isExpanded ? "Show Less" : "Show More", action: toggle)
                }
            }
    }

    /// One tile in the live card. It keeps the row's right-click menu and registers its frame so
    /// other rows can still be dragged past it, but it is not draggable itself: tiles sit side by
    /// side, and the list's reorder is a vertical one. What a tile shows reorders in Customize.
    private func tile(_ entry: ResolvedRow, in providerID: String) -> some View {
        MetricTileView(data: entry.data)
            .contextMenu { rowMenu(entry.descriptor, providerID: providerID) }
            .reorderFrame(id: entry.descriptor.id, in: reorderSpaceName, store: rowFrames)
    }

    /// Reveals or hides the card's On Demand metrics and quick links.
    private func toggleExpansion(providerID: String, isExpanded: Bool) {
        withAnimation(Motion.spring) {
            // Same transaction as the row change, so the panel height (and the footer riding it)
            // animates on the same spring clock as the unfolding rows — see `coAnimateExpansion`.
            MenuBarPopover.coAnimateExpansion?(providerID, !isExpanded)
            _ = layout.setProviderExpanded(!isExpanded, for: providerID)
        }
    }

    /// The hairline between an open card's Always Visible rows and its On Demand ones. It is
    /// also the boundary a metric is dragged across to move it between the two.
    private func expandedSeparator(providerID: String) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .padding(.horizontal, 14)
            .padding(.vertical, ExpansionHeightEstimator.separatorRowPadding)
            .contentShape(Rectangle())
            .reorderFrame(id: expandedDividerID(for: providerID), in: reorderSpaceName, store: rowFrames)
            .accessibilityHidden(true)
    }

    func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::dashboard-expanded-divider"
    }

    private func visibleCondensedTextRowIDs(alwaysRows: [ResolvedRow], expandedRows: [ResolvedRow]) -> Set<String> {
        condensedTextRowIDs(alwaysRows).union(condensedTextRowIDs(expandedRows))
    }

    /// Neighbor-aware rule (shared with the share-card export via `WidgetData.condensedTextRowOffsets`):
    /// IDs of text-only rows sitting directly under another text-only row. Rows can't see their
    /// neighbors, so the list computes the pairs; Compact density pulls these rows up so a run of
    /// one-liners reads as one cluster. Called per segment (always-shown / expanded), so the expand
    /// caret is never crossed.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        let offsets = WidgetData.condensedTextRowOffsets(in: rows.map(\.data))
        return Set(offsets.map { rows[$0].descriptor.id })
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String,
                     condensedTop: Bool) -> some View {
        let isActive = activeMetricID == descriptor.id
        return WidgetRowView(
            data: data,
            condensedTop: condensedTop
        )
            // Reset credits are the app's only provider write. Bind this row to the service for its
            // exact Codex card; Claude, Grok, and other non-Codex rows receive nil (read-only timeline).
            .environment(
                \.codexResetClaim,
                container.codexResetClaims.service(for: providerID)
            )
            .contentShape(Rectangle())
            .opacity(isActive ? 0 : 1)
            // A limit or a plain value can become a tile the moment it lands beside a limit, which
            // replaces this row view with one in a grid — and a drag's `onEnded` never reaches a
            // view that is gone. So what can be a tile is never dragged, as a row or as a tile.
            .highPriorityGesture(
                metricDragGesture(for: descriptor, providerID: providerID),
                isEnabled: !data.isLimitTile && data.valueTile == nil
            )
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: reorderSpaceName, store: rowFrames)
    }

    /// Desktop-native management for a single metric: hide it, pin/unpin it, refresh its provider, or jump
    /// into Customize — without a trip through Customize first. Hide leads (the most-reached-for verb), then
    /// star, then a divider before the two provider-/app-level actions.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unstar" : "Star for menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id, matching: dataStore.isMetricApplicable) {
                    layout.setPinned(
                        true,
                        for: descriptor.id,
                        matching: dataStore.isMetricApplicable
                    )
                } else {
                    layout.notePinDenied(descriptor.id, matching: dataStore.isMetricApplicable)
                }
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(container.displayName(for: provider))") {
                refreshProvider(providerID)
            }
        }
        Button("Customize…") {
            openCustomize(for: providerID)
        }
    }

    /// From the dashboard, jump straight into this provider's Customize metrics (L2), not the provider list.
    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = providerID
            layout.screen = .customize
        }
    }
}
