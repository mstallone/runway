# Muse

Tracks Muse Code subscription quota using the Meta account login from the official `muse` CLI, plus local token history and estimated API-rate value from Muse session logs.

## What it tracks

| Metric | Meaning |
|---|---|
| Five-Hour Usage | Usage percentage in the rolling five-hour prompt window |
| Weekly Usage | Usage percentage in the weekly quota window |
| Usage Trend | Daily tokens saved by Muse Code on this Mac |
| Today | Today's local tokens and estimated API-rate value |
| Yesterday | Yesterday's local tokens and estimated API-rate value |
| Last 30 Days | Local tokens and estimated API-rate value over the history window |

When Muse reports a subscription tier (Everyday Usage, High Usage, or Power Usage), Runway shows it beside the provider name. A pay-as-you-go `META_API_KEY` is not a subscription login and is not used. Five-Hour Usage and Weekly Usage start always visible and starred in the menu bar. Usage Trend and the spend tiles start on demand.

The five-hour and weekly meters are account-wide subscription pools, the same percents Muse Code shows. The graph and spend rows come from local session logs and include only usage saved on this Mac. With iCloud sync on, Runway combines that machine-local history with history from your other Macs without double-counting the account-wide subscription meters.

## Where credentials come from

Runway reads what Muse Code already stored:

- **macOS Keychain**: service `ai.meta.dev.credentials`, account `meta`. Current `muse login` builds keep the OAuth access token there. Automatic refreshes never request its secret. After launch, the card shows a neutral **Connect** action. Choose **Always Allow** to avoid a dialog on future manual reads.
- **Legacy `auth.json`**: `$MUSE_AUTH_PATH`, or `$XDG_CONFIG_HOME/muse/auth.json`, or `~/.config/muse/auth.json`. Older CLIs wrote `access_token` in this file. Current files only point at Keychain and carry no secret.

Runway never writes the Keychain item, never refreshes the OAuth login, and never saves the API key snapshot the key-mint endpoint returns. Muse Code owns its login.

## The spend tiles

Today, Yesterday, and Last 30 Days are computed locally from Muse Code session journals under `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`). Each session is an append-only `session.jsonl`. Nested `subagent/*/session.jsonl` files count too; the parent log does not already include those completions.

Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude, Codex, and Grok. The dollars are estimated from measured token counts at Meta Model API rates using the shared [model pricing](../pricing.md). Standard Muse Spark models use $1.25 input / $0.15 cached input / $4.25 output per million tokens. Contributor SKUs (`muse-spark-*-contributor`) use $0.10 / $0.002 / $0.20. Cache writes are unpublished, so they bill at the input rate. These estimates are separate from the subscription pools the key-mint response reports. No log data leaves your Mac. A period with no recorded usage reads "No data".

The spend tiles still load when the live meters cannot (a Connect prompt, an expired session, or no subscription) as long as the local logs exist.

## Setup

1. Install [Muse Code](https://dev.meta.ai) and run `muse login`.
2. Refresh Runway. Muse is detected from the local login or from session logs, and turns on the first time this provider is available.

Subscribe or manage the plan at [Accounts Center](https://accountscenter.meta.com/muse_code).

## Under the hood

`POST https://api.meta.ai/muse-code/key` with the Meta OAuth access token is Muse Code's key-mint call. The JSON includes subscription meters (`subs_usage.window` and `subs_usage.weekly`) plus plan metadata. Runway reads those meters and discards the minted API key. The request sends the same `x-client-id: tbh:tui` surface header Muse Code uses. That endpoint is not documented as a public API and is not safe to poll every few minutes: Meta rate-limits it, and a 429 also blocks Muse Code's own `credential.refresh`.

When Meta returns HTTP 200 with a `{title, detail, status}` error envelope (401, 429, and similar) instead of meters, Runway honors that body's `status`. A 401 or 403 is a session expiry. A 429 keeps the last good meters on screen, skips further mint calls for 15 minutes, and warns that extra refreshes make the limit worse. If Muse Code rotated the access token between attempts, Runway re-reads the Keychain item and retries the mint once.

Malformed responses and inactive subscriptions are reported as errors instead of inventing zero usage.

Spend tiles and the trend read `model_completed` events from the local journals. Muse records OpenAI-style token buckets: `input_tokens` includes cache reads and writes, and `output_tokens` already includes reasoning. Runway does not add `reasoning_tokens` or `goal_usage_attribution` totals on top of those completions.

## Troubleshooting

- **"Not logged in to Muse Code"**: run `muse login` and complete the Meta device-code sign-in. If local session logs exist, the spend tiles still show.
- **"Muse login found in Keychain"** (neutral key glyph / **Connect** button): the item is present, but automatic refreshes do not request its secret. Connect, and choose **Always Allow** to avoid a dialog on future manual reads. Spend tiles still load from local logs.
- **"Keychain access to the Muse login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Couldn't read Muse credentials from Keychain"**: the keychain itself could not be read, usually because it is locked. Unlock it, then refresh.
- **"Muse session expired"**: run `muse login` again. The saved access token was rejected. Spend tiles keep working.
- **"Updates blocked by Meta"** (amber wait triangle, meters still showing): the mint endpoint rate-limited Runway. Wait; extra refreshes extend the block and can stop Muse Code from minting a key. Spend tiles still load from local logs.
- **"Usage request failed (HTTP 429)"**: same rate limit, but there is no last-good snapshot yet. Wait, then refresh once. If session logs exist, the spend tiles still show.
- **"No active Muse Code subscription"**: the Meta login works, but this account has no Muse Code plan. Subscribe in Accounts Center, then refresh. Local spend tiles still load if session logs exist.
- **"Usage response invalid"**: the login works, but the usage payload was missing or malformed. Try again after Muse Code updates.
- **Spend tiles show "No data"**: Runway found no `model_completed` events in the last 30 days under `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`). Complete a Muse Code turn so a session journal is saved, then refresh.
- **Muse stays off after changing `MUSE_AUTH_PATH`, `XDG_CONFIG_HOME`, or `XDG_DATA_HOME` in your shell profile**: relaunch Runway. Shell home overrides are pinned for one app launch.
