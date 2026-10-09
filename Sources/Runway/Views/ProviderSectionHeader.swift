import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead; the optional plan is pinned to the trailing edge. Callers can
/// supply an optional `warning` — the latest refresh error, rendered as a small amber triangle at the
/// header's trailing edge whose hover tooltip carries the
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
    /// Set when this header names one account inside a grouped provider card (see
    /// `AccountCardGrouping`): the provider's mark and name sit once on the `ProviderFamilyHeader`
    /// above, so this header drops the mark, shows only the account's title in the quieter
    /// sub-header weight, and insets to the rows' edge. Everything else (plan, notices) is unchanged.
    var accountTitle: String?
    /// Whether the account's week is spent (see `AccountAvailability.isExhausted`): its mark and
    /// name fade, the way its icon does in the menu bar — except as an account sub-header in a
    /// grouped provider card, which keeps its title at full strength.
    var isUnavailable = false

    /// Header type and icon use the same compact layout definition as the rows beneath them.
    private let density = DensitySetting.compact
    /// Margin kept around the provider mark inside its frame (a fraction of the frame). Subtracted
    /// from the header's leading padding so the mark's ink, not its frame, meets the leading edge.
    static let markInset: CGFloat = 0.04
    /// Fixed layout slot for the warning triangle (its natural width is ~12pt at this size).
    static let warningSlotWidth: CGFloat = 14
    /// The click rectangle the notice glyph owns: a 10pt symbol is a poor target, so its button is
    /// this large while negative padding keeps its layout slot small.
    static let glyphHitSize: CGFloat = 28
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
    /// Hidden while a refresh is in flight: the spinner already says "working on it".
    private var showsWarning: Bool { warning != nil && !refreshing }

    /// The header's trailing padding: it ends the header's content on the card's corner radius.
    static let trailingPadding: CGFloat = Theme.cardCornerRadius

    init(
        provider: Provider,
        plan: String? = nil,
        warning: String? = nil,
        noticeIsConnectPrompt: Bool = false,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onWarningRefresh: (() -> Void)? = nil,
        accountTitle: String? = nil,
        isUnavailable: Bool = false
    ) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.noticeIsConnectPrompt = noticeIsConnectPrompt
        self.refreshing = refreshing
        self.staleness = staleness
        self.onWarningRefresh = onWarningRefresh
        self.accountTitle = accountTitle
        self.isUnavailable = isUnavailable
    }

    /// An account whose week is spent fades, like its icon in the menu bar. An account sub-header
    /// inside a grouped provider card stays at full strength: its rows already show the exhaustion.
    private var nameOpacity: Double { Self.nameOpacity(isUnavailable: isUnavailable, accountTitle: accountTitle) }

    static func nameOpacity(isUnavailable: Bool, accountTitle: String?) -> Double {
        isUnavailable && accountTitle == nil ? Theme.unavailableOpacity : 1
    }

    /// The rows' leading inset, which an account sub-header lines up with.
    private static let accountLeadingPadding: CGFloat = 14

    var body: some View {
        // One baseline-aligned row. The words (name, stale tag, plan) share the name's text baseline;
        // the glyphs (provider mark, spinner, notice) have no baseline of their own, so each is
        // centered on the name's cap height instead — see `centeredOnHeaderCapHeight`.
        HStack(alignment: .firstTextBaseline, spacing: Self.itemSpacing) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            if accountTitle == nil {
                ProviderIcon(source: provider.icon, inset: Self.markInset)
                    .frame(width: density.headerIconSize, height: density.headerIconSize)
                    .partyPulse(partyMode)
                    .centeredOnHeaderCapHeight()
                    .opacity(nameOpacity)
            }
            // The name is the only element that gives under width pressure (the plan and the stale
            // tag below stay whole — see their comments). A name that truncates (long account labels
            // like "Claude — demo@example.com") marquees to its ending while the header is hovered —
            // the same reveal the Total Spend legend uses.
            HoverMarqueeText(
                text: accountTitle ?? container.displayName(for: provider),
                font: accountTitle == nil
                    ? .system(size: density.headerPointSize, weight: .semibold)
                    : .system(size: density.headerPointSize - 1, weight: .medium),
                isHovered: isHovered
            )
            .foregroundStyle(.primary)
            .opacity(nameOpacity)
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
            Spacer(minLength: 0)
            // The plan always sits at the trailing edge, so every card's is found in one place
            // whatever the name's length.
            if let plan {
                ProviderPlanBadge(plan: plan)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // The warning sits at the far trailing edge — a header-level status instead of crowding
            // the name.
            // Hidden while a refresh is in flight: the spinner already says "working on it", and the
            // refresh may be about to clear the error.
            if showsWarning, let warning {
                warningTriangle(warning)
                    .centeredOnHeaderCapHeight()
            }
        }
        // Both ends of the header land on the corner radius of the card beneath it: the mark's ink
        // starts, and the plan ends, exactly where the card's rounded corners give way to its
        // straight top edge, with no further padding.
        .padding(
            .leading,
            accountTitle == nil
                ? Theme.cardCornerRadius - density.headerIconSize * Self.markInset
                : Self.accountLeadingPadding
        )
        .padding(.trailing, Self.trailingPadding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `NSPanel.orderOut` retains this SwiftUI tree and may not deliver a hover exit (the legend
        // row's rule). Clear the hover at the panel's authoritative close signal so a reopened
        // popover can't start with a marquee still holding a scroll position from the previous
        // session, which read as the name "starting from the middle".
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible { isHovered = false }
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
                    .frame(width: Self.glyphHitSize, height: Self.glyphHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A 10pt glyph is a poor click target, so the button owns a 28pt hit rectangle while
            // the negative padding collapses its LAYOUT footprint back to the fixed slot, leaving
            // the row's height and spacing unchanged.
            .padding(-((Self.glyphHitSize - Self.warningSlotWidth) / 2))
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
