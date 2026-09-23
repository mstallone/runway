# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure when Devin reports no weekly quota) |
| Daily | Daily quota used (hidden when Devin hides the daily quota) |
| Extra Balance | Overage or extra-usage balance in dollars |

When Devin reports your plan name, Runway shows it beside the provider name.

## Where credentials come from

Checked in this order. The first that works wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, Runway uses the app's login instead.

## Troubleshooting

- **"Not logged in"**: run `devin auth login`, or sign into the Devin app, then refresh.
- **Weekly shows the daily figure**: when Devin reports no separate weekly quota, the daily quota is shown in the Weekly row.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as remaining and are flipped to used. No token refresh. A 401/403 switches to the next auth source.

When Weekly is Always Visible and exhausted, the dashboard replaces its bar with **Usage Exhausted** and a live countdown plus the reset date and time, and temporarily hides the other Always Visible bars until a refresh reports available usage. On Demand rows and saved settings are preserved; independent model pools affect only their own session bar. See [Dashboard](../dashboard.md) for details.

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
