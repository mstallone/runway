# Copilot

Tracks your GitHub Copilot quota using a GitHub token that Copilot tooling already left on your machine. No login flow and no browser cookies.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Share of your monthly AI-credit allotment used. On org-managed seats with no allotment, a plain count of your own credits used this cycle |
| Extra Usage | Premium interactions used beyond your included credits, once extra spend is enabled |
| AI Credits Used | Total AI credits your organization used this month, with included/additional breakdown |
| Additional Spend | Dollars your organization was billed beyond its included AI credits |
| Chat | Chat-message quota used |
| Completions | Code-completion quota used |

Runway adapts the card to the account instead of showing every Copilot metric as "No data":

- **Individual paid plans** show Credits and, when enabled, Extra Usage.
- **Individual free plans** show Chat and Completions.
- **Business and Enterprise seats** show AI Credits Used and Additional Spend, plus your own Credits count when the seat reports one.

Metrics GitHub does not expose for the current account type are hidden. The applicable usage rows are Always Visible. None of the organization metrics are pinned to the menu bar by default. Percentage meters show percent used and, when the response includes one, a countdown to the next reset. The plan name (Pro, Business, Free) shows next to the provider.

Since June 2026 GitHub Copilot bills all plans by AI credits:

- **Paid plans** meter the credit pool, so you see Credits (and Extra Usage if you have turned on additional spend). Chat and completions are unlimited on paid plans, so those rows are hidden.
- **Free plans** have no credits. You see the fixed Chat and Completions quotas GitHub reports. Both rows stay available if a refresh omits one bucket. The omitted metric shows No data until GitHub reports it again.
- **Org-managed seats** (Copilot Business or Enterprise assigned by an organization) return no per-seat percent quota. If the response's premium bucket carries a `credits_used` count, Runway shows it as **Credits**, a plain count, since there is no allotment to divide by. This is your own consumption and needs no special access. Runway also looks up usage at the seat's billing entity (its organization, or its enterprise when billing is consolidated) and shows **AI Credits Used** and **Additional Spend**. Caveats:
  - The numbers are organization-wide, not your personal share. GitHub does not expose per-seat usage.
  - Reading an org's billing requires you to be an org owner or billing manager. Regular members see a managed-account message instead of "No data" placeholders, plus their own Credits count when the response carries one.
  - When Copilot identifies the seat's organization, Runway checks its enterprise before accepting an empty organization report, because consolidated usage is billed at the enterprise level. If a proven enterprise association stays unreadable, or the seat is an Enterprise seat and the credential cannot see enterprise associations at all, Runway keeps the managed-account state. For a Business seat, when no enterprise claims the organization (or associations cannot be read), a readable empty organization report stands. At the start of a billing month the card shows zero credits used, not the managed-account message. An unrelated empty report is never attributed to the seat.
- AI Credits Used is a plain count, not a percentage. The API reports total, included, and additional usage, but not the organization's full pool, and Runway does not invent a denominator.

A dollar credit figure ("$12 of $15 used") is not shown. GitHub only exposes it through the logged-in web billing page, which requires browser cookies, and the Copilot provider does not read browser cookies. Editors like VS Code show the same credit percentage from this endpoint, not a dollar amount.

## Where credentials come from

Checked in this order (prompt-free files first, Keychain last):

1. Copilot editor token: `~/.config/github-copilot/apps.json` (older `hosts.json`), written by the VS Code, JetBrains, and Neovim Copilot plugins.
2. GitHub CLI config: `~/.config/gh/hosts.yml` (`oauth_token`), when `gh` stores its token in a file.
3. GitHub CLI Keychain item (service `gh:github.com`), when `gh` stores its token in the system keyring. Automatic refreshes never request its secret. After launch or a credential change, the card shows a neutral **Connect** action. Runway reuses that value in memory for the running session while the item's non-secret metadata is unchanged. Choose **Always Allow** to avoid a dialog on future manual reads.

The editor token is preferred for the Copilot quota endpoint. For organization and enterprise billing, Runway tries the GitHub CLI credential first when Copilot identifies the seat organization, because it can carry the required permissions, then falls back to the editor token. An empty report stays provisional until both credentials have been tried, so a credential with consolidated enterprise access can still supply the totals. When the seat organization is unknown, Runway keeps membership discovery on the credential that produced the Copilot card, so another local GitHub account cannot be mixed in.

### Setup

If usage does not appear, authenticate with the GitHub CLI:

```bash
brew install gh   # if needed
gh auth login     # choose GitHub.com and follow the prompts
```

Using Copilot in a supported editor is enough on its own. The editor writes the token to `apps.json`.

## Troubleshooting

- **"Sign in to GitHub Copilot…"**: no token was found. Sign in to Copilot in your editor, or run `gh auth login`.
- **"GitHub login found in Keychain"** (neutral key glyph / **Connect** button): `gh` keeps its token in the system keyring and it has not been loaded this session. Connect, and choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the GitHub login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"GitHub login couldn't be read"**: the login keychain is unavailable, most often locked. Unlock it and refresh.
- **"GitHub token invalid or expired"**: the token was rejected (401/403). Re-authenticate with `gh auth login`.
- **"Managed by Your Organization"**: GitHub does not expose a per-seat percent quota for Business/Enterprise, and none of the local credentials could read the organization or enterprise billing. Your own Credits count still shows when the seat reports one. Organization reporting requires organization billing access. Consolidated reporting also requires enterprise read and billing access. Some editor-plugin and GitHub CLI tokens do not carry those scopes.

## Under the hood

`GET https://api.github.com/copilot_internal/user` with the standard Copilot client headers (API version `2025-04-01`). The response reports each bucket as percent remaining. The meters show percent used.

For org-managed seats (identified by the token-based-billing placeholder in that response), Runway first uses the response's organization list to query `GET /organizations/{org}/settings/billing/ai_credit/usage?product=Copilot`. GitHub defaults that endpoint to the current year and month. If an associated organization returns 403, 404, or an empty report, Runway resolves all enterprises visible to the token through GitHub GraphQL, verifies which enterprise owns that seat organization, and queries the enterprise AI-credit endpoint filtered to that organization and Copilot. This lets an enterprise billing manager see consolidated totals even when they do not administer the seat organization. Rate-limited and other retryable REST or GraphQL failures fail that refresh, so the card keeps its last-good numbers with the usual warning treatment. Only explicit access errors show the managed-account state. If the Copilot response has no organization association, Runway falls back to `GET /user/orgs`, but only positive Copilot usage (not an empty current or cached report) can identify the seat's organization. Other AI products are excluded at the API boundary and ignored by the mapper. An org is remembered only after it reports Copilot usage.
