# Dashboard

The popover that opens from the menu bar icon. Each provider is a card that shows the metrics you have enabled.

## First launch

A fresh install starts with Claude, Codex, and Cursor. It then checks which providers have credentials on your Mac (local logins, saved API keys, or supported environment variables) and switches to exactly that set. Nothing is sent anywhere. If nothing is found, the Claude, Codex, and Cursor starter set stays. A one-time card at the top of the dashboard explains this and points to **Customize**, where you can turn any provider on or off. The card stays until you close it.

This full detection only runs on a new install. Updates never change the providers you already have on or off. When an update ships a provider you have never seen, the same local check runs once for that provider and turns it on only if you have the tool. See [Which Providers Are On](provider-enablement.md).

## Cards

Each provider card leads with its **Always Visible** metrics. Metrics you have moved to **On Demand** sit behind the card's caret. Click the caret to reveal them in a single-column list below it, and click again to collapse. Closing the popover collapses every open card. A provider with no On Demand metrics and no quick links shows no caret.

A card can also show **quick-link buttons** at the bottom of its expanded section (Status, Console, Dashboard, and so on) that open the provider's own pages in your browser. They are part of the expander, so collapsing the caret hides them too. Buttons lay out up to three across and wrap to a second row.

## Total Spend

When any enabled provider tracks daily spend (Claude, Codex, Cursor, Grok, Muse, OpenCode, or Sakana Fugu), a Total Spend card sits above the provider cards. The title is a pull-down menu for **Cost**, **Cost/MTok**, or **Tokens**. Cost is the default, and the choice persists across restarts. A capsule switcher flips the period between **Today**, **Yesterday**, and **30 Days**. The ring, center total, and ranked legend follow the selected metric:

- **Cost**: each segment is that provider's share of combined dollars, biggest first.
- **Cost/MTok**: each segment is sized by that provider's dollars per million tokens. The center is the blended rate across providers that have both spend and tokens. The legend lists each provider's own rate.
- **Tokens**: each segment is that provider's share of combined tokens.

The ring center shows two short lines: a compact number and a unit (`$533` / `dollars`, `12.4` / `million`, or `$1.37` / `MTok`). Hover the center for the exact figure, and a note when any contributor's dollars are a local estimate (Cost and Cost/MTok only). In the legend, hover a provider row to see its full provider or account name. Each provider keeps a fixed brand color, and even a tiny share keeps a visible sliver of the ring. Providers with nothing for the selected metric do not appear. An enabled provider counts even if you have hidden its spend rows in Customize. Other dollar rows, like OpenRouter's API spend, never mix in.

The header's share icon (or right-clicking the card) copies a branded PNG of the ring to your clipboard, like sharing a provider card. The header also carries an ⓘ naming the providers that feed the total. A period with nothing to show for the active metric shows an empty state instead of hiding the card. Turn the card off with **Show Total Spend** at the top of [Settings](settings.md).

## Rows

**Metrics with a limit** (session, weekly, credits with a cap) show a progress bar:

- The fill color is a verdict on the whole window based on your current burn rate. Blue: you are on course to finish with at least 10% to spare. Yellow: you are projected to land inside the last 10% with a little left. Red: you are projected to run out before the reset, or to finish right at the limit. A half-full bar burning too fast is red, and a nearly empty bar coasting to the reset stays blue. Bars without a reset window (like a credit balance) and windows too young to project color by level instead: yellow at 80% used, red at 10% or less left. Colors come from the system palette, so they adapt to light and dark mode and accessibility settings. They never change with the Used/Left toggle.
- A headline like `52% left` or `48% used`. Click it to flip between Used and Left everywhere. Hovering shows the other reading.
- A reset label like `Resets in 3h 25m` or `Resets today at 6:38 PM`. Click it to flip between countdown and exact time everywhere. Hovering shows the other format.
- A blue bar carries nothing extra by default. With **Always Show Pacing** on in Settings, it also shows an even-pace tick on the bar and a `~35% left at reset` note next to the metric name. A metric with nothing used yet stays plain.
- A yellow bar adds a `~3% spare` note next to the metric name and an even-pace tick on the bar (where usage would sit if you burned evenly across the window). The cushion is always at least 1%. If you are projected to finish with nothing to spare, the bar turns red instead.
- A red bar shows a red flame next to the metric name with the projected run-out time (`Limit in 3h 5m` or `Limit today at 11:49 PM`, in the same format as the reset label) and the even-pace tick. Click the time to flip the format everywhere. When you are projected to finish right at the limit with no run-out before the reset, the flame shows alone.
- Once the balance is spent, or so close that it rounds to `0`, the bar stays red and the flame reads `Limit reached` regardless of burn rate.
- Hover the bar, the spare note, or the flame for the projection at reset: a blue bar shows the cushion (`~35% left at reset`), a yellow bar the projected usage (`~92% used at reset`), a red bar how far over you land (`~12% over limit at reset`, or `~100% used at reset` when you finish right at it). Once spent it reads `Limit reached`.

