# OpenCode

Tracks your OpenCode-hosted usage: the **Go** subscription and the **Zen** pay-as-you-go gateway. Go plan windows come from OpenCode's usage API. Spend tiles and the usage trend come from OpenCode's logs on your Mac.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Go usage in the rolling 5-hour window, as a percent, with the reset countdown |
| Weekly | Go usage this week, as a percent (resets Monday UTC) |
| Monthly | Go usage this billing cycle, as a percent |
| Today / Yesterday / Last 30 Days | Local cost and tokens across all your OpenCode-hosted usage (Go and Zen) |
| Usage Trend | A day-by-day chart of tokens over the last month |

When you have the Go subscription, Runway shows "Go" in the provider's header.

The Session, Weekly, and Monthly meters are account-wide, the same percents the OpenCode dashboard shows, including usage from other machines. If you only use the Zen gateway (no Go subscription), the cap meters are hidden and you see the spend tiles.

## Where credentials come from

Use OpenCode as usual. Runway reads the `opencode-go` API key from OpenCode's local data directory (`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if set) and sends it as a Bearer token to the usage API. There is no login prompt and no token to paste. Runway only reads OpenCode's login. It never writes or refreshes it. Spend tiles read the local SQLite logs in that same directory.

OpenCode 2 keeps the key in its local databases. OpenCode 1 keeps it in `auth.json`. OpenCode 2 leaves the old `auth.json` behind after an upgrade, so once any database holds OpenCode 2 credentials Runway ignores that file. Logging out of Go in OpenCode 2 is respected.

## The meters and spend tiles

Go meters are percents from `GET https://opencode.ai/zen/go/v1/usage`, OpenCode's own accounting. Each spend tile shows cost and tokens together (`$4.08 · 1.2M tokens`). Those dollars come from the per-message cost OpenCode records for its hosted gateways on this Mac, so they can be lower than account-wide Go usage. A period with no recorded local usage reads "No data". If the usage API request fails (a rejected key, no connection, a server error), the spend tiles and trend still load from your logs, and the card shows the failure as a notice in place of the Go meters. Codex usage that goes through OpenCode's ChatGPT OAuth login is attributed to the Codex card, not these spend tiles. No log data leaves your Mac.

## Troubleshooting

- **No Session / Weekly / Monthly meters**: those are Go-plan windows. You see them when you are logged into OpenCode Go and the key has an active subscription. Zen-only users see the spend tiles instead.
- **"OpenCode Go key was rejected"**: the local key was not accepted. Log into OpenCode Go again. Spend tiles from your local logs still show.
- **"No OpenCode Go subscription on this key"**: the key is valid but this account is not on Go. The spend tiles still work if you use Zen locally.
- **"Couldn't read OpenCode's saved login"**: OpenCode's login storage exists but could not be read. That is a database in the data directory for OpenCode 2, or `auth.json` for OpenCode 1. Runway does not fall back to an older copy of the login. Quit OpenCode and refresh, check the permissions on the data directory, or log into OpenCode Go again.
- **Spend tiles show "No data"**: Runway needs OpenCode's local database at `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh.
- **"Couldn't read OpenCode's local database"**: the database or data directory exists but could not be read this refresh. If you are on Go, the percent meters still refresh. Quit OpenCode and refresh to restore the tiles. If it persists, check the permissions on `~/.local/share/opencode`.

## Under the hood

Go windows: `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key as `Authorization: Bearer …`. The response is `{ usage: { rolling, weekly, monthly } }`, each with `percent` and `resetsAt`. A 401 is a rejected key. A 403 `EntitlementError` means no Go subscription.

Spend tiles and trend: assistant-message `cost` and token fields from every `opencode*.db` in the data directory. OpenCode partitions its database by release channel (stable is `opencode.db`, the preview line is `opencode-next.db`), so all channels are combined. Both `opencode-go` (Go) and `opencode` (Zen) count. OpenCode 1 logs to the `message` table and OpenCode 2 to `session_message`. Both are read, and completed context compactions count too. OpenCode 2 copies old messages into the new table under the same ID, so each message is counted once. Read-only.

Go key: the current `opencode-go` row of the `credential` table in each `opencode*.db`, in file-name order. The first key found is used. `auth.json` is read only when no database has a `credential` table.

When Weekly is Always Visible and exhausted, the dashboard replaces its bar with **Usage Exhausted** and a live countdown plus the reset date and time, and temporarily hides the other Always Visible bars until a refresh reports available usage. On Demand rows and saved settings are preserved; independent model pools affect only their own session bar. See [Dashboard](../dashboard.md) for details.

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
