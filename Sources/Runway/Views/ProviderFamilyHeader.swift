import SwiftUI

/// The header over a grouped account card: the provider's mark and name once, with how many
/// accounts sit beneath it. Each account inside the card carries its own `ProviderSectionHeader`
/// in its account form, which is where the plan, notices, and reordering live.
struct ProviderFamilyHeader: View {
    let provider: Provider
    let name: String
    let accountCount: Int
    /// How many of those accounts can be used right now, as far as their limits say.
    let usableCount: Int

    private let density = DensitySetting.compact
    @Environment(\.popoverPartyMode) private var partyMode

    var body: some View {
        HStack(alignment: .center, spacing: ProviderSectionHeader.itemSpacing) {
            ProviderIcon(source: provider.icon, inset: ProviderSectionHeader.markInset)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            // The provider's name leads at the header size; the count beside it and the tally at
            // the trailing edge are one step quieter, so the header reads name first across its
            // full width.
            Text(name)
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(accountCount) accounts")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(usableCount) of \(accountCount) ready")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, Theme.cardCornerRadius - density.headerIconSize * ProviderSectionHeader.markInset)
        .padding(.trailing, ProviderSectionHeader.trailingPadding)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
