import SwiftUI

/// One metric as a row inside a provider's grouped list container. The provider icon is drawn once in the
/// section header (not per row), so a row shows only the metric. Two layouts:
/// - **Bounded** (`limit != nil`): only the exhausted-week message. Limits themselves are never
///   rows; a card draws them as a grid of tiles (`MetricTileGrid`, laid out by `MeterTileLayout`).
/// - **Unbounded** (`limit == nil`, text-only row): **no bar**. Label on the left, a single right-aligned
///   descriptive line ("1,503 left") and an optional secondary line ("on-device estimate").
/// Rows size to their own content (variable height). Same `WidgetData` the menu bar uses — only layout differs.
struct WidgetRowView: View {
    let data: WidgetData
    /// True when this text-only row sits directly under another text-only row. Rows don't know
    /// their neighbors — the list supplies it — and the compact layout pulls consecutive one-liners
    /// into a single cluster.
    var condensedTop: Bool = false

    private let density = DensitySetting.compact
    @State private var modelHover = HoverPopoverState()
    /// Backs the resets popover's claim flow; `nil` outside the live dashboard (previews, share
    /// renders), which renders the timeline read-only.
    @Environment(\.codexResetClaim) private var codexResetClaim
    /// The popover's shared 30s clock for relative reset/expiry text. Reading `halfMinute` in `body`
    /// (only for rows that show a date) re-renders the row when it ticks; the clock itself stops
    /// while the popover is closed, so the retained hidden tree never ticks. Deliberately NOT a
    /// per-row `TimelineView` gated on `\.popoverIsVisible`: that gate was a structural branch swap,
    /// so every open/close tore down and rebuilt each dated row's subtree (measured as the largest
    /// single cost on the popup-open path). Optional because rows also render inside
    /// `ImageRenderer` for share cards, where no clock exists — nil simply means static text,
    /// which is what a one-shot render wants.
    @Environment(DashboardClock.self) private var clock: DashboardClock?
    /// The row font comes from the compact layout definition. The size is explicit because semantic
    /// `.headline.weight(.regular)` does not match `.headline` on macOS, and `minimumScaleFactor`
    /// was shrinking only the trailing value. Names use the same size in semibold.
    private var supportingFont: Font {
        .system(size: density.supportingPointSize, weight: .regular)
    }

