# Settings

Settings opens in its own window, separate from the popover. Open it from the popover footer's **gear** menu, with ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. Opening Settings closes the popover. Close the window with the red close button, Esc, ⌘W, or ⌘Q. ⌘Q closes only the Settings window. Runway keeps running in the menu bar. Quit it from the popover's gear menu or the menu bar icon's right-click menu.

The window has four tabs: **General**, **Appearance**, **Notifications**, and **Advanced**. It remembers the tab you were on, its size, and its position. It only exists while it is open, so a closed Settings window uses no memory or CPU.

While Settings is open, Runway briefly appears in the Dock, the same as during an [update session](updates.md). That is what brings the window to the front for a menu-bar-only app. It leaves the Dock when you close the window.

## General

| Setting | Options | What it does |
|---|---|---|
| Show Total Spend | on/off | Whether the cross-provider [Total Spend](dashboard.md#total-spend) card shows at the top of the dashboard. On by default. The card appears whenever at least one enabled provider tracks spend (Claude, Codex, Cursor, Grok, OpenCode, Sakana Fugu). |
| Launch at Login | on/off | Registers the app as a login item. The system's login-item registry is the source of truth. |
| Global Shortcut | record a shortcut | Toggles the popover from anywhere. Click the field and press a combo. The ⓧ clears it. |

### iCloud Sync

**Sync Across Macs** is on by default. Turn it off here to keep this Mac local-only. It shares normalized Runway history and each device's latest usage snapshot through the app's private CloudKit database, and combines machine-local tokens and spend across Macs signed into the same iCloud account. Settings shows the five-minute write cadence and each device's relative **Updated** time. It also reports unavailable iCloud, loading, write, and malformed-record states. See [iCloud Sync](icloud-sync.md).

### Privacy

| Setting | Options | What it does |
|---|---|---|
| Hide From Screen Share | On / Off | Off by default. On replaces the menu bar strip with the Runway icon and wordmark while your screen is shared or recorded, and restores your starred metrics when the capture ends. See [Menu bar](menu-bar.md#hiding-usage-while-screen-sharing). |

## Appearance

| Setting | Options | What it does |
|---|---|---|
| Icon Style | Text / Bars | How starred metrics render in the menu bar. See [Menu bar](menu-bar.md). |
| Theme | System / Light / Dark | Appearance override for the popover and the Settings window. |
| Time Format | Auto / 12-hour / 24-hour | How exact times read ("Resets today at 6:38 PM" vs "18:38"). Auto follows the system. |
| Increase Transparency | Off / On | Off by default. On makes the popover translucent so your desktop shows through, with frosted surfaces behind the numbers and footer controls. It pauses when the macOS **Reduce Transparency** or **Increase Contrast** accessibility setting is on, and a note says so. |

### Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left". Same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM". Same toggle as clicking a reset label. |
| Always Show Pacing | Off / On | Off by default shows pacing only when a metric is close to or over its limit. On shows it on every metric with a reset window: on-track rows gain their projection ("~33% left at reset") and an even-pace tick. Metrics without a reset window have no pace to show. A metric with nothing used yet stays plain. |

## Notifications

Runway can send a macOS notification when a metric runs low or its pace gets worse. Alerts work while the app runs in the menu bar, even with the popover closed.

| Setting | Options | What it does |
|---|---|---|
| Almost Out | On / Off | Alerts when a metric crosses under 10% remaining, including balances without a reset window. |
| Cutting It Close | On / Off | Alerts when a metric is projected to finish the period close to its limit. |
| Will Run Out | On / Off | Alerts when a metric is projected to run out before it resets. |

Alerts fire on a new crossing or when pace worsens, then stay quiet while that condition is unchanged. A quota already in a bad state when Runway launches sets the baseline without alerting. If it recovers and later worsens again, the alert fires again. A new reset period also clears the reset-based history. **Almost Out** uses only the remaining share, so it also works for balances without a reset window. **Cutting It Close** and **Will Run Out** need a reset window. Metrics whose data cannot be read never alert. Turn all three off to silence everything. Several alerts at once stack into one grouped banner.

All three default off. The first time you turn one on, Runway asks for notification permission. If you decline, or later turn notifications off for Runway in System Settings, a warning mark appears on the Notifications header and an "Open System Settings" button shows under the toggles. A notification's title is the alert name, its subtitle names the provider and metric, and its body is the plain-language verdict. Tapping an alert opens the popover.

## Advanced

### Command Line

| Setting | Options | What it does |
|---|---|---|
| Terminal Helper | Install / Uninstall | Adds a global `runway` command that agents can use to read limits. See [CLI](cli.md). |

### Logging

| Setting | Options | What it does |
|---|---|---|
| Log Level | Error / Warning / Info / Debug | How much detail the app writes to its log file. Defaults to Info and persists across launches. Raise to Debug while reproducing a problem. Applies immediately. |
| Copy Log Path | button | Copies the log file path (`~/Library/Logs/Runway/Runway.log`) to the clipboard. |
| Reveal in Finder | button | Opens a Finder window with the log file selected. |

See [Logging](logging.md) for subsystem tags, the file size cap, and what is never logged.

### Updates

The Updates section appears in official packaged builds that include the signed update feed. Local developer builds do not show it.

| Setting | Options | What it does |
|---|---|---|
| Update Automatically | On / Off | Whether Sparkle checks for updates in the background. You can still check manually when this is off. |
| Check for Updates… | button | Starts a manual update check and opens Sparkle's update window. |

See [Updates](updates.md).

## Version

The app version shows in the popover footer.

Your settings carry across updates: layout, stars, preferences, and the shortcut. When an update changes how a setting is stored, the app upgrades it in place on launch, stepping through any skipped versions. Nothing is reset.

Which providers you have on also carries across updates. A new install picks its starting set by detecting the AI tools on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)). When an update ships a provider you have never seen, the same local detection runs once for that provider and turns it on only if you have the tool. See [Which Providers Are On](provider-enablement.md).
