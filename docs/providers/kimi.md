# Kimi

Tracks Kimi Code membership quota using the login from the official Kimi Code CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Five-Hour Usage | Usage percentage in the rolling five-hour quota window |
| Weekly Usage | Usage percentage in the shared weekly quota window |
| Extra Usage Balance | Remaining prepaid Extra Usage balance |
| Monthly Extra Usage | Extra Usage spent against the monthly cap, or the uncapped amount spent |

Kimi Code membership quota is shared between the Kimi website, the CLI, and every API key on the same account, so the values describe the account-wide pool, not just this Mac. Extra Usage rows only appear when Kimi reports a Booster wallet for the account. Runway displays the currency Kimi returns, including CNY and USD.

## Where credentials come from

Runway reads the OAuth login Kimi Code stores at:

```text
$KIMI_CODE_HOME/credentials/kimi-code.json
```

`KIMI_CODE_HOME` defaults to `~/.kimi-code`. Runway refreshes an expiring access token the same way the CLI does and saves the rotated access and refresh tokens back atomically with owner-only permissions. It uses Kimi Code's cross-process refresh lock, so the app and CLI cannot spend the same rotating refresh token at the same time.

The provider follows these Kimi Code endpoint overrides when they are exported:

- `KIMI_CODE_BASE_URL`
- `KIMI_CODE_OAUTH_HOST` (or the older `KIMI_OAUTH_HOST`)

Like Kimi Code, Runway maps a non-default base URL or OAuth host to the CLI's `kimi-code-env-<hash>.json` credential slot, so a custom service can never borrow the production Kimi login.

Bearer credentials are only sent over HTTPS. Plain HTTP is allowed only for a loopback test endpoint.

## Setup

1. Install and start [Kimi Code](https://www.kimi.com/code).
2. Run `/login` in Kimi Code and complete the browser sign-in.
3. Refresh Runway. Kimi is detected from the local OAuth credential and turns on the first time this provider is available.

An API key exported as `KIMI_API_KEY` is not used for this provider. Kimi Code's membership usage command requires its OAuth login, and API keys can point at separate Moonshot pay-as-you-go services with different billing. Treating either kind of key as a membership login could show the wrong account or send the key to the wrong service, so Runway uses the OAuth path only.

## Under the hood

Runway mirrors the CLI's membership flow:

- `GET https://api.kimi.com/coding/v1/usages` reads the quota windows and Extra Usage wallet.
- `POST https://auth.kimi.com/api/oauth/token` refreshes an expiring OAuth login.

The usage endpoint is used by Kimi Code's own `/usage` command but is not documented as a public API. Runway accepts the same response aliases as the CLI and reports malformed responses as errors instead of inventing zero usage.

## Troubleshooting

- **"Not logged in to Kimi Code"**: run Kimi Code, enter `/login`, and complete sign-in.
- **"Kimi Code session expired"**: repeat `/login`. The saved refresh token was rejected or revoked.
- **"Kimi Code credentials couldn't be read"**: check that the credential file belongs to your macOS account and is readable.
- **"Couldn't safely refresh Kimi Code credentials"**: Kimi Code is probably rotating the same token right now. Wait for it to finish, then refresh again.
- **"Kimi Code subscription usage is unavailable"**: the login works, but this account or endpoint does not expose membership usage.
- **Kimi stays off after changing `KIMI_CODE_HOME` in your shell profile**: relaunch Runway. Shell home and endpoint overrides are pinned for one app launch so every refresh uses one credential identity.
