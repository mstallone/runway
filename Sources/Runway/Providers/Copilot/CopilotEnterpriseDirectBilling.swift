import Foundation

/// Billing for a Copilot seat assigned with an empty organization list. Membership orgs are not
/// the billing home. Prefer GraphQL enterprise listing when the token has `read:enterprise`;
/// otherwise derive candidate slugs from `/user/orgs` and read each enterprise's Copilot usage
/// with no organization filter. Never query those orgs' own billing endpoints — a 503 there used
/// to fail the whole card.
extension CopilotProvider {
    func enterpriseDirectBillingLookup(token: String) async -> OrgBillingLookup {
        if let cached = defaults.string(forKey: Self.billingEnterpriseDefaultsKey) {
            do {
                switch try await enterpriseWideUsageLookup(enterprise: cached, token: token) {
                case .usage(let lines):
                    return .usage(lines)
                case .empty(let lines):
                    // This slug was cached after it reported Copilot usage, so its own zero is the
                    // owning enterprise's report — the same verified empty the org-managed path uses.
                    return .empty(lines, enterpriseVerified: true)
                case .forbidden, .inaccessible, .notFound:
                    defaults.removeObject(forKey: Self.billingEnterpriseDefaultsKey)
                }
            } catch {
                AppLog.warn(
                    LogTag.plugin("copilot"),
                    "enterprise AI credit lookup failed for the remembered enterprise: \(error.localizedDescription)"
                )
                return .temporarilyUnavailable
            }
        }

        switch await CopilotEnterpriseDiscovery(client: orgBillingClient).lookupSlugs(token: token) {
        case .slugs(let slugs):
            return await probeEnterpriseWideSlugs(slugs, token: token, emptyAcceptance: .singleListedSlug)
        case .noEnterprises:
            return .managed(provenEnterpriseAssociation: false)
        case .managed:
            // GraphQL listing needs `read:enterprise`. Org owners can still read enterprise REST
            // billing once the slug is known, so fall through to membership-derived candidates.
            return await membershipDerivedEnterpriseBillingLookup(token: token)
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        }
    }

    /// `/user/orgs` plus hyphen-prefix guesses, used only after GraphQL enterprise listing is denied.
    private func membershipDerivedEnterpriseBillingLookup(token: String) async -> OrgBillingLookup {
        let orgs: [String]
        do {
            let response = try await orgBillingClient.fetchUserOrgs(token: token)
            guard response.statusCode == 200 else {
                AppLog.info(
                    LogTag.plugin("copilot"),
                    "org list HTTP \(response.statusCode); skipping membership-derived enterprise billing"
                )
                return .managed(provenEnterpriseAssociation: false)
            }
            orgs = CopilotOrgBillingMapper.orgLogins(response)
        } catch {
            AppLog.warn(
                LogTag.plugin("copilot"),
                "org list fetch failed during enterprise-direct discovery: \(error.localizedDescription)"
            )
            return .managed(provenEnterpriseAssociation: false)
        }

        let slugs = CopilotOrgBillingMapper.candidateEnterpriseSlugs(fromOrgLogins: orgs)
        guard !slugs.isEmpty else {
            return .managed(provenEnterpriseAssociation: false)
        }
        return await probeEnterpriseWideSlugs(slugs, token: token, emptyAcceptance: .singleReadableSlug)
    }

    private enum EnterpriseEmptyAcceptance: Equatable {
        /// GraphQL listed these enterprises. Only a single listed slug's empty report can stand.
        case singleListedSlug
        /// Guessed from membership orgs. Extra 404s are expected; only one HTTP 200 empty can stand.
        case singleReadableSlug
    }

    private func probeEnterpriseWideSlugs(
        _ slugs: [String],
        token: String,
        emptyAcceptance: EnterpriseEmptyAcceptance
    ) async -> OrgBillingLookup {
        var sawTransientFailure = false
        var emptyCandidate: [MetricLine]?
        var readableCount = 0
        for slug in slugs {
            do {
                switch try await enterpriseWideUsageLookup(enterprise: slug, token: token) {
                case .usage(let lines):
                    defaults.set(slug, forKey: Self.billingEnterpriseDefaultsKey)
                    return .usage(lines)
                case .empty(let lines):
                    readableCount += 1
                    emptyCandidate = emptyCandidate ?? lines
                case .forbidden, .inaccessible, .notFound:
                    continue
                }
            } catch {
                sawTransientFailure = true
                AppLog.warn(
                    LogTag.plugin("copilot"),
                    "enterprise AI credit usage failed for one enterprise; trying the next: \(error.localizedDescription)"
                )
            }
        }
        let acceptEmpty: Bool
        switch emptyAcceptance {
        case .singleListedSlug:
            acceptEmpty = slugs.count == 1
        case .singleReadableSlug:
            acceptEmpty = readableCount == 1
        }
        if let emptyCandidate, !sawTransientFailure, acceptEmpty {
            return .empty(emptyCandidate, enterpriseVerified: false)
        }
        // Guessed slugs must not turn a membership 503 into a failed card. GraphQL-listed
        // enterprises still surface a transient outage so last-good totals can stay on screen.
        if sawTransientFailure, emptyAcceptance == .singleListedSlug {
            return .temporarilyUnavailable
        }
        return .managed(provenEnterpriseAssociation: false)
    }
}
