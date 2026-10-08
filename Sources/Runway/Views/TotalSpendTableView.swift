import SwiftUI

/// The Table layout: providers down, the three periods across, the combined total on top — every
/// number at once, with no period to select. A provider with several accounts opens to list them.
struct TotalSpendTableView: View {
    let table: TotalSpendTable
    @Binding var expanded: Set<String>

    private let density = DensitySetting.compact

    private static let valueColumnWidth: CGFloat = 50
    private static let columnSpacing: CGFloat = 6

    var body: some View {
        VStack(spacing: TotalSpendCardHeight.tableRowSpacing) {
            line(leading: { Color.clear.frame(height: 1) }, cells: TotalSpendPeriod.allCases.map(\.shortLabel)) {
                $0.font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            line(leading: { name("Total", weight: .semibold) }, cells: table.totals.map(cell)) {
                $0.font(.system(size: density.supportingPointSize, weight: .semibold)).foregroundStyle(.primary)
            }
            Divider()
            ForEach(table.rows) { row in
                VStack(spacing: 0) {
                    rowView(row)
                    if row.isExpandable {
                        VStack(spacing: TotalSpendCardHeight.tableRowSpacing) {
                            ForEach(row.members) { member in
                                line(
                                    leading: { name(member.title, style: .secondary).padding(.leading, 15) },
                                    cells: member.amounts.map(cell)
                                ) {
                                    $0.font(.system(size: density.supportingPointSize)).foregroundStyle(.tertiary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.top, TotalSpendCardHeight.tableRowSpacing)
                        .accordionReveal(expanded.contains(row.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TotalSpendTable.Row) -> some View {
        let isOpen = expanded.contains(row.id)
        let content = line(
            leading: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(TotalSpendPalette.color(for: row.id))
                        .frame(width: 8, height: 8)
                    name(row.title)
                    if row.isExpandable {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            },
            cells: row.amounts.map(cell)
        ) {
            $0.font(.system(size: density.supportingPointSize, weight: .medium)).foregroundStyle(.secondary)
        }
        if row.isExpandable {
            Button {
                if isOpen { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    /// One grid line: a flexible leading cell and one fixed-width, trailing-aligned cell per period.
    private func line<Leading: View, Cell: View>(
        @ViewBuilder leading: () -> Leading,
        cells: [String],
        cellStyle: @escaping (Text) -> Cell
    ) -> some View {
        HStack(spacing: Self.columnSpacing) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, text in
                cellStyle(Text(text))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.valueColumnWidth, alignment: .trailing)
            }
        }
    }

    private func name(
        _ title: String,
        weight: Font.Weight = .regular,
        style: HierarchicalShapeStyle = .primary
    ) -> some View {
        Text(title)
            .font(.system(size: density.supportingPointSize, weight: weight))
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// A row with nothing for a period shows a dash — never a fabricated zero.
    private func cell(_ amount: Double?) -> String {
        guard let amount else { return "–" }
        return MetricFormatter.totalSpendTile(amount, metric: table.metric)
    }
}
