import Foundation
@testable import Runway

/// Test-target-only query: production reads `holdsDefaultSource` where it needs it.
extension ProviderAccountsStore {
    /// The record currently holding a family's default badge, if any.
    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }
}

/// Test-target-only conveniences for pin checks that do not care about per-account applicability.
/// The app always passes `matching:`, so a dormant pin never counts against the current account.
extension LayoutStore {
    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedCount(forProvider: providerID, matching: { _ in true })
    }

    func canPin(_ descriptorID: String) -> Bool {
        canPin(descriptorID, matching: { _ in true })
    }

    func pinDenialReason(_ descriptorID: String) -> String? {
        pinDenialReason(descriptorID, matching: { _ in true })
    }

    func notePinDenied(_ descriptorID: String) {
        notePinDenied(descriptorID, matching: { _ in true })
    }
}
