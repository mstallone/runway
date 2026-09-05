# Muse

Tracks Muse Code subscription quota using the Meta account login from the official `muse` CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Five-Hour Usage | Usage percentage in the rolling five-hour prompt window |
| Weekly Usage | Usage percentage in the weekly quota window |

When Muse reports a subscription tier (Everyday Usage, High Usage, or Power Usage), Runway shows it beside the provider name. A pay-as-you-go `META_API_KEY` is not a subscription login and is not used. Both meters start always visible and starred in the menu bar.

## Where credentials come from

Runway reads what Muse Code already stored:

- **macOS Keychain**: service `ai.meta.dev.credentials`, account `meta`. Current `muse login` builds keep the OAuth access token there. Automatic refreshes never request its secret. After launch, the card shows a neutral **Connect** action. Choose **Always Allow** to avoid a dialog on future manual reads.
- **Legacy `auth.json`**: `$MUSE_AUTH_PATH`, or `$XDG_CONFIG_HOME/muse/auth.json`, or `~/.config/muse/auth.json`. Older CLIs wrote `access_token` in this file. Current files only point at Keychain and carry no secret.

Runway never writes the Keychain item, never refreshes the OAuth login, and never saves the API key snapshot the key-mint endpoint returns. Muse Code owns its login.

## Setup

1. Install [Muse Code](https://dev.meta.ai) and run `muse login`.
2. Refresh Runway. Muse is detected from the local login and turns on the first time this provider is available.

Subscribe or manage the plan at [Accounts Center](https://accountscenter.meta.com/muse_code).

## Under the hood

`POST https://api.meta.ai/muse-code/key` with the Meta OAuth access token is Muse Code's key-mint call. The JSON includes subscription meters (`subs_usage.window` and `subs_usage.weekly`) plus plan metadata. Runway reads those meters and discards the minted API key. The request sends the same `x-client-id: tbh:tui` surface header Muse Code uses. That endpoint is not documented as a public API and is not safe to poll every few minutes: Meta rate-limits it, and a 429 also blocks Muse Code's own `credential.refresh`.

When Meta returns HTTP 200 with a `{title, detail, status}` error envelope (401, 429, and similar) instead of meters, Runway honors that body's `status`. A 401 or 403 is a session expiry. A 429 keeps the last good meters on screen, skips further mint calls for 15 minutes, and warns that extra refreshes make the limit worse. If Muse Code rotated the access token between attempts, Runway re-reads the Keychain item and retries the mint once.

Malformed responses and inactive subscriptions are reported as errors instead of inventing zero usage.

## Troubleshooting

- **"Not logged in to Muse Code"**: run `muse login` and complete the Meta device-code sign-in.
- **"Muse login found in Keychain"** (neutral key glyph / **Connect** button): the item is present, but automatic refreshes do not request its secret. Connect, and choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the Muse login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Couldn't read Muse credentials from Keychain"**: the keychain itself could not be read, usually because it is locked. Unlock it, then refresh.
- **"Muse session expired"**: run `muse login` again. The saved access token was rejected.
- **"Updates blocked by Meta"** (amber wait triangle, meters still showing): the mint endpoint rate-limited Runway. Wait; extra refreshes extend the block and can stop Muse Code from minting a key.
- **"Usage request failed (HTTP 429)"**: same rate limit, but there is no last-good snapshot yet. Wait, then refresh once.
- **"No active Muse Code subscription"**: the Meta login works, but this account has no Muse Code plan. Subscribe in Accounts Center, then refresh.
- **"Usage response invalid"**: the login works, but the usage payload was missing or malformed. Try again after Muse Code updates.
- **Muse stays off after changing `MUSE_AUTH_PATH` or `XDG_CONFIG_HOME` in your shell profile**: relaunch Runway. Shell home overrides are pinned for one app launch.
