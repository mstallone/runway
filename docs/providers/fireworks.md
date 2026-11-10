# Fireworks

Tracks your [Fireworks](https://fireworks.ai) monthly spend against the account's monthly spend limit, using the API key the `firectl` or Nexus CLI already stored.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly Spend | Dollars spent this calendar month against the account's monthly spend limit. Resets at the start of each UTC month |

## Where credentials come from

Runway never asks for a Fireworks key. Checked in this order, first match wins:

1. **`firectl`:** `~/.fireworks/auth.ini`, written by `firectl set-api-key`. Runway reads `api_key`, and `account_id` when present.
2. **Nexus CLI:** the `FireworksAI` Keychain item written by `nexus login`. It holds only the key, so the account is looked up from the API.

When no `account_id` is set, Runway asks the API which accounts the key can see and uses the account only if there is exactly one. The lookup runs once per key while the app runs.

Automatic refreshes never show a Keychain dialog. If the Nexus item hasn't been read yet, the card offers **Connect**. Connecting or a manual refresh may ask macOS for access once; choose Always Allow to avoid future dialogs.

## Troubleshooting

- **"Not logged in"**: run `firectl set-api-key` or `nexus login`, then refresh.
- **"API key was rejected"**: the key returned 401 or 403. Log in again with either CLI.
- **"Fireworks account is unknown"**: the key sees no account or several. Add `account_id = <your-account>` to `~/.fireworks/auth.ini`.
- **"No monthly spend limit"**: the account has no `monthly-spend-usd` quota (some enterprise accounts are uncapped), so there is nothing to meter.

## Under the hood

REST calls with a `Bearer` token against `https://api.fireworks.ai/v1`:

- `GET /accounts?pageSize=2`: only when no account is known.
- `GET /accounts/{account_id}/quotas?pageSize=200`: the Monthly Spend meter is the `monthly-spend-usd` quota's `usage` against its enforced `value`. A quota with no `usage` field is a measured `$0.00`.

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
