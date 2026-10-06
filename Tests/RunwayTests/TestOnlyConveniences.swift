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

/// Test-target-only entry point that takes whole peer documents. The app remaps peers to local
/// card ids first (`PeerHistoryRemapper`) and calls the `peerHistories:` form.
extension UsageHistoryAggregator {
    static func merged(
        localSnapshots: [String: ProviderSnapshot],
        peerDocuments: [UsageHistoryDocument],
        descriptors: [String: UsageHistoryDescriptor],
        now: Date = Date()
    ) -> [String: ProviderUsageHistory] {
        var pairs: [(String, ProviderUsageHistory)] = []
        for document in UsageHistoryDocument.newestByDevice(peerDocuments) {
            for (providerID, history) in document.providers {
                pairs.append((providerID, history))
            }
        }
        return merged(localSnapshots: localSnapshots, peerHistories: pairs, descriptors: descriptors, now: now)
    }
}
