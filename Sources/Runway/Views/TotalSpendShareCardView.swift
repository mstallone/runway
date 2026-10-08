import SwiftUI

/// The branded, off-screen PNG for the Total Spend card's share action — the aggregate counterpart to
/// `ShareCardView`. Static: the metric title and period are baked into the header (no menus in an
/// image) beside the period's total, and the body reuses `TotalSpendBreakdown` (or, for the Table
/// layout, `TotalSpendTableView`) so the export is exactly
/// what the popover shows. Same authored width, opaque tray background, forced appearance, and
/// watermark footer as the per-provider card, so shared images read as one family.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let metric: TotalSpendMetric
    var style: TotalSpendBreakdown.Style = .bar
    /// Set for the Table layout: the export is then the whole grid, every period at once, instead
    /// of one period's breakdown.
    var table: TotalSpendTable?
    let appearance: ColorScheme

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            DashboardMetricCard {
                Group {
                    if let table {
                        TotalSpendTableView(table: table)
                    } else {
                        TotalSpendBreakdown(projection: projection, style: style)
                    }
                }
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
            // The table carries its own period columns and total row.
            if table == nil {
                Text(total.period.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(MetricFormatter.totalSpend(projection.centerValue, metric: metric, style: .full))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}
