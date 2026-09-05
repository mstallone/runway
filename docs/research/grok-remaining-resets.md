# Grok Banked Usage Resets: How Listing Works

Research and a live list (not redeem) of Grok's "Reset Available" tokens, done 2026-08-23. This is the protocol reference for the read-only row in `Sources/Runway/Providers/Grok/GrokRemainingResetsDecoder.swift`.

Sources: grok.com Settings → Usage, the `GetRemainingResets` and `RedeemReset` gRPC-web RPCs (`prod_mc_billing.ConsumerUiSvc`), plus a live list-only call with the Grok CLI OAuth token from `~/.grok/auth.json`. Runway does not call `RedeemReset`.

## What a reset token is

xAI grants SuperGrok users occasional banked usage-limit resets (the "Reset Available / Expires on …" card on Settings → Usage). Redeeming one immediately resets the weekly shared pool. Tokens expire (observed live: 30 days after grant) and drop out of the list once redeemed or expired. They do not stack past the list the RPC returns.

## Endpoints

Both live under `https://grok.com`. The Grok CLI's `GET /v1/billing?format=credits` JSON does not carry this list.

Headers on the list call (gRPC-web empty request):

- `Authorization: Bearer <access_token>` (the Grok CLI OAuth access token)
- `Content-Type: application/grpc-web+proto`
- `x-grpc-web: 1`
- `Origin: https://grok.com` / `Referer: https://grok.com/?_s=usage`
- Body: an uncompressed gRPC-web data frame of length 0 (`00 00 00 00 00`)

### List (what Runway implements)

`POST /prod_mc_billing.ConsumerUiSvc/GetRemainingResets`

Protobuf (`consumer_ui.proto` field numbers, verified live):

```
ConsumerGetRemainingResetsResp
  repeated ConsumerResetToken tokens = 10;

ConsumerResetToken
  string token_id = 10;                          // e.g. "restok_…"
  google.protobuf.Timestamp granted_at = 20;     // present live; unused
  google.protobuf.Timestamp validity_end = 30;   // expiry; field 1 = unix seconds
```

A successful empty list is a known zero: an empty data frame plus `grpc-status: 0`. Redeemed and expired tokens drop out of the list. Tokens missing an id or whose `validity_end` is in the past are ignored, matching grok.com's own filter.

### Redeem (not implemented)

`POST /prod_mc_billing.ConsumerUiSvc/RedeemReset` consumes a token. Runway never calls this. Claiming stays on grok.com. A display-only timeline is enough to see how many resets remain and when they expire.

## Live list (2026-08-23)

The CLI OAuth bearer is accepted by grok.com for this RPC (no browser cookie needed). One still-valid token was present. `validity_end` was 30 days after `granted_at`. The token was not redeemed.
