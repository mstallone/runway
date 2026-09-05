# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits, a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"). Off by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (`2 available`) with a colored dot for the soonest expiry. Hover the value for a timeline of each credit's expiry |
| Extra Usage | Flex credits, shown as dollars and credits (`$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Codex reports your plan name, Runway shows it beside the provider name. `self_serve_business_prolite` is shown as **Business Premium**.

## Where credentials come from

Sign in with the Codex CLI (`codex`). Runway reads the same `auth.json` file or home-scoped OS keyring item (`$CODEX_HOME` respected). Codex credentials are read-only to Runway. It never refreshes a token and never writes `auth.json` or the keyring. The `codex` CLI owns the login. When the token lapses, the card shows **"Codex login needs renewal"**. Run `codex` (it renews its own login), then refresh Runway. The spend tiles keep working.

Automatic refreshes never request the keyring secret. After launch or a credential change, the card shows a neutral **Connect** action. That manual read is cached in memory for the running session while the item's non-secret metadata is unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If the login keychain cannot be inspected (it is locked, say), the card asks you to unlock it.

## Multiple accounts

Runway discovers Codex homes at launch and gives every distinct ChatGPT account its own card. Each card has its own limits, plan, spend logs, cached data, and reset-credit actions. If the same account is signed in under more than one home, Runway keeps one card and combines those homes' session logs. Pi's Codex usage and OpenCode's ChatGPT OAuth usage identify only the provider family, so Runway assigns those slices to the account in the default Codex home. When no account holds the default home, those slices are left unattributed.

Discovery checks `~/.codex` and `~/.config/codex`, dot-directories in your home folder, directories directly under `~/.config`, and every entry in `CODEX_HOME`. Runway accepts a comma-separated `CODEX_HOME` list for discovery. A single Codex CLI process still uses one home at a time. For example:

```sh
CODEX_HOME="$HOME/.codex-work" codex
CODEX_HOME="$HOME/.codex-personal" codex
```

A discovered home must contain a usable OAuth login that names its account through Codex's own account id. For file storage, that identity comes from `auth.json`. For keyring storage, a user-attended **Refresh All** reads the exact home-scoped item and binds the account identity to that item's non-secret fingerprint. The card appears on the next launch. Replacing the keyring item invalidates the binding, so the home stays hidden until the new login is rebound.

Runway never treats a directory name as identity. Every card is pinned to one credential home and reads only that home's file or keyring item. That keeps tokens, session logs, cached snapshots, and reset claims from crossing between accounts when homes are added, removed, or swapped.

With one account, the default name is "Codex". With multiple accounts, every card includes its account email, including the first card. An organization name appears after the email when available. If two accounts still have the same label, Runway adds a short stable account code. If the only login lives in a custom home, it is the sole Codex card.

Additional cards use stable ids such as `codex@ab12cd34`. You can rename any Codex card from its context menu or Customize. CLI and local API queries for `codex` return every Codex card. Querying the full card id selects one.

## The spend tiles

Today, Yesterday, and Last 30 Days are computed locally. Runway reads the Codex CLI's session rollouts under `~/.codex/sessions/` and `archived_sessions/` (or `$CODEX_HOME`). Symlinks are followed. Codex usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too. Runway reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Codex usage there into the same tiles and trend. pi records its own per-message cost when it has one, so those dollars come from pi. Zero-cost Codex rows (subscription usage pi does not price) are estimated with the same Codex request rules as native logs. The same applies when OpenCode uses its built-in ChatGPT Pro/Plus OAuth login: Runway reads the `openai` rows from OpenCode's local database and attributes them to Codex. OpenCode API-key traffic is not included. Days are grouped in your Mac's local time zone. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`). A day with no usage reads **No data**.

The dollars are estimated from token counts at API rates using the shared [model pricing](../pricing.md). Sessions that ran on the fast/priority service tier, as recorded in each session's own log, use the fast rates for those turns. Older logs without tier metadata price at standard rates. Runway does not consult the current `config.toml`, so a tier change never reprices past days. Auto-review usage keeps its `codex-auto-review` name in the model breakdown, and its cost uses the dated model fallback available for that event. The token counts are measured. Subagent and forked sessions copy their parent session's token history into their own log. Runway recognizes those copies and counts each token once. No log data leaves your Mac.

