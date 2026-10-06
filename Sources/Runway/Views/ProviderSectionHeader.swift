import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead; the optional plan is pinned to the trailing edge. Dashboard
/// callers supply a screenshot-copy action, revealed at the trailing edge while the plan is hovered
/// (the plan slides left to make room). Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber triangle at the
/// header's trailing edge (beside the hover-revealed copy control) whose hover tooltip carries the
/// message (e.g. "Not logged in. Run `codex` to authenticate."). With `onWarningRefresh` supplied that
/// triangle is also a button: clicking it refreshes just that provider, so the notice sits on the
/// action that clears it — supplied only for notices a refresh can move, never for one that asks the
/// user to wait. The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
struct ProviderSectionHeader: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    /// Whether `warning` is the neutral connect prompt (a credential exists but hasn't been loaded
    /// this process) rather than a problem. It swaps the amber triangle for a muted key glyph —
    /// same slot, same click-to-refresh behavior — so a state that needs no fixing doesn't wear a
    /// warning color.
    var noticeIsConnectPrompt: Bool = false
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?
    /// Forced refresh of this provider, run when the warning triangle is clicked. `nil` leaves the
    /// triangle the plain status glyph it has always been — the reorder preview (inert by
    /// construction), and any notice a refresh cannot move, which the dashboard decides via
    /// `WidgetDataStore.headerNoticeAction(for:)`.
    var onWarningRefresh: (() -> Void)?
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?

    /// Header type and icon use the same compact layout definition as the rows beneath them.
    private let density = DensitySetting.compact
    /// Air between the plan and the trailing edge while the copy glyph is on screen: the overlaid
    /// glyph's layout slot plus a single point of breathing room — the glyph is drawn centered in
    /// its slot, so its built-in inset supplies most of the visual air and one extra point keeps the
    /// plan from feeling glued to it. Only held while the glyph shows — see the gutter comment on
    /// the plan's trailing padding below.
    private static let copyGutterWidth: CGFloat = CopyFeedbackButton.slotWidth + 1
    /// Margin kept around the provider mark inside its frame (a fraction of the frame). Subtracted
    /// from the header's leading padding so the mark's ink, not its frame, meets the leading edge.
    private static let markInset: CGFloat = 0.04
    /// Fixed layout slot for the warning triangle (its natural width is ~12pt at this size), so the
    /// copy overlay's trailing offset is a constant rather than a measurement.
    static let warningSlotWidth: CGFloat = 14
    /// Spacing between the header row's items.
    static let itemSpacing: CGFloat = 5
    /// Cap height of the name's font, the vertical anchor for the header's glyphs.
    fileprivate nonisolated static let nameCapHeight: CGFloat = NSFont.systemFont(
        ofSize: DensitySetting.compact.headerPointSize,
        weight: .semibold
    ).capHeight
    /// Read for the live card name: a rename lands in the account registry and re-titles the header
    /// without a relaunch (the `Provider`'s own name is baked at launch).
    @Environment(AppContainer.self) private var container
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @State private var isHovered = false
    /// Whether the pointer is in the copy control's reveal zone: the plan plus the copy slot beside
    /// it (just the slot when a card has no plan) rather than the full header, so sweeping the
    /// pointer across the dashboard doesn't flash a button — and slide a plan — on every card it
    /// crosses. Resolved from the pointer's position in the header (see `updateHover`) instead of
    /// per-view hover handlers: the button is drawn over the plan, so the two would each end the
    /// other's hover and the button would flash on and off under a resting pointer.
    @State private var isInCopyZone = false
    /// The plan's leading edge and the header's width, in the header's own coordinate space. Both
    /// are unknown until their first geometry report; the zone stays closed until then.
    @State private var planMinX: CGFloat?
    @State private var headerWidth: CGFloat = 0
    /// Where the pointer last was along the header, kept so the zone can be re-judged when its
    /// bounds move under a resting pointer. Read only from handlers, never from `body`, so pointer
    /// movement alone does not re-render the header.
    @State private var pointerX: CGFloat?
    private nonisolated static let coordinateSpaceName = "ProviderSectionHeader"
    /// Mirrors the copy glyph's actual visibility, reported by `CopyFeedbackButton`: hover reveal
    /// plus the post-copy checkmark's linger after the pointer leaves. The trailing gutter keys off
    /// this rather than the raw hover so a lingering checkmark keeps its space until it fades,
    /// instead of the plan badge sliding back underneath it.
    @State private var copyButtonPresent = false

    /// Hidden while a refresh is in flight: the spinner already says "working on it".
    private var showsWarning: Bool { warning != nil && !refreshing }

    /// The header's trailing padding: it ends the header's content on the card's corner radius.
    static let trailingPadding: CGFloat = Theme.cardCornerRadius

    /// How far the copy slot sits in from the header's content edge: past the notice glyph and the
    /// row's item spacing when a notice is shown, flush otherwise.
    static func copySlotTrailingOffset(showsWarning: Bool) -> CGFloat {
        showsWarning ? warningSlotWidth + itemSpacing : 0
    }

    /// The copy reveal zone along the header's x axis. Its leading edge follows the plan's live
    /// position, so the zone grows as the plan slides left and the pointer that opened it can never
    /// be left outside it; without a plan it is the copy slot alone. Its trailing edge is the
    /// header's edge, or the notice glyph when one is shown — that glyph has its own tooltip and
    /// click.
    static func copyZone(headerWidth: CGFloat, planMinX: CGFloat?, showsWarning: Bool) -> ClosedRange<CGFloat> {
        let contentMaxX = headerWidth - trailingPadding
        let slotMinX = contentMaxX - copySlotTrailingOffset(showsWarning: showsWarning) - CopyFeedbackButton.slotWidth
        let maxX = showsWarning ? contentMaxX - warningSlotWidth : headerWidth
        let minX = min(planMinX ?? slotMinX, maxX)
        return minX...maxX
    }

    /// `nil` until the header (and the plan, when there is one) has been measured.
    private var copyZone: ClosedRange<CGFloat>? {
        guard headerWidth > 0 else { return nil }
        guard plan != nil else {
            return Self.copyZone(headerWidth: headerWidth, planMinX: nil, showsWarning: showsWarning)
        }
        guard let planMinX else { return nil }
        return Self.copyZone(headerWidth: headerWidth, planMinX: planMinX, showsWarning: showsWarning)
    }

    private func resolveCopyZone() {
        // No copy action (the reorder preview), no zone.
        let inZone = onCopyScreenshot != nil && (pointerX.flatMap { x in copyZone?.contains(x) } ?? false)
        if inZone != isInCopyZone { isInCopyZone = inZone }
    }

    private func updateHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if !isHovered { isHovered = true }
            pointerX = location.x
            resolveCopyZone()
        case .ended:
            isHovered = false
            pointerX = nil
            isInCopyZone = false
        }
    }

    private var planTrailingPadding: CGFloat {
        copyButtonPresent ? Self.copyGutterWidth : 0
    }

    init(
        provider: Provider,
        plan: String? = nil,
        warning: String? = nil,
        noticeIsConnectPrompt: Bool = false,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onWarningRefresh: (() -> Void)? = nil,
        onCopyScreenshot: (() -> Bool)? = nil
    ) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.noticeIsConnectPrompt = noticeIsConnectPrompt
        self.refreshing = refreshing
        self.staleness = staleness
        self.onWarningRefresh = onWarningRefresh
        self.onCopyScreenshot = onCopyScreenshot
    }

    var body: some View {
        // One baseline-aligned row. The words (name, stale tag, plan) share the name's text baseline;
        // the glyphs (provider mark, spinner, notice) have no baseline of their own, so each is
        // centered on the name's cap height instead — see `centeredOnHeaderCapHeight`.
        HStack(alignment: .firstTextBaseline, spacing: Self.itemSpacing) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            ProviderIcon(source: provider.icon, inset: Self.markInset)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
                .centeredOnHeaderCapHeight()
            // The name is the only element that gives under width pressure (the plan and the stale
            // tag below stay whole — see their comments). A name that truncates (long account labels
            // like "Claude — demo@example.com") marquees to its ending while the header is hovered —
            // the same reveal the Total Spend legend uses.
            HoverMarqueeText(
                text: container.displayName(for: provider),
                font: .system(size: density.headerPointSize, weight: .semibold),
                // Not while the copy glyph is in play: its gutter opening or closing changes the
                // name's width, which would restart a marquee mid-scroll.
                isHovered: isHovered && !isInCopyZone && !copyButtonPresent
            )
            .foregroundStyle(.primary)
            .layoutPriority(1)
            // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
            // Short by design ("Outdated") — the precise age rides in the hover tooltip. Hidden while
            // a refresh is in flight: the spinner already says "working on it". It stays beside the
            // name it qualifies rather than joining the plan at the trailing edge. `fixedSize` keeps
            // the tag whole under width pressure: as the lowest-priority element it used to absorb the
            // squeeze from a long account name and render as a clipped glyph fragment (half an "O"
            // reading as a stray "(" after the name). It must stay legible rather than sliver or
            // vanish — staleness can occur with no warning triangle (wake-from-sleep aging), making
            // this the only signal that the values are fossilized (upstream #582) — so the name yields
            // instead; its tail stays recoverable through the hover marquee.
            if let staleness, !refreshing {
                Text(staleness.label)
                    .font(.system(size: density.planBadgePointSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hoverTooltip(staleness.tooltip)
            }
            if refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
                    // No taller than the mark, so a refresh starting can't change the row's height.
                    .frame(height: density.headerIconSize)
                    .centeredOnHeaderCapHeight()
            }
            // Owns the header's spare width, so the hover target spans the row even with a short
            // title and everything after it is pinned to the trailing edge.
            // With no plan to carry the copy gutter, the spacer holds it instead, so a name that
            // fills the row still clears the revealed glyph.
            Spacer(minLength: plan == nil && copyButtonPresent ? Self.copyGutterWidth - Self.itemSpacing : 0)
            // The plan always sits at the trailing edge, so every card's plan is found in one place
            // whatever the name's length. Its trailing padding is the copy gutter: zero at rest, so
            // the plan's last letter is flush with the header's trailing edge, and the copy glyph's
            // room only while the glyph is on screen, so the plan slides left in the same
            // beat as the fade-in (the header-level animation below) instead of a permanently
            // reserved slot reading as dead margin.
            if let plan {
                ProviderPlanBadge(plan: plan)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, planTrailingPadding)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.coordinateSpaceName)).minX
                    } action: { minX in
                        planMinX = minX
                    }
            }
            // The warning sits at the far trailing edge — a header-level status instead of crowding
            // the name. Fixed slot width so the copy overlay can offset past it without measuring.
            // Hidden while a refresh is in flight: the spinner already says "working on it", and the
            // refresh may be about to clear the error.
            if showsWarning, let warning {
                warningTriangle(warning)
                    .centeredOnHeaderCapHeight()
            }
        }
        // The copy button overlays the trailing edge (just inside the warning triangle when one is
        // shown) instead of participating in the row, so it costs no width at rest. A header with
        // no plan reveals it in place without moving anything; one with a plan slides the plan left
        // by the gutter to make room.
        .overlay(alignment: .trailing) {
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(container.displayName(for: provider)) Screenshot",
                    isRevealed: isInCopyZone,
                    action: onCopyScreenshot,
                    onPresenceChange: { copyButtonPresent = $0 }
                )
                .padding(.trailing, Self.copySlotTrailingOffset(showsWarning: showsWarning))
            }
        }
        // Animate the gutter's grow/collapse in step with the button's 0.12s fade, so the plan's
        // shift and the glyph's appearance read as one motion.
        .animation(.easeOut(duration: 0.12), value: copyButtonPresent)
        // Both ends of the header land on the corner radius of the card beneath it: the mark's ink
        // starts, and the plan ends, exactly where the card's rounded corners give way to its
        // straight top edge, with no further padding.
        .padding(.leading, Theme.cardCornerRadius - density.headerIconSize * Self.markInset)
        .padding(.trailing, Self.trailingPadding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .coordinateSpace(.named(Self.coordinateSpaceName))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            headerWidth = width
        }
        .onContinuousHover(coordinateSpace: .local) { updateHover($0) }
        // The zone's bounds can move under a resting pointer (the plan is measured, a notice comes
        // or goes); hover events only arrive on movement, so re-judge the last known position.
        .onChange(of: copyZone) { resolveCopyZone() }
        // `NSPanel.orderOut` retains this SwiftUI tree and may not deliver a hover exit (the legend
        // row's rule). Clear the hover at the panel's authoritative close signal so a reopened
        // popover can't start with a revealed copy button — or a marquee still holding a scroll
        // position from the previous session, which read as the name "starting from the middle".
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible {
                isHovered = false
                pointerX = nil
                isInCopyZone = false
            }
        }
    }

    /// The amber notice glyph. When the caller supplies a refresh action the glyph becomes a button:
    /// most of these notices (a login awaiting Keychain approval, an expired token the user just
    /// renewed in their terminal) are cleared by exactly one thing — a manual refresh — and clicking
    /// the symbol that reports the problem is the shortest path to it. That click is an explicit user
    /// gesture, so it is allowed to raise a Keychain approval prompt; background refreshes are not.
    /// Without an action (the reorder preview) it stays the plain status glyph it was.
    @ViewBuilder
    private func warningTriangle(_ warning: String) -> some View {
        // The connect prompt shares the slot and the click behavior but not the alarm: a muted key
        // glyph, because a login waiting to be loaded is a neutral state, not a problem.
        let glyph = Image(systemName: noticeIsConnectPrompt ? "key.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(noticeIsConnectPrompt ? AnyShapeStyle(.secondary) : Theme.notice)
        if let onWarningRefresh {
            Button(action: onWarningRefresh) {
                glyph
                    .frame(width: CopyFeedbackButton.hitSize, height: CopyFeedbackButton.hitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The copy control's trick, for the same reason: a 10pt glyph is a poor click target, so
            // the button owns a 28pt hit rectangle while the negative padding collapses its LAYOUT
            // footprint back to the fixed slot. The slot width stays the constant the copy overlay
            // offsets past, and the row height is unchanged. Where the two rectangles overlap the
            // copy button wins — it is drawn in the overlay above this row, which is the right
            // outcome: that band is where the copy glyph is.
            .padding(-((CopyFeedbackButton.hitSize - Self.warningSlotWidth) / 2))
            .hoverTooltip(Self.warningTooltip(for: warning, refreshable: true, connectPrompt: noticeIsConnectPrompt))
            .accessibilityLabel(warning)
        } else {
            // Centered in the same slot as the button branch above, so the glyph sits in exactly one
            // place whether or not it carries an action.
            glyph
                .frame(width: Self.warningSlotWidth)
                .hoverTooltip(warning)
                .accessibilityLabel(warning)
        }
    }

    /// The triangle's tooltip: the notice, plus the click affordance when the glyph is actionable —
    /// nothing else on screen says the symbol can be clicked. Provider messages are sentences ("Not
    /// logged in. Run `codex` to authenticate."), so the hint joins as one more sentence; a message
    /// that arrives without end punctuation gets a period first. A connect prompt names its own
    /// verb — the click loads the credential, it doesn't fix anything.
    static func warningTooltip(for warning: String, refreshable: Bool, connectPrompt: Bool = false) -> String {
        let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard refreshable, !trimmed.isEmpty else { return trimmed }
        let terminated = trimmed.last.map { ".!?".contains($0) } ?? false
        return "\(trimmed)\(terminated ? "" : ".") Click to \(connectPrompt ? "connect" : "refresh")."
    }
}

private extension View {
    /// Centers a glyph on the cap height of the header's name within a `.firstTextBaseline` row.
    /// Plain center alignment centers on the name's line box instead, whose ascender space is
    /// taller than its descender space, so a glyph rides visibly above the letters it sits beside.
    func centeredOnHeaderCapHeight() -> some View {
        alignmentGuide(.firstTextBaseline) { $0.height / 2 + ProviderSectionHeader.nameCapHeight / 2 }
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    private let density = DensitySetting.compact

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
