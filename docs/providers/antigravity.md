# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity has two shared quota pools, and each pool has a rolling 5-hour window and a weekly window:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, and others), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |

When Antigravity reports your subscription tier (such as `Pro` or `Ultra`), Runway shows it beside the provider name.

Gemini Pro and Gemini Flash are one pool, so Runway shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers. Every non-Gemini model shares the second pool, shown under the Claude name. Quotas are reported as a fraction, so there are no token or dollar spend tiles.

When a pool's 5-hour window has no usage yet, that meter reads **Not started** instead of a reset countdown. Hover it for an explanation. The weekly meters always show a reset countdown.

## Where credentials come from

Runway reads what Antigravity already has:

- **Antigravity running**: Runway talks to the app's local language server. This is the richest source and where the plan name comes from.
- **App closed**: Runway falls back to the OAuth token Antigravity and `agy` store in your macOS Keychain and queries Google's Cloud Code API. Runway refreshes an expired token itself and never writes back to Antigravity's keychain item. It reuses its short-lived cache only while the same Keychain login is present and readable.

If neither is available you see *Start Antigravity or run `agy` and try again.*

## Troubleshooting

- **"Start Antigravity or run `agy`…"**: sign in to the Antigravity app or run `agy` so a usable token exists, then refresh. A manual refresh (⌘R) looks for the local server immediately. The automatic 5-minute passes find it within about 15 minutes of it starting.
- **"Antigravity login found in Keychain"** (neutral key glyph): the item is present, but automatic refreshes do not request its secret. Connect to load it. Choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the Antigravity login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Couldn't read Antigravity credentials from Keychain"**: the keychain itself could not be read, usually because it is locked. Unlock it, then refresh.
- **"Couldn't read Antigravity credentials…"**: unlock Keychain, or sign in to Antigravity again. Runway does not use its cached access token until the current login can be verified.
- **The weekly meters show "No data"**: your Antigravity build does not expose the quota-summary endpoint yet. The 5-hour meters still work from the older endpoints. Updating Antigravity brings the weekly meters back.
- **A meter shows "No data"**: that pool or window was not in the latest response. Some tiers only report certain windows. The other meters still update.
- **Where did the Gemini Pro and Flash meters go?** They merged. Both models draw from the one shared Gemini pool, which is now the Session meter.
- **Quotas look full after heavy use**: the 5-hour windows reset on a rolling basis and the weekly windows once a week. The reset time is on each meter.

## Under the hood

Best source first: the local language server, found by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. Runway binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential, so logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source Runway asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code). That is the only endpoint that reports the merged pools and the weekly windows. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction. Those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field.

> Reverse-engineered from the app and language-server binary. Endpoints and storage can change without notice.