    var body: some View {
        // A row with a concrete reset date derives time-sensitive state (reset countdown, pace marker,
        // "Runs out in …") from the shared clock (see `clock` above), so it re-renders on its 30s
        // tick instead of waiting for the next data refresh. Rows without a reset date are static:
        // they never read the clock, so they never subscribe to its ticks. Dated rows subscribe
        // via this read and re-render every half minute.
        let _ = (data.resetsAt != nil || !data.expiriesAt.isEmpty) ? clock?.halfMinute : nil
        rowContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        // Consecutive text rows (Today / Yesterday / Last 30 Days) pull up against each other
        // (`condensedTop`) so they read as one cluster under the tiles.
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var topPadding: CGFloat {
        if data.isBounded { return density.meterRowPadding }
        return condensedTop ? density.condensedTextRowTopPadding : density.textRowPadding
    }

    private var bottomPadding: CGFloat {
        data.isBounded ? density.meterRowPadding : density.textRowPadding
    }

    @ViewBuilder
    private var rowContent: some View {
        if let title = data.exhaustedWeeklyTitle {
            // The one shape that is not a tile: an account that cannot be used is a single faded
            // line — the message, and when it is back.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    Text(data.exhaustedWeeklyResetNote())
                    Text(data.exhaustedWeeklyResetNote(countdownOnly: true))
                }
            }
            .font(supportingFont)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .opacity(Theme.unavailableOpacity)
        } else if data.isChart, data.hasData {
            // The sparkline owns its own label + bars; a chart with no real points falls through to the
            // unbounded "No data" row below (and so descriptor template data never leaks here).
            UsageSparkline(data: data)
        } else {
            unboundedRow
        }
    }

    /// Bar/copy color for a severity, or the inactive gray when there's none (the no-data track).
    private func severityColor(_ severity: WidgetData.MeterSeverity?) -> AnyShapeStyle {
        severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary)
    }

    /// Unbounded: no bar. Label on the left, with a single right-aligned descriptive line ("1,503 left")
    /// and an optional secondary line ("on-device estimate") beneath it.
    private var unboundedRow: some View {
        unboundedRowContent
            .onChange(of: data.modelBreakdown) { _, _ in modelHover.dismiss() }
            // A refresh can replace the reset credits (count and expiries) while the popover is open;
            // drop it so it never lingers over a stale timeline — except while the claim flow has the
            // popover pinned: the claim's own forced refresh is what changes the credits, and dismissing
            // on it would close the popover before the claim's result banner ever renders. The pinned
            // popover re-renders from the new data instead (the detail view reconciles its own state).
            .onChange(of: data.expiriesAt) { _, _ in
                if !modelHover.isPinned { modelHover.dismiss() }
            }
            .onDisappear { modelHover.dismiss() }
    }

    /// The value column reveals the model breakdown on hover, so it lights up under the pointer the way
    /// a Finder / System Settings list row does — the native cue that "this is a target." Lit the moment
    /// the pointer arrives (`overInline`, before the reveal dwell) and held lit while the popover is open,
    /// so the value reads as the popover's source. Both flags live on `modelHover`, so the panel's close
    /// path (`dismissAll`) clears the highlight even though this view's state survives `orderOut`. Only
    /// rows that actually have a breakdown light up.
    private var showValueHighlight: Bool {
        hasHoverPopover && (modelHover.overInline || modelHover.isPresented)
    }

    /// Whether the value column reveals a hover popover: the model breakdown on spend rows, or the
    /// resets timeline on a rate-limit-resets row. One `modelHover` coordinator drives both — a
    /// row is only ever one kind — so lighting the value and anchoring the popover share the spend
    /// row's machinery. The resets row qualifies even at "0 available" (empty `expiriesAt`), so its
    /// empty-state popover stays reachable — but only with real data: a "No data" tile must not open a
    /// popover that reads as "zero credits" (`hasModelBreakdown` already carries its own `hasData`).
    private var hasHoverPopover: Bool {
        data.hasModelBreakdown || (data.showsResetExpiries && data.hasData)
    }

    private var unboundedRowContent: some View {
        // A numeric value ("1,503 left") must never truncate, so it holds its width rigid. A text
        // badge ("Managed by Your Organization") can be a full sentence: if it also held rigid, the
        // row's minimum width would exceed the panel's content slot, and — because every provider
        // card stretches to the widest sibling — one such row strips the outer padding from the
        // entire dashboard. Badge text yields instead: it wraps to two lines and then truncates.
        let isTextBadge = data.valueTextOverride != nil
        return HStack(alignment: .center, spacing: 10) {
            labelColumn
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    expiryStatusDot
                    Text(data.unboundedDetail)
                        // The value is the row's payload, so it carries the weight — the same
                        // name-quiet, reading-strong order as a limit tile.
                        .font(.system(size: density.supportingPointSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .lineLimit(isTextBadge ? 2 : 1)
                        .fixedSize(horizontal: !isTextBadge, vertical: false)
                        // Hover target is the value text itself, not the whole row — the same
                        // per-element pattern the bounded row uses for "x left" and "Resets in …". Reveals
                        // the exact figures the compact value shortens, or "No usage in this period" on a
                        // zero row; nil (no tooltip) on a small, already-full, non-zero row. Suppressed
                        // when the model-breakdown popover is wired up — a text bubble and a popover
                        // fighting over the same hover reads as two competing surfaces, and the panel's
                        // per-model tooltips carry the exact figures instead. The resets row likewise
                        // drops its tooltip — the timeline popover replaces it.
                        .hoverTooltip(hasHoverPopover ? nil : data.unboundedValueTooltip)
                }
                if let subtitle = data.unboundedSubtitle {
                    // Secondary, not tertiary: the subtitle is informational ("on-device estimate"),
                    // and tertiary is reserved for inactive content on glass. Badge subtitles are
                    // sentences, so they get the same two-line room as the badge value above.
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isTextBadge ? 2 : 1)
                }
            }
            .multilineTextAlignment(.trailing)
            // A quaternary chip behind the value — the app's subtle-fill token, in the shared 6pt
            // continuous corner — signals the value is interactive before the breakdown even opens.
            // Negative-inset so it hugs the figure without changing the row's height (the text-row
            // rhythm that clusters Today / Yesterday / Last 30 Days must not shift), and a quick
            // opacity fade in/out matches macOS hover states.
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4)
                    .opacity(showValueHighlight ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: showValueHighlight)
            // Both the hover trigger and the popover anchor live on the value column, not the whole
            // row: hovering the label (or empty gap) shouldn't reveal the breakdown — only the figure
            // it explains should — and the arrow then centers on that figure, matching the trend
            // popover's anchoring off the sparkline strip.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard hasHoverPopover else {
                    modelHover.dismiss()
                    return
                }
                if case .active = phase {
                    modelHover.inlineHover(true)
                } else {
                    modelHover.inlineHover(false)
                }
            }
            .popover(
                isPresented: Binding(
                    get: { hasHoverPopover && modelHover.isPresented },
                    // A click-outside dismiss removes the detail view without an `.ended` hover event,
                    // so a plain assignment would strand `overDetail == true` and block future hides.
                    set: { if !$0 { modelHover.dismiss() } }
                ),
                arrowEdge: .top
            ) {
                if let breakdown = data.modelBreakdown {
                    ModelUsageDetail(title: data.title, breakdown: breakdown) { inside in
                        modelHover.detailHover(inside)
                    }
                } else if data.showsResetExpiries {
                    RateLimitResetsDetail(
                        count: data.resetCreditCount, expiries: data.expiriesAt,
                        onHoverChange: { inside in modelHover.detailHover(inside) },
                        onPinChange: { pinned in modelHover.setPinned(pinned) },
                        // Codex cards bind a claim service; Claude, Grok, and static renders receive nil, so
                        // the timeline stays read-only (Runway never calls Grok's RedeemReset).
                        claim: codexResetClaim.map { service in
                            { expiry, redeemRequestID in
                                await service.claim(creditExpiringAt: expiry, redeemRequestID: redeemRequestID)
                            }
                        }
                    )
                }
            }
        }
    }

    /// Small blue/yellow/red status dot shown just before the value when the row carries reset-credit
    /// expiries — colored by the soonest expiry. The per-credit detail (which credits, expiring when)
    /// lives in the resets popover the value column now reveals on hover, so the dot carries no tooltip
    /// of its own. Renders nothing when no credit is available (an empty `expiriesAt`).
    @ViewBuilder
    private var expiryStatusDot: some View {
        if let severity = data.expirySeverity() {
            Circle()
                .fill(severityColor(severity))
                .frame(width: 6, height: 6)
                .accessibilityLabel(expiryStatusAccessibilityLabel(severity))
        }
    }

    private func expiryStatusAccessibilityLabel(_ severity: WidgetData.MeterSeverity) -> String {
        switch severity {
        case .normal: return "Reset credits expire in more than 7 days"
        case .warning: return "A reset credit expires within 7 days"
        case .critical: return "A reset credit expires within 48 hours"
        }
    }

    private var labelColumn: some View {
        HStack(spacing: 4) {
            Text(data.title)
                // Same size and weight as a meter row's name, so every row in the card starts the
                // same way.
                .font(supportingFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            unknownModelWarningIcon
        }
    }

    /// Amber warning triangle shown just after a spend tile's label (Today / Yesterday / Last 30 Days)
    /// when the period used a model the pricing manifest can't price, so its cost is incomplete. Hovering
    /// lists the unknown model names. Renders nothing otherwise.
    @ViewBuilder
    private var unknownModelWarningIcon: some View {
        if data.hasUnknownModels {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(severityColor(.warning))
                .hoverTooltip(data.unknownModelTooltip)
                .accessibilityLabel("This period used a model with unknown pricing")
        }
    }
}
