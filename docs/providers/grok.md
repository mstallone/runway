# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens estimated from Grok CLI session activity |

When Grok reports your subscription tier, Runway shows it beside the provider name.

The weekly shared pool is the limit Grok enforces for unified-billing accounts (the old monthly credits meter is legacy and no longer shown). Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); Runway reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from Grok CLI's persisted session activity under `~/.grok/sessions/` (or `$GROK_HOME/sessions/`). Grok 1.x records measured token buckets and per-model totals when each turn completes; Runway reads those records directly, includes nested subagent and resumed sessions, and removes replayed turns from forked sessions. For older Grok CLI versions, Runway still falls back to `~/.grok/logs/unified.jsonl`.

Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude/Codex/Cursor. The dollars are estimated from measured token counts at public API rates using the shared [model pricing](../pricing.md) (that's the ⓘ), and these estimates are separate from the weekly subscription pool that Grok's billing API reports. No session data leaves your Mac. A period with no recorded usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Spend tiles show "No data"** — complete a Grok CLI turn so its usage is saved under `~/.grok/sessions/`, then refresh. On older Grok CLI versions, Runway needs token-bearing rows in `~/.grok/logs/unified.jsonl`.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for the weekly pool and pay-as-you-go cap — the exact call the Grok CLI itself makes — and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
