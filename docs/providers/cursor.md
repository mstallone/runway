# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance left from grants and prepaid account balance |
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Cursor Models | Cursor-native model usage percent (Grok, Composer) |
| Other Models | Third-party model usage percent |
| Grok Bot | Grok Bot weekly usage percent and reset countdown. Enabled by default, below the caret |
| Extra Usage | On-demand spend, user-scoped when available, otherwise the team aggregate. Shown as a meter when Cursor returns a limit |

When Cursor reports your plan name, Runway shows it beside the provider name.

Grok Bot has its own weekly allowance, separate from Cursor's billing-cycle meter. It uses the existing Cursor login. Signing into the Grok CLI is not required. Accounts without a personal included allowance (including pooled enterprise seats) hide the meter.

## Where credentials come from

Be signed into the Cursor app. Runway reads Cursor's local state database and its keychain entries for the session tokens. Cursor credentials are read-only to Runway. It never refreshes a token and never writes the state database or keychain. The Cursor app owns the login. When the token lapses, the card shows **"Cursor login needs renewal"**. Sign in again where that login lives (open the Cursor app, or run `agent login` if you use the Cursor CLI), then refresh Runway.

Automatic refreshes never request the keychain secrets. After launch or a credential change, the card shows a neutral **Connect** action. That manual read is cached in memory for the running session while the items' non-secret metadata is unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If the login keychain cannot be inspected (it is locked, say), the card asks you to unlock it.

## The spend tiles

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. Runway uses the exported token counts and the shared model pricing to estimate cost locally. Cursor's export can arrive late, so the newest figures can lag current activity. Runway leaves malformed rows out instead of counting them as zero. A failed download, invalid export schema, or broken CSV leaves spend history unavailable for that refresh. Each failure is recorded in the log without the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors**: open Cursor and make sure you are signed in, then refresh.
- **Some metrics missing**: Cursor omits fields depending on plan type. Missing metrics show "No data".
- **Optional lookup failed**: plan, credit-grant, prepaid-balance, Grok Bot, and request-fallback failures are nonfatal when primary usage is available. Runway records fixed, credential-free reasons in the log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), a combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise and team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend. Neither REST response is treated as the whole account snapshot by itself. All requests are read-only against the stored token. A 401/403 shows the renewal notice instead of refreshing and retrying. Optional endpoint failures are nonfatal when the other fallback response is usable and are recorded in the log. Per-day spend uses exported token counts priced through the shared [model pricing](../pricing.md). Cursor-native models (`auto`, `composer-*`) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
