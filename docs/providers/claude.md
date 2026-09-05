# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code or Claude Desktop.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
| Fable | Separate weekly Fable limit (model-scoped window from the `limits` array) |
| Extra Usage | Extra-usage credits spent against your monthly cap |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Claude reports your plan name, Runway shows it beside the provider name. Runway prefers the current plan and tier in Claude Code's state file over the copies stored at sign-in, so an upgrade or downgrade shows up without signing in again.

## Where credentials come from

Sign in with Claude Code or Claude Desktop. Runway checks these sources and prefers one that can read your subscription usage:

1. The macOS keychain entry Claude Code maintains
2. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. Claude Desktop's encrypted login cache, when no working Claude Code login is available
4. The `CLAUDE_CODE_OAUTH_TOKEN` environment variable

**Claude Desktop** support is read-only. Runway decrypts Desktop's current access token using the `Claude Safe Storage` item in your macOS Keychain. It never reads or uses Desktop's refresh token, and never changes Desktop's config, cookies, or Keychain entry, so it cannot invalidate Desktop's session. Recent Desktop builds store tokens under account-prefixed cache keys. Runway reads those as well as the older format, and only uses entries that belong to the signed-in Desktop account.

**Keychain reads.** Launch-time and background refreshes never request Claude's Keychain secrets. After launch or a credential change, the card shows a neutral **Connect** action. That manual read is cached in memory for the running session while the item's non-secret metadata is unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If Desktop's token expires, open Claude Desktop so it can renew the login, then refresh Runway. Several Claude cards share the same cached read. Claude Desktop's `Claude Safe Storage` key is handled the same way: a manual read derives the decryption key and caches it for the rest of the process.

A Claude Code Keychain item stays higher priority than a home-file or Desktop login even before access is approved. Runway reports that approval is needed instead of showing usage from a possibly stale home file or a different Desktop account. If macOS cannot tell whether the item exists (for example while the login keychain is locked), Runway asks you to unlock the keychain.

First-run detection checks Claude Desktop's files and Keychain metadata without requesting the secret. Leftover or corrupt Desktop files, and malformed Claude Code credentials found during a manual read, do not enable Claude by themselves.

If you cancel or deny a Claude Code approval prompt during a manual refresh, Runway stops there. It does not repeat the prompt through a broader lookup or open a Claude Desktop prompt.

**Environment token.** A `CLAUDE_CODE_OAUTH_TOKEN` (usually a long-lived `claude setup-token`) can run the model but cannot read your Session and Weekly limits, and it often lingers in your shell. When a real keychain or file login is present, Runway uses that login for the live meters and keeps the environment token as a fallback. If the environment token is your only credential (a headless setup), it is used on its own and the spend tiles still load from local logs.

If one source holds an expired or locked-out token, Runway falls back to the others, so signing in again with `claude` is picked up on the next refresh without restarting Runway.

**Token renewal.** Claude Code owns its login, and Runway defers to it. When a stored token has already been expired for a while, so no live Claude Code session can be mid-rotation, Runway renews it the same way Claude Code would and writes the rotated credential back to the store it came from (the Keychain item or `.credentials.json`), keeping one token chain. Two apps rotating the same login independently can trip the server's token-reuse protection and sign you out everywhere, so Runway only renews after expiry, only after verifying it can write the result back, and never for Claude Desktop's login. If renewal is not possible (a guard declines, or the refresh token itself is revoked), the live Session and Weekly meters pause and the Claude header shows **"Claude login needs renewal"**. Open Claude Code so it mints a fresh login, then refresh Runway. The local spend tiles keep working. To turn renewal off:

```sh
defaults write com.mattstallone.runway runway.claude.disableTokenRefresh -bool true
```

## The spend tiles

