# Codex Rate-Limit Reset Credits: How Claiming Works

Research and live verification of the Codex "reset credit" claim flow, done 2026-07-12. This is the protocol reference for the claim flow in `Sources/Runway/Providers/Codex/CodexResetClaimService.swift`.

Sources: the open-source Codex CLI (`openai/codex`, `codex-rs/backend-client/src/client/rate_limit_resets.rs`, `codex-rs/tui/src/chatwidget/reset_credits.rs`, `codex-rs/tui/src/chatwidget/usage.rs`, `codex-rs/app-server/src/request_processors/account_processor/rate_limit_resets.rs`), plus a live end-to-end claim against a real account (one credit, hours before it expired).

## What a reset credit is

OpenAI grants Codex users occasional free "rate limit resets". Redeeming one immediately resets the account's Codex rate-limit windows: on paid plans the 5-hour and weekly windows together (`windows_reset: 2`), on Free/Go plans the monthly window. Credits expire (typically 30 days after grant) and are gone once redeemed or expired.

## Endpoints

Both live under the ChatGPT backend base URL (`https://chatgpt.com/backend-api`). The CLI also has a `PathStyle::CodexApi` variant (`/api/codex/...` instead of `/wham/...`) for enterprise or alternative base URLs. Runway uses the ChatGPT style.

Headers on every call (the same ones Runway's Codex usage client sends):

- `Authorization: Bearer <access_token>` (the ChatGPT OAuth access token from `~/.codex/auth.json`)
- `ChatGPT-Account-Id: <account_id>` (from the same file)
- `Content-Type: application/json` on the POST

### List

`GET /wham/rate-limit-reset-credits`

```json
{
  "credits": [
    {
      "id": "RateLimitResetCredit_…",
      "reset_type": "codex_rate_limits",
      "status": "available",            // available | redeeming | redeemed
      "granted_at": "2026-06-12T03:57:42.677034Z",
      "expires_at": "2026-07-12T03:57:42.677034Z",   // may be null (never expires)
      "redeem_started_at": null,
      "redeemed_at": null,
      "profile_image_url": "https://…/codex-icon-200.png",
      "profile_user_id": "Codex Team",
      "title": "Full reset (Weekly + 5 hr)",
      "description": "Thanks for using Codex! You've been granted one free rate limit reset."
    }
  ],
  "available_count": 4
}
```

Redeemed and expired credits drop out of the list entirely. After the live claim the list had 3 entries, not 4 with one `redeemed`.

### Consume (the claim)

`POST /wham/rate-limit-reset-credits/consume`

```json
{
  "redeem_request_id": "<client-generated UUID v4>",
  "credit_id": "RateLimitResetCredit_…"
}
```

- `redeem_request_id`: the idempotency key, a UUID v4 minted by the client (`Uuid::new_v4().to_string()` in the TUI). The CLI generates one key per credit shown in its picker and reuses the same key when the user retries after an error, so a retry can never burn a second credit. The server replies `already_redeemed`, which the CLI treats as success.
- `credit_id`: optional. When present the server redeems exactly that credit. When omitted the server picks one. The CLI always sends it (it sorts available credits by soonest `expires_at` and lets the user pick). It omits `credit_id` only in a fallback path when the detail list could not be fetched.

Response (HTTP 200 even for the failure codes; the outcome is in `code`):

```json
{
  "code": "reset",
  "credit": {
    "id": "RateLimitResetCredit_…",
    "status": "redeemed",
    "redeem_started_at": "2026-07-12T01:47:04.448019Z",
    "redeemed_at": "2026-07-12T01:47:05.162045Z",
    …
  },
  "windows_reset": 2
}
```

`code` values (from `ConsumeRateLimitResetCreditCode` in the CLI):

| code | meaning | credit burned? |
|---|---|---|
| `reset` | success; `windows_reset` is the number of windows reset (2 = 5h + weekly) | yes |
| `already_redeemed` | the same `redeem_request_id` was already processed; treat as success | already was |
| `nothing_to_reset` | usage does not need a reset right now (CLI: "Your usage does not need a reset right now.") | no |
| `no_credit` | the targeted credit is no longer available (raced away or expired), or none available at all | no |

The consume response's `credit` object carries `redeem_started_at`, `redeemed_at`, and `profile_*` fields the CLI's own struct ignores.

## Live verification (2026-07-12, Pro plan)

The run was a one-shot Python script with hard guards (claim at most one credit, only the soonest-expiring one, only if it expired within 4 h, explicit `credit_id`). The full verbose log is kept out of the repo.

- Before: 4 credits available; 5h window 96% used (reset in about 25 min), weekly 52% used (reset in about 6 days). Target credit expired 2.18 h later.
- `POST …/consume` with a fresh UUID and explicit `credit_id`: HTTP 200, `code: "reset"`, `windows_reset: 2`, credit `status: "redeemed"`. Round-trip about 1.1 s (`redeem_started_at` to `redeemed_at` about 0.7 s server-side).
- After (fetched about 1 s later): both the 5h and weekly windows read 0% used with full window durations (`reset_after_seconds` = 18000 / 604800), `available_count` = 3, and the redeemed credit no longer appears in the list. The reset also zeroed the windows of the `additional_rate_limits` entry (the model-specific limit was already 0%, so this is suggestive, not proven).

## Implementation notes

- The claim is a single POST on infrastructure Runway already talks to. Auth, headers, and account id handling are the same as `CodexUsageClient`'s existing calls.
- Mint the `redeem_request_id` UUID when the user is shown the claim control (per credit), keep it for the duration of the interaction, and reuse it on retry. That is the CLI's double-spend protection.
- Always pass an explicit `credit_id`. Default the selection to the soonest-expiring available credit (the CLI's sort order).
- Treat `already_redeemed` as success. Surface `nothing_to_reset` as an informational message (the credit is not lost). On `no_credit` with a `credit_id`, refresh the list, because the credit raced away.
- This is an irreversible spend of a scarce grant. The UI must be an explicit user action (the CLI uses a picker plus confirmation), never automatic.
- After a successful claim, refresh usage and the credit list immediately. Both windows drop to 0% and the count decrements.
