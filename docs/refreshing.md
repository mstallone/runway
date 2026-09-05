# Refreshing & Caching

## When data updates

- All enabled providers refresh together: once at launch, then every 5 minutes. There is no setting for the interval. Opening the popover does not start another pass. Providers fetch in parallel, so fast cards update without waiting for a slow one. Results that land close together are published as one update. The batch finishes only after every provider returns. Notifications, history sync, and the next five-minute wait start after that.
- Turning a provider on (in Customize, or through first-launch or new-provider detection) fetches it right away instead of waiting for the interval, even in the middle of a running refresh.
- The dashboard footer shows a countdown to the next update (like `5m` or `45s`). Click it, or press ⌘R, to refresh now and skip the cache. If several providers need Keychain approval, their dialogs appear one at a time. Runway never opens two approval dialogs together.
- Automatic refreshes never show Keychain UI. Once you have approved Runway for a login with **Always Allow**, background refreshes read it silently, including right after a relaunch. A login macOS would have to ask about (a new item, or one you have not approved yet) is never asked about in the background. Its card shows the neutral key glyph or **Connect** button, and the dialog appears only when you click it. Background reads run with Keychain UI suppressed, so a read that would have prompted lands in the Connect state instead. That state is not an error and shows no warning triangle. If the app that owns a credential resets its item's sharing rules on a token rotation and blocks Runway's direct read even though your Always Allow is intact, Runway reads through Apple's security helper instead, but only after confirming from the item's rules that the helper needs no dialog. Runway also only shows an approval dialog when the approval can last. An unsigned developer build skips the dialog, stays on the Connect state, and logs the reason.
- The one-shot `runway` command reuses the same cache for five minutes, refreshes missing or stale entries without starting the app, and exits. `runway --force` runs the same forced refresh as ⌘R regardless of cache age, but it never opens a Keychain approval dialog and cannot reuse the app's approval, because the command is a separately signed binary. Providers whose credentials live only in a protected Keychain item reach the command through the snapshot the app writes. See [CLI](cli.md).
- While a provider is fetching, a spinner appears next to its name, and the footer countdown becomes one too.
- With [iCloud Sync](icloud-sync.md) on, a refresh batch publishes this device's sync record after the whole batch finishes. Manual provider refreshes write after that provider finishes, and nearby changes are combined into one write.

## Caching

Snapshots are cached on disk and load at launch, so you see your last-known values right away, before the first fetch finishes.

Claude and Codex cache entries also remember which account produced them. If you swap the account signed in at the provider's default home between launches, the previous account's cached values are dropped at the next launch. The card starts empty and fills on its first fetch instead of showing the old account's limits and plan under the new login.

A cached value only counts as fresh when it was fetched during the current running session. A value cached in an earlier session always re-fetches on the first pass after launch. You still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new version refreshes right away instead of showing the previous version's data. Within a session, a freshly fetched value counts as fresh for one refresh interval.

Claude, Codex, and pi spend history has a separate parse cache under `~/Library/Application Support/Runway/log-scan-cache/`. It stores parsed usage events before pricing, so pricing updates take effect without re-reading unchanged JSONL. On relaunch, an entry is reused only when its path, size, modification time, and parser version still match. A session log that only grew since its last parse is not re-read from the start. The cache remembers how far it parsed plus a fingerprint of the bytes just before that point, so it still detects a rewritten file and re-parses it in full. Same-home cards share parsed data, and changing one source file rewrites only that file's record. Old files leave the cache as the history window advances, and identities unused for 35 days are removed. App writes are debounced until after refresh. The CLI flushes pending writes before it exits.

## When a fetch fails

A failed refresh never wipes your data. The last good values stay on screen, and a warning triangle appears at the right edge of the provider's header. Hover it for the error message (for example "Not logged in"). Click the triangle to refresh that provider, which usually clears the problem (a denied Keychain approval, or a token you just renewed in your terminal). Like every manual refresh, that click may show a macOS permission prompt. Background refreshes never do. While the refresh runs, the triangle gives way to the header's spinner. Notices that ask you to wait, like Claude's "Updates blocked by Anthropic" during a rate limit, stay a plain symbol with no click, because refreshing again only makes the block last longer. The error clears on the next successful refresh.

A Keychain login that needs your one-time approval is not one of these failures. It shows a muted key glyph in the header, or a **Connect** button when the card has no data yet, because nothing needs fixing. The warning triangle appears for Keychain only when something went wrong: you declined the approval dialog (the message says access was declined and to choose Always Allow), or the keychain itself could not be read (locked, or securityd failing).

When a provider stops responding, Runway cuts it off after a per-provider ceiling (2.5 minutes for most; slower flows like Copilot's multi-org billing probe get more). The attempt counts as a failed refresh with the message "Refresh timed out after 150s". The provider backs off briefly before the next attempt, and a new attempt never overlaps a timed-out one that is still winding down.

The last good normalized history is preserved too, so a temporary provider failure, or a successful limit refresh whose local log scan is temporarily unavailable, does not remove this Mac's previous contribution from an iCloud-combined spend total.

Rows that have never had data show "No data".

## Stale data

Because a failed refresh keeps the last good values on screen, those values can persist while refreshes keep failing. An **Outdated** tag appears next to the provider's name once its data is more than about ten minutes old. Hover it for the exact age ("Last updated 3h ago"). When you see it, the numbers below are from that earlier time, usually because the provider is failing to refresh (check the warning triangle) or the Mac was asleep. A successful refresh clears it.
