import SwiftUI

/// An off-screen, branded PNG of one provider's usage, rendered for the right-click "Share Screenshot"
/// action. It is a static snapshot — no drag grips, spinners, staleness tags, or refresh warnings — that
/// mirrors what the provider's card currently shows in the popover (respecting whether the caret is
/// expanded), drawn at the popover's own scale and rasterized at ×4 for a crisp, large share image.
///
/// The layout is intentionally not a fixed canvas: the card height grows with its rows, so a collapsed
/// provider exports a short card and an expanded one a tall one, with little wasted whitespace. The view
/// takes already-resolved `[WidgetData]` (not a store), so it has no environment dependency and renders
/// the same way in the app and in tests. It paints an opaque `Theme.traySurface` background (an
/// `ImageRenderer` has no window backdrop) and forces the appearance via `.environment(\.colorScheme, …)`
/// so a Light-mode user gets a light card even when the OS is in dark mode.
struct ShareCardView: View {
    let provider: Provider
    var plan: String?
    let rows: [WidgetData]
    let appearance: ColorScheme
    /// Index in `rows` where the On Demand rows begin (the Always Visible count): where the divider
    /// goes, and a hard boundary for tiles and condensing, as on the live dashboard. `nil` when the
    /// provider is collapsed (no expanded section).
    var expandBoundaryIndex: Int? = nil
    /// The column count the provider's accounts share for their Always Visible limits, so the
    /// export lays its tiles out as the card on screen does.
    var limitColumns: Int? = nil
    /// The live card title when it differs from the launch-baked `provider.displayName` (a rename can
    /// land mid-session). Passed explicitly — this view renders in an `ImageRenderer`, outside the
    /// app's environment, so it can't read the account registry itself.
    var displayNameOverride: String? = nil
    /// The dashboard's compact notice for unavailable rows, shown alongside any available metrics.
    /// The export omits the Refresh button because a static image cannot perform the action.
    var errorMessage: String? = nil
    /// Whether the notice asks the user to connect a credential.
    var errorIsConnectPrompt: Bool = false

    /// Authored card width in points. The renderer multiplies this by `ShareCardRenderer.scale` for the
    /// PNG's pixel width; the height is whatever the rows add up to (flexible).
    static let width: CGFloat = 360

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            metricsCard
        }
    }

    // MARK: - Header

    /// Provider mark + name (+ optional plan), leading — logo, then name, then plan — at the popover's
    /// type scale so it sits in proportion to the rows. Static: no drag grip, spinner, staleness tag, or
    /// warning triangle.
    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 22, height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayNameOverride ?? provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    /// The provider's visible metric rows in the shared card surface, reusing `WidgetRowView` so the
    /// exported card matches the live dashboard exactly. Toggles are nil (static render). An empty
    /// provider falls back to a quiet placeholder so the card never renders blank.
    @ViewBuilder
    private var metricsCard: some View {
        DashboardMetricCard {
            if let errorMessage {
                ProviderErrorCardView(
                    message: errorMessage,
                    isRefreshing: false,
                    showsRefreshAction: false,
                    style: errorIsConnectPrompt ? .connect : .warning,
                    onRefresh: {}
                )
            }
            if rows.isEmpty, errorMessage == nil {
                Text("No metrics to show")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            StaticMetricRows(rows: rows, expandBoundaryIndex: expandBoundaryIndex, limitColumns: limitColumns)
        }
    }
}