Today, Yesterday, and Last 30 Days are computed locally. Runway reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`). Symlinks are followed, so a projects folder linked into a synced location is read too. Claude usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too. Runway reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Claude usage there into the same tiles and trend. pi records its own per-message cost, so those dollars come from pi and are not re-estimated. Cowork (the Claude desktop app's agent mode) writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and Runway scans those as well. Persisted `claude -p` runs count too. Runs made with `--no-session-persistence` cannot appear because Claude writes no session log for them. Advisor work recorded inside a message is counted once under the advisor's own model. The parent's main-model totals are kept separate, and ordinary iteration details are not counted again. A log's recorded fast or standard speed controls its price. Runway does not infer speed from the event date.

Days are grouped in your Mac's local time zone. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`). A day with no usage reads **No data**. The dollars are estimated from token counts at API rates using the shared [model pricing](../pricing.md). The token counts are measured. No log data leaves your Mac. The spend tiles also load when there is no Claude OAuth login (for example an API-key gateway) as long as the local logs exist. The header then shows **Not logged in** because Session and Weekly cannot load.

## Multiple accounts

If you keep more than one Claude login on this Mac using custom config dirs (separate `CLAUDE_CONFIG_DIR` homes, each with its own sign-in), Runway finds them at launch and gives each account its own card, with its own limits, plan, and spend tiles. A custom dir signed into the same account as your main login does not become a second card. Its session logs count into the main card's spend tiles.

With one account, the default name is "Claude". With multiple accounts, every card includes its account email (for example "Claude — dev@example.com"), including the first card. An organization name appears after the email when available. If two accounts still have the same label, Runway adds a short stable account code. If the only login lives in a custom config dir, it is the sole Claude card. Right-click a card and choose **Rename…** (or use the Name field in Customize) to name it yourself. A card only shows while its login is still found on this Mac. Log it out or delete the dir and the card disappears, keeping its customization and history in case it returns. Turn a card off like any provider in Customize.

An ambient `CLAUDE_CODE_OAUTH_TOKEN` cannot identify its account. When a separate account card is also discovered, default-home local spend stays available under a "Claude — Environment Token" card. A leftover Claude state file, or a malformed or tokenless stored credential beside it, does not lend an old account name to that card.

In the [CLI](../cli.md) and [local API](../local-http-api.md), extra cards appear under ids like `claude@ab12cd34`. Requesting `claude` returns every Claude card.

## Troubleshooting

- **"Not logged in"**: run `claude` to sign in, then refresh. If local session logs exist, the spend tiles still show. Session and Weekly stay empty until you sign in.
- **"Claude Code login found"** (neutral key glyph / **Connect** button): the login exists but has not been loaded this session. Connect, and choose **Always Allow** if macOS asks for access to `Claude Code-credentials`.
- **"Keychain access to the Claude Code login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Claude Code credentials couldn't be checked"**: unlock your login keychain, then refresh.
- **"Claude Desktop login found"** (neutral): connect, and choose **Always Allow** if macOS asks for access to `Claude Safe Storage`.
- **"Keychain access to the Claude Desktop login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Claude Desktop login is stale"** (amber warning): open Claude Desktop so it can renew the login, then refresh.
- **"Claude login needs renewal"** (amber warning): every stored login has an expired or revoked token, and Runway's own renewal could not recover it (usually the refresh token itself is revoked). Open Claude Code, then refresh. The spend tiles keep working.
- **"Re-login for live usage"** (amber warning): your saved login can authenticate for inference but cannot read your subscription limits, because it lacks `user:profile` access (an inference-only token from `claude setup-token`). Run `claude` and sign in again with your Claude account, then refresh. The spend tiles keep working.
- **"Updates blocked by Anthropic"** (amber warning): the usage API is throttling Runway. It keeps the last values, shows when it will retry, and backs off. A different login starts with a fresh cache and cooldown. This is the one header warning you cannot click to refresh, because manual refreshes extend the block.
- **Spend tiles show "No data"**: Runway found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and Runway look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the selected OAuth token. An already-expired token gets one guarded renewal at the token endpoint (`POST https://platform.claude.com/v1/oauth/token`, Claude Code's own public client), with the rotated credential written back to its store. If a token is expired or revoked and renewal declines, Runway tries the next credential source, and when none is left it shows the renewal notice over the local spend tiles.

When the 5-hour session window has no usage yet, the Session row shows **Not started**. Hover it for an explanation.
