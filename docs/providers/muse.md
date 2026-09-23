# Muse

Tracks Muse Code subscription quota from the signed-in Meta developer dashboard, plus local token history and estimated API-rate value from Muse session logs.

## What it tracks

| Metric | Meaning |
|---|---|
| Five-Hour Usage | Usage percentage in the five-hour quota window |
| Weekly Usage | Usage percentage in the weekly quota window |
| Usage Trend | Daily tokens saved by Muse Code on this Mac |
| Today | Today's local tokens and estimated API-rate value |
| Yesterday | Yesterday's local tokens and estimated API-rate value |
| Last 30 Days | Local tokens and estimated API-rate value over the history window |

When Muse reports a subscription tier (Everyday Usage, High Usage, or Power Usage), Runway shows it beside the provider name. A pay-as-you-go `META_API_KEY` and the Muse CLI login are not used for quota reads. Five-Hour Usage and Weekly Usage start always visible and starred in the menu bar. Usage Trend and the spend tiles start on demand.

The five-hour and weekly meters are account-wide subscription pools, calculated from the dashboard's weighted usage and limits. The graph and spend rows come from local session logs and include only usage saved on this Mac. With iCloud sync on, Runway combines that machine-local history with history from your other Macs without double-counting the account-wide subscription meters.

## Where credentials come from

Runway reads the existing `llama_dev_sess` browser cookie for `dev.meta.ai` / `meta.ai` from Chrome, Arc, Brave, Edge, or Firefox. It reuses the browser-cookie reader shared with Sakana Fugu, with a Firefox reader for Muse. Runway tries matching cookies in newest-first order and uses the first readable session. One signed-in profile is sufficient; other profiles do not need a login. If Meta rejects a session, Runway tries another profile and remembers the rejected cookie for this app launch. Signing in again supplies a new cookie. With several valid Meta accounts, the newest readable session wins, which may not be the account you intended. Safari, custom Chromium data locations, and explicit profile selection are not supported.

Firefox profiles are discovered from `~/Library/Application Support/Firefox/profiles.ini` (including registered absolute paths) and the standard `Profiles/` folder. Runway reads unexpired matching cookies from each profile’s `cookies.sqlite`, including container sessions. It compares Firefox’s last-access time with Chromium’s cookie-update time to choose a session across browsers. Private-window sessions are not saved in this database and cannot be used.

Firefox stores these cookies without encryption, so reading a Firefox session needs no Keychain approval. Chromium reads use Runway's coordinated, prompt-free Keychain path. If the browser's Safe Storage key needs approval, the card offers **Connect**. A manual connection can request that approval. Cookies and decryption keys stay in memory; Runway does not save them or change the browser's login.

Runway never reads Muse CLI credentials, mints an API key, refreshes the OAuth login, or sends an inference request to measure quota. Signing in to the CLI alone is sufficient for local token history, but dashboard meters need a browser login.

## The spend tiles

Today, Yesterday, and Last 30 Days are computed locally from Muse Code session journals under `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`). Each session is an append-only `session.jsonl`. Nested `subagent/*/session.jsonl` files count too; the parent log does not already include those completions.

Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude, Codex, and Grok. The dollars are estimated from measured token counts at Meta Model API rates using the shared [model pricing](../pricing.md). Standard Muse Spark models use $1.25 input / $0.15 cached input / $4.25 output per million tokens. Contributor SKUs (`muse-spark-*-contributor`) use $0.10 / $0.002 / $0.20. Cache writes are unpublished, so they bill at the input rate. These estimates are separate from the subscription pools the dashboard reports. No log data leaves your Mac. A period with no recorded usage reads "No data".

The spend tiles still load when the live meters cannot (a Connect prompt, an expired session, or no subscription) as long as the local logs exist.

## Setup

1. Sign in to [Meta's usage dashboard](https://dev.meta.ai/usage/) in Chrome, Arc, Brave, Edge, or Firefox and check that it shows your Muse Code subscription.
2. Refresh Runway. If it offers **Connect**, allow access to your browser's Safe Storage key when macOS asks.
3. Use Muse Code as usual for local token history. Muse is detected from either the browser session or existing session logs.

Subscribe or manage the plan at [Accounts Center](https://accountscenter.meta.com/muse_code).

## Under the hood

Runway uses the same read-only JSON requests as the current Meta developer dashboard: `GET /api/portal/teams`, followed by `GET /api/portal/teams/{team_id}/subscription-quota`, both on HTTPS `dev.meta.ai`. A team with an explicitly null quota is skipped. The first available subscription is displayed; quotas from different teams or browser accounts are never added together.

Five-hour and weekly percentages are `weighted_used / weighted_limit × 100` from the `subscription_quota` object. Reset times and the source observation time come from the same object. Runway retains the precise percentage; Meta's page rounds down to whole percentages. Numeric-only tier IDs are not displayed as plan names.

These are undocumented dashboard APIs, verified against the live dashboard in September 2026. They replace the older `llm_sess` / embedded HTML approach in OpenUsage PR #1248, which no longer matched the current website during testing. Missing quota or a changed response produces an explicit warning, never invented zero usage. Cookies are never forwarded through redirects, and requests use no shared cookie jar or disk cache.

Remote fetches have a 15-minute minimum interval, including manual refreshes and failures. Concurrent refreshes share one fetch sequence, and cancellation of its owning refresh cancels the underlying work. Authentication rejection tries another browser profile; network errors and rate limits stop the sequence. A 429 honors `Retry-After` (seconds or HTTP date), with at least the same 15-minute cooldown. Transient failures retain the last reported meters, their original timestamp, and a warning. Logging out or selecting a new cookie clears the old meters. A temporary cookie-read failure hides them but preserves the session-bound cache and retry deadline; those are reused only if the same cookie becomes readable again. Local history continues refreshing independently. The request floor/cache are per running app process; relaunching starts a new process.

Spend tiles and the trend read `model_completed` events from the local journals. Muse records OpenAI-style token buckets: `input_tokens` includes cache reads and writes, and `output_tokens` already includes reasoning. Runway does not add `reasoning_tokens` or `goal_usage_attribution` totals on top of those completions.

## Troubleshooting

- **Sign in to dev.meta.ai**: open the usage dashboard in a supported browser with the account that owns your Muse subscription. A CLI login is not a dashboard session.
- **Meta browser session found / Connect**: allow Runway to read your browser's Safe Storage key. Local spend still works while disconnected.
- **Browser session expired**: sign in to dev.meta.ai again and refresh Runway.
- **No subscription quota is available**: confirm the browser dashboard shows Muse subscription meters. An account without a subscription, or a changed dashboard format, can leave those meters unavailable.
- **Last reported usage / rate limited**: Runway is showing the last successful observation and will retry after its cooldown. Repeated refresh clicks do not bypass the cooldown.
- **Spend tiles show No data**: complete a Muse Code turn so a session journal is saved under `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`).
- **Changed `XDG_DATA_HOME`**: relaunch Runway; shell home overrides are pinned for one app launch.

When Weekly is Always Visible and exhausted, the dashboard replaces its bar with **Usage Exhausted** and a live countdown plus the reset date and time, and temporarily hides the other Always Visible bars until a refresh reports available usage. On Demand rows and saved settings are preserved; independent model pools affect only their own session bar. See [Dashboard](../dashboard.md) for details.

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