**Metrics without a limit** (daily spend, balances) show as a single line like `$4.08 spent` or `1.2M tokens`. The Today, Yesterday, and Last 30 Days rows combine cost and tokens (`$4.08 · 1.2M tokens`) and can be turned on or off in Customize. A day with no usage reads "No data" instead of `$0.00 · 0 tokens`, the same as when the source cannot be loaded. Big numbers are abbreviated (`$2.06K`, `1.5B`). Hover the value for the exact figures and the source note, such as a local estimate.

For Claude, Codex, Cursor, Grok, Muse, OpenCode, and Sakana Fugu spend rows, hovering the value for a moment opens a model breakdown for that period: a ranked list of models with name and spend on one line, share percentage and tokens on the next, and a thin share bar. Cursor groups its per-thinking-effort export slugs (like `claude-opus-4-8-thinking-max`) under the base model. Long tails fold into **Other** (anything past the top named models or under 5% of the period). Models no pricing source can price do not appear here or in the row's totals. The row's warning triangle names them instead (see [Pricing](pricing.md)).

**Usage Trend** (Claude, Codex, Cursor, Grok, Muse, OpenCode, and Sakana Fugu) is a small bar chart of the last 30 days of token usage, one bar per day, from the same source as that provider's spend rows. Hover it for the peak day, the date range, and the source. It is on by default. Turn it off or reorder it from Customize like any other metric. It cannot be starred for the menu bar.

**When a provider cannot load at all** (its refresh failed and there is no earlier data to show), the card replaces its metric rows with the reason and a **Refresh** button. A Keychain login that still needs your one-time approval gets the same card with neutral styling: a muted key glyph and a **Connect** button instead of a warning, because nothing is broken. Already-approved logins load silently in the background. The provider's quick links stay available behind the caret. The button is the one action that can show a macOS permission prompt. Background refreshes never do. Once a provider has loaded at least once, a later failure keeps the last-good rows on screen and shows an amber triangle at the right edge of the header. Clicking the triangle refreshes the provider (see [Refreshing](refreshing.md)).

**Long card names** (like `Claude — matt@example.com`) get the full header line. If a name still does not fit, hovering the header scrolls it once to its end and holds there.

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

A provider's **detail** has a back button and a Reset control in its top bar. Claude and Codex cards start with a **Name** field, the same rename the card's right-click menu offers. Then come two metric sections: **Always Visible** (shown on the card) and **On Demand** (behind the caret). Each metric row has a drag grip, its name, a star for the menu bar, and an on/off switch. Drag a metric into the other section, or onto one of its rows, to move it. An empty section shows a dashed **Drag metrics here** target. You can star up to two metrics per provider. OpenRouter and Z.ai also show an **API Key** section here, where you can add, replace, reveal, or clear that provider's key.

Drag-reorder also works on the dashboard: drag a row within its provider, drag it across the caret boundary while the card is open, or drag a provider header to reorder cards. On a Force Touch trackpad you feel a light tap each time the dragged item snaps into a new slot.

For Claude, the default layout keeps Session, Weekly, and Fable always visible. Codex and Grok keep only Weekly always visible. Sakana Fugu and Muse keep Five-Hour Usage and Weekly Usage always visible. For Claude, Codex, Grok, Muse, and Sakana Fugu, Usage Trend and the Today, Yesterday, and Last 30 Days rows start on demand. Codex and Grok also put Rate Limit Resets there, above the usage history. Their other metrics start off. Other providers keep their core meters above the caret and secondary details on demand.

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
