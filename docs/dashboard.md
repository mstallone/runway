# Dashboard

The popover that opens from the menu bar icon. Each provider is a card that shows the metrics you have enabled.

## First launch

A fresh install starts with Claude, Codex, and Cursor. It then checks which providers have credentials on your Mac (local logins, saved API keys, or supported environment variables) and switches to exactly that set. Nothing is sent anywhere. If nothing is found, the Claude, Codex, and Cursor starter set stays. A one-time card at the top of the dashboard explains this and points to **Customize**, where you can turn any provider on or off. The card stays until you close it.

This full detection only runs on a new install. Updates never change the providers you already have on or off. When an update ships a provider you have never seen, the same local check runs once for that provider and turns it on only if you have the tool. See [Which Providers Are On](provider-enablement.md).

## Cards

Each provider card leads with its **Always Visible** metrics. Metrics you have moved to **On Demand** are tucked away. Click anywhere on the card to reveal them under a thin divider, and click again to collapse. With keyboard navigation on, focus the card and press Space. Closing the popover collapses every open card. A provider with no On Demand metrics and no quick links has nothing to reveal.

With **Group Accounts by Provider** on in [Settings → Appearance](settings.md#dashboard), every account of one provider shares a single card. The provider's name and account count sit above it once, with how many of its accounts are usable right now (`2 of 5 ready`), and each account inside keeps its own title, plan, metrics, expanded section, notices, and right-click menu. The title drops the provider prefix (`matt@example.com` instead of `Claude — matt@example.com`); a card you renamed keeps its name. The accounts gather where the provider's first card sits in your order. Drag an account's title to reorder it among that provider's accounts; the provider's card stays where it is. Drag a single-account provider's header to move it past a grouped provider as a whole. A provider with one account looks the same either way.

When an Always Visible Weekly meter reaches its limit, the card temporarily hides its other Always Visible progress bars. The card's mark and name fade, the way the account's icon fades in the menu bar (an account's title inside a grouped provider card stays at full strength), and Weekly becomes a one-line faded **Usage Exhausted** message with a live countdown and the reset time (`Resets in 1d 16h · Sat 3:00 AM`), without a bar or percentage; text rows and On Demand metrics stay available. The bars return in their saved order after a refresh reports usage below the weekly limit. This does not change Customize settings or saved menu-bar pins. In the menu bar, exhausted accounts show a faded provider icon without values (see [Menu Bar](menu-bar.md#exhausted-weekly-usage)). A weekly meter that is disabled or On Demand does not trigger hiding. Independent weekly pools (Antigravity and Codex Spark) hide only their own session bar.

A card can also show **quick-link buttons** at the bottom of its expanded section (Status, Console, Dashboard, and so on) that open the provider's own pages in your browser. They are part of the expanded section, so collapsing the card hides them too. Buttons lay out up to three across and wrap to a second row.

## Total Spend

When any enabled provider tracks daily spend (Claude, Codex, Cursor, Grok, Muse, OpenCode, or Sakana Fugu), a Total Spend card sits above the provider cards. It covers three periods: **Today**, **Yesterday**, and **30 Days**.

**Accounts are grouped by provider.** Several accounts of one provider (five Claude logins, say) count as one line, one color, and one segment, titled with the provider's name. Click that line to list its accounts underneath, and click again to fold them away. Closing the popover folds them all. A provider with one account shows that account's own name and has nothing to open.

Pick how the card looks from the **View** submenu at the bottom of the header's pull-down menu, or with **Total Spend Style** in [Settings](settings.md). Both change the same setting:

- **Table**: providers down, the three periods across, and a **Total** row on top. Every number is visible at once. Providers are ranked by their 30-day amount, so the order stays put from day to day. A provider with nothing for a period shows a dash.
- **Bar**: three totals across the top show each period's combined amount. Click one to select that period. It joins a panel below it, where a bar split by provider sits over a ranked legend with each provider's amount and share.
- **Pie** (the default): the same tiles over a ring split by provider, with the selected period's total in the middle and a ranked legend beside it.

In Bar and Pie, clicking the selected total again closes the panel and leaves the three totals alone. Click any total to open it again on that period. The selected period and the collapsed state persist across restarts.

A pull-down menu at the right end of the header switches what the card measures: **Cost**, **Cost/MTok**, or **Tokens**. Tokens is the default, and the choice persists across restarts. Below those, its **View** submenu holds Pie, Bar, and Table.

- **Cost**: combined dollars. Each provider's share is its part of them.
- **Cost/MTok**: the blended rate across providers that have both spend and tokens. A provider's rate is its dollars over its tokens across all of its accounts. Bar and ring segments are sized by rate, and no share is shown.
- **Tokens**: combined tokens. Each provider's share is its part of them.

Totals use a short figure (`$533.20`, `$2.1K`, `12.4M`). Under Cost and Cost/MTok, the Bar legend lists exact dollar amounts. In the legend, hover a row to see a long name in full. Each provider keeps a fixed brand color, and even a tiny share keeps a visible sliver and reads `<1%`. Providers with nothing for the selected metric do not appear. An enabled provider counts even if you have hidden its spend rows in Customize. Other dollar rows, like OpenRouter's API spend, never mix in.

Right-clicking the card and choosing **Share Screenshot** copies a branded PNG to your clipboard, like sharing a provider card. In Bar and Pie it shows the selected period's total and provider breakdown. In Table it shows the whole table. A period with nothing to show for the active metric shows a dash and, when selected, an empty state instead of hiding the card. Turn the card off with **Show Total Spend** in [Settings → Appearance](settings.md#dashboard).

## Rows

**Metrics with a limit** (session, weekly, credits with a cap) show as tiles. Every tile is the same four lines, whatever its state: the metric's name, its reading, a progress bar, and a time.

- Tiles fill the card. Up to three limits sit side by side, four sit two by two, and more wrap in threes. Every account of one provider uses the same columns, so a limit is the same width and in the same place on each of them.
- A short plain value next to a limit (like a credit balance) joins the same row as a tile with no bar. It takes a third of the card and the limits share the rest. Values that do not fit that row, and rows with their own hover detail, keep their own line.
- A limit with no data is left out while the card has other things to show.
- The bar's fill color is a verdict on the whole window based on your current burn rate. Blue: you are on course to finish with at least 10% to spare. Yellow: you are projected to land inside the last 10% with a little left. Red: you are projected to run out before the reset, or to finish right at the limit. A half-full bar burning too fast is red, and a nearly empty bar coasting to the reset stays blue. Bars without a reset window (like a credit balance) and windows too young to project color by level instead: yellow at 80% used, red at 10% or less left. Colors come from the system palette, so they adapt to light and dark mode and accessibility settings. They never change with the Used/Left toggle.
- The reading, like `52%` with a small `left` or `used` beside it. **Show Usage As** in [Settings](settings.md) picks which one the tiles show. Once the balance is spent, or so close that it rounds to `0`, the reading turns red.
- The time under the bar is the reset in short form: a countdown like `3h 25m`, or an exact time like `6:38 PM` today, `Sat 3:00 AM` later this week, and `Feb 15` beyond that. **Reset Times** in Settings picks which one the tiles show.
- On a red bar that is projected to run out before it resets, the time shows a flame and when the limit runs out instead (`1d 15h`). A bar projected to finish right at the limit keeps its reset time. The reset moves to the tile's hover card.
- Yellow and red bars show an even-pace tick (where usage would sit if you burned evenly across the window). With **Always Show Pacing** on in Settings, blue bars show it too. A metric with nothing used yet stays plain.
- Hover anywhere on a tile for a small detail card with what the tile does not print: where the pace lands at reset (`~35% left`, `~92% used`, `~12% over limit`), the reset in the other format (the exact time under a countdown, and the other way round), and when a limit on course to run out will do so. A session that has not started explains why, and a plain value gives its exact figures. A tile with nothing to add has no card.

**Metrics without a limit** (daily spend, balances) show as a single line like `$4.08 spent` or `1.2M tokens`. The Today, Yesterday, and Last 30 Days rows combine cost and tokens (`$4.08 · 1.2M tokens`) and can be turned on or off in Customize. A day with no usage reads "No data" instead of `$0.00 · 0 tokens`, the same as when the source cannot be loaded. Big numbers are abbreviated (`$2.06K`, `1.5B`). Hover the value for the exact figures and the source note, such as a local estimate.

For Claude, Codex, Cursor, Grok, Muse, OpenCode, and Sakana Fugu spend rows, hovering the value for a moment opens a model breakdown for that period: a ranked list of models with name and spend on one line, share percentage and tokens on the next, and a thin share bar. Cursor groups its per-thinking-effort export slugs (like `claude-opus-4-8-thinking-max`) under the base model. Long tails fold into **Other** (anything past the top named models or under 5% of the period). Models no pricing source can price do not appear here or in the row's totals. The row's warning triangle names them instead (see [Pricing](pricing.md)).

**Usage Trend** (Claude, Codex, Cursor, Grok, Muse, OpenCode, and Sakana Fugu) is a small bar chart of the last 30 days of token usage, one bar per day, from the same source as that provider's spend rows. Hover it for the peak day, the date range, and the source. It is on by default. Turn it off or reorder it from Customize like any other metric. It cannot be starred for the menu bar.

**When usage cannot load**, unavailable bars become one compact message with the reason and a **Refresh** button. This includes login or fetch failures reported as warnings while local spend still loads. Any available usage, cached values, and local spend stay visible in their saved positions; empty rows are hidden until data returns. If none of the selected metrics have data, the message replaces all of them. On Demand metrics and quick links stay in the expanded section, even when account filtering removes every Always Visible metric. The notice keeps the card visible without promoting those rows; saved settings do not change. A Keychain login awaiting approval offers **Connect** instead; already-approved logins load silently. Notices that ask you to wait, such as a provider rate limit, offer no Refresh button. Manual refreshes can show a macOS permission prompt; background refreshes never do. If all bars still have last-good data, a later failure keeps them on screen and the header notice explains the error (see [Refreshing](refreshing.md)).

The plan name sits at the right end of the header. **Long card names** (like `Claude — matt@example.com`) get the rest of the header line. If a name still does not fit, hovering the header scrolls it once to its end and holds there.

With [iCloud Sync](icloud-sync.md) on, the machine-local providers' spend rows, trends, warnings, and model breakdowns are rebuilt from all synced Macs. Cursor is unchanged because its export is already account-wide. Quotas, plans, balances, and provider errors always describe this Mac's refresh.

Rows with a reset date tick every 30 seconds, so countdowns and pace stay live between refreshes.

Runway honors the system Reduce Motion setting. Screen switches and panel growth use quick fades instead of springs and slides.

## Right-click menus

Every row: **Hide**, **Star for menu bar** / **Unstar**, **Refresh \<provider\>**, **Customize…** (opens straight to that provider's metrics).

Provider headers: **Hide \<provider\>** (turns the whole provider off; turn it back on in Customize), **Refresh \<provider\>**, **Customize…**, and **Share Screenshot** (see below). Claude and Codex cards also offer **Rename…**. Give the card any name you like, which helps with multiple accounts. Leave the field empty to go back to the default name. The name follows the card everywhere: the dashboard, the Total Spend legend, share screenshots, notifications, and the CLI and API output.

## Share

Copy a branded PNG of one provider's usage to your clipboard:

- Right-click a provider header and choose **Share Screenshot**.
- Open the footer's **gear** menu and choose **Share Screenshot** ▸ *\<provider\>*. The submenu lists every provider on the dashboard.

The image shows the provider's mark and name, the metric rows you currently see for that provider, and a small Runway mark at the bottom. It follows your Light/Dark appearance and shows everything on the card as-is. Nothing is hidden or blurred.

## Footer

The bar pinned to the bottom of the popover. On the left: the app version. On the right: a countdown to the next update (like `5m`) that you can click, or press **⌘R**, to refresh now, and a **gear** menu. The gear holds **Customize**, **Settings** (opens the [Settings window](settings.md)), **Memory** (opens the [Memory Explorer](memory-explorer.md)), **Share Screenshot**, **Check for Updates…**, **About Runway**, and **Quit Runway**.

## Customize

Open Customize from the footer's **gear** menu or press **Return**. It has two levels: a list of providers, then a provider's detail.

The **provider list** shows every provider with an on/off switch, a count of its metrics, and a chevron into its detail. A provider turned off stays in the list, greyed. Its metrics leave the dashboard and menu bar but keep their setup for when you turn it back on. Drag enabled providers by their grip to reorder. Tap a row to open its detail. On a fresh install only the providers detected on your Mac start on (see "First launch" above). This list is where you add the rest.

A provider's **detail** has a back button and a Reset control in its top bar. Claude and Codex cards start with a **Name** field, the same rename the card's right-click menu offers. Then come two metric sections: **Always Visible** (shown on the card) and **On Demand** (shown when the card is expanded). Each metric row has a drag grip, its name, a star for the menu bar, and an on/off switch. Drag a metric into the other section, or onto one of its rows, to move it. An empty section shows a dashed **Drag metrics here** target. You can star up to two metrics per provider. OpenRouter and Z.ai also show an **API Key** section here, where you can add, replace, reveal, or clear that provider's key.

Drag-reorder also works on the dashboard: drag a spend or text row within its provider, drag it across the divider while the card is open, or drag a provider header to reorder cards. Tiles sit side by side and do not drag; reorder limits, and plain values that can sit beside them, in Customize. On a Force Touch trackpad you feel a light tap each time the dragged item snaps into a new slot.

For Claude, the default layout keeps Session, Weekly, and Fable always visible. Codex and Grok keep only Weekly always visible. Sakana Fugu and Muse keep Five-Hour Usage and Weekly Usage always visible. For Claude, Codex, Grok, Muse, and Sakana Fugu, Usage Trend and the Today, Yesterday, and Last 30 Days rows start on demand. Claude, Codex, and Grok also put Rate Limit Resets there, above the usage history. Their other metrics start off. Other providers keep their core meters always visible and secondary details on demand.

Press **⌘Z** to undo. It works anywhere in the popover and steps back through your recent customization changes one at a time: hiding or showing a metric, reordering metrics or providers, starring or unstarring, and moving a metric across the divider. Undo is per session and resetting clears it.

When Runway ships a new default metric, existing layouts get it once, in that provider's default position. If you turn it off, it stays off. A provider's **Reset** button restores that provider's default metrics, order, menu-bar stars, and On Demand set, and leaves other providers and the provider order alone. **Reset All Customization** at the top of the provider list does the same for every provider, restores the default provider order, and re-detects your installed tools. It turns providers on for exactly the tools set up on your Mac, like first launch (see [Which Providers Are On](provider-enablement.md)). It asks for confirmation first and cannot be undone.

## Keyboard

| Key | Action |
|---|---|
| Return | From the dashboard, open Customize; from a provider detail, go back to the provider list; from the provider list, go back to the dashboard |
| Esc | From a provider detail, go back to the provider list; from the provider list, go back to the dashboard; from the dashboard, close the popover |
| ⌘Z | Undo the last customization change (repeat to step back) |
| ⌘R | Refresh now from the dashboard (skips the cache) |
| ⌘, | Open the [Settings window](settings.md) (closes the popover) |
| ⌘M | Open the [Memory Explorer](memory-explorer.md) (closes the popover) |

A global shortcut (recorded in Settings) toggles the popover from anywhere.

## Closing

Closing the popover resets navigation: scroll returns to the top, Customize closes, and every provider card collapses.

Pinned accounts that need a login remain in the menu bar as faded icons without values, including when the dashboard retains cached usage or local history. The dashboard notice explains how to reconnect. Normal menu-bar values return after a successful refresh; see [Menu Bar](menu-bar.md#login-unavailable).
