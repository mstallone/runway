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

When you have the Go subscription, Runway shows "Go" beside the provider name.

The Session, Weekly, and Monthly meters are account-wide, the same percents the OpenCode dashboard shows, including usage from other machines. If you only use the Zen gateway (no Go subscription), the cap meters are hidden and you see the spend tiles.

## Where credentials come from

Use OpenCode as usual. Runway reads the `opencode-go` API key from OpenCode's local data directory (`~/.local/share/opencode/auth.json`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if set) and sends it as a Bearer token to the usage API. There is no login prompt and no token to paste. Spend tiles read the local SQLite logs in that same directory.

## The meters and spend tiles

Go meters are percents from `GET https://opencode.ai/zen/go/v1/usage`, OpenCode's own accounting. Each spend tile shows cost and tokens together (`$4.08 · 1.2M tokens`). Those dollars come from the per-message cost OpenCode records for its hosted gateways on this Mac, so they can be lower than account-wide Go usage. A period with no recorded local usage reads "No data". No log data leaves your Mac.

## Troubleshooting

- **No Session / Weekly / Monthly meters**: those are Go-plan windows. You see them when you are logged into OpenCode Go (`opencode-go` in `auth.json`) and the key has an active subscription. Zen-only users see the spend tiles instead.
- **"OpenCode Go key was rejected"**: the local key was not accepted. Log into OpenCode Go again so `auth.json` is rewritten.
- **"No OpenCode Go subscription on this key"**: the key is valid but this account is not on Go. The spend tiles still work if you use Zen locally.
- **"Couldn't read OpenCode's auth.json"**: the file exists but is unreadable or not valid JSON. Check its permissions, or log into OpenCode Go again to rewrite it.
- **Spend tiles show "No data"**: Runway needs OpenCode's local database at `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh.
- **"Couldn't read OpenCode's local database"**: the database or data directory exists but could not be read this refresh. If you are on Go, the percent meters still refresh. Quit OpenCode and refresh to restore the tiles. If it persists, check the permissions on `~/.local/share/opencode`.

## Under the hood

Go windows: `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key as `Authorization: Bearer …`. The response is `{ usage: { rolling, weekly, monthly } }`, each with `percent` and `resetsAt`. A 401 is a rejected key. A 403 `EntitlementError` means no Go subscription.

Spend tiles and trend: assistant-message `cost` and token fields from every `opencode*.db` in the data directory. OpenCode partitions its database by release channel (stable is `opencode.db`, the preview line is `opencode-next.db`), so all channels are combined. Both `opencode-go` (Go) and `opencode` (Zen) count. Read-only.