For supported GPT-5.4, GPT-5.5, GPT-5.6, and GPT-6 models, requests above 272k input tokens use OpenAI's long-context rates for the whole request. These Codex request rules apply the same way to native Codex logs and to zero-cost Codex OAuth usage imported from pi or OpenCode. Cached input uses the published cache-read discount when the pricing source provides one, otherwise the full input rate. Fast/priority estimates use each model's published Codex multiplier (for example 2.5× for GPT-5.5). Model names ending in `-fast` are normalized to their base rate before that multiplier is applied once.

## Troubleshooting

- **"Not logged in"**: run `codex` and sign in, then refresh.
- **"Codex login needs renewal"**: the stored token has expired or was revoked. Runway never renews Codex tokens, so run `codex` (it refreshes its login on start), then refresh Runway. The spend tiles keep working.
- **"Codex login found in Keychain"** (neutral key glyph): the login has not been loaded this session. Connect, and choose **Always Allow** when macOS asks for access to `Codex Auth`.
- **"Keychain access to the Codex login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **API-key-only setups** cannot read subscription usage. Sign in with your ChatGPT account instead.
- **Spend tiles show "No data"**: Runway found no qualifying Codex usage in Codex, pi, or OpenCode logs from the last 30 days. If your Codex home is custom, set `CODEX_HOME` so both the Codex CLI and Runway look in the same place.
- **OpenCode usage is missing**: OpenCode must have an `openai` OAuth credential in its `auth.json`. An OpenAI API key is excluded from Codex subscription totals.
- **A custom home doesn't become a separate card**: confirm it has a ChatGPT OAuth login and an `auth.json`, `config.toml`, or sessions directory that lets discovery recognize the home. API-key-only, tokenless, and nameless file credentials are skipped. For a keyring-only home, choose **Refresh All**, approve its `Codex Auth` item if macOS asks, then relaunch Runway so the bound account can become a card.

## Under the hood

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token, read-only. Runway never calls the token endpoint. A 401/403 shows the renewal notice instead of retrying. Session and Weekly are classified by each usage window's duration rather than by its primary/secondary slot. This matters when Codex temporarily removes one limit and moves the remaining weekly window into the primary slot. Payloads without a recognized duration fall back to primary-as-Session and secondary-as-Weekly. Response headers fill percentages missing from the corresponding window.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array, using the same duration-based classification. Runway shows the entry whose name identifies GPT-5.3-Codex-Spark. Accounts without the limit omit the entry, so the rows read "No data". Other model limits in that array are not shown.

Runway preserves Codex's reported `used_percent`. If the API reports 1% used for an untouched window, the app shows 99% left. Codex rows use the normal reset label rather than a "Not started" state. Pacing waits until enough of the window has elapsed, and something has been used, to make a projection.

The "Rate Limit Resets" row shows the reset-credit count (`2 available`) with a colored dot for the soonest expiry: blue beyond a week, yellow within a week, red within 48 hours. Runway also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call, the endpoint that lists each credit's expiry. Hover the value for a timeline of those resets, soonest first: a numbered color dot, the exact expiry time (`Jul 12 at 5:30 PM`), and the countdown (`12d 18h`). With no credits it reads `0 available` and the popover says `You have no rate limit resets`. If the dedicated call fails, the row falls back to the count in the usage body (`rate_limit_reset_credits.available_count`). That body has no per-credit expiries, so the popover shows the count and notes that expiry times are unavailable.

### Using a reset from the popover

You can spend a reset credit from that popover, the same claim the Codex CLI's "Usage limit resets" picker performs. Hover a credit in the timeline and a **Use** button appears. Clicking it expands that credit into an inline confirmation ("Immediately reset your usage limits. This can't be undone.") with **Reset** / **Cancel**. Confirming claims that credit from that card's account and resets its 5-hour and weekly windows. The app then refreshes only that Codex card so the meters and remaining count update before the success line ("Reset claimed. Enjoy!") appears.

Safeguards, because a claim is irreversible:

- Claiming is always a two-click flow behind the hover popover. Nothing is claimed automatically.
- Each claim targets one explicit credit (re-matched against a fresh credit list at claim time) and carries an idempotency key, so a retry after a network error can never spend a second credit.
- If the credit was used elsewhere meanwhile (CLI or web), the popover says it is no longer available and refreshes. If your usage does not need a reset, Codex refuses without spending the credit and the popover says so. After a claim resets usage, the remaining Use buttons disable ("nothing to reset") until the popover is reopened.
