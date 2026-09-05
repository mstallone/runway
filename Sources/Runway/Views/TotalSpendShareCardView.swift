import SwiftUI

/// The branded, off-screen PNG for the Total Spend card's share action — the aggregate counterpart to
/// `ShareCardView`. Static: the metric title and period are baked into the header (no menus in an
/// image), and the body reuses `TotalSpendChartBody` so the exported ring or bars are exactly
/// what the popover shows. Same authored width, opaque tray background, forced appearance, and
/// watermark footer as the per-provider card, so shared images read as one family.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let metric: TotalSpendMetric
    let chartKind: TotalSpendChartKind
    let appearance: ColorScheme

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            DashboardMetricCard {
                TotalSpendChartBody(
                    projection: projection,
                    days: total.days,
                    chartKind: chartKind
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metric.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(total.period.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
