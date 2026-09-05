# Menu Bar

Star your most important metrics into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a menu with **Settings**, **Memory** (opens the [Memory Explorer](memory-explorer.md)), and **Quit**. Left-click opens the popover.

## Starring

Star a metric from any row's right-click menu, or from the star beside a metric in Customize.

- The app ships with a default set of stars (Antigravity Session and Weekly, Claude Session and Weekly, Codex Weekly, Cursor Models and Other Models, Copilot Credits, Muse Five-Hour Usage and Weekly Usage, OpenRouter Credits, Z.ai Session and Weekly) so the strip shows numbers right away. Each discovered Claude or Codex account card gets its family's default stars with its own values. A card discovered later receives them once and then keeps your changes. A provider's Reset restores its defaults, and Reset All restores the full set. Only providers that are on render in the strip, and a fresh install starts with just the providers detected on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)).
- At most **2 stars per provider**. If an account or plan change makes a starred metric unavailable, Runway keeps the star for a future switch back, and the dormant star does not use one of the two slots. If a later switch makes more than two saved stars live at once, the strip renders the first two in Customize order without deleting the others.
- When a star is not allowed, the star button stays clickable. Clicking it shakes and shows the reason in a temporary pill at the bottom of Customize (for example, "Up to 2 stars per provider").

## Styles

Settings → Appearance → Icon Style:

- **Text**: provider icon plus values. Two starred metrics from the same provider stack as a labeled pair. Hover an account segment to see that card's current name.
- **Bars**: a compact glyph with the first four starred metrics that have a limit. Metrics without limits only appear in Text style.

## Hiding usage while screen sharing

Settings → General → Privacy → **Hide From Screen Share** (off by default). While your screen is shared or recorded (a Zoom, Meet, or Teams share, a screen recording, macOS Screen Sharing), the strip shows the Runway icon and wordmark instead of your numbers. When the capture ends, your starred metrics come back. Captures you start yourself count too.

Detection uses the system's own screen-capture signal, the one that lights the capture indicator in the menu bar. Runway checks it the instant it changes, and again every few seconds while the setting is on.

Normally:

![The menu bar strip showing usage values](assets/menu-bar-privacy-idle.png)

While the screen is shared or recorded:

![The menu bar strip concealed behind the Runway wordmark](assets/menu-bar-privacy-sharing.png)

## The notch

On MacBooks with a notch, a crowded menu bar can push the Runway item under the notch where you cannot see or click it. Runway watches for this and recovers:

1. **Move back into view.** The item's remembered position is rewritten so it lands just right of the notch. This is the normal outcome. The strip can hop visibly.
2. **Surrogate button.** If the move does not stick, a small round Runway button appears just below the menu bar next to the notch. Click it to open the dashboard, drag it anywhere, or right-click for Hide Until Relaunch.
3. Either way, the dashboard opens beside the notch, never centered under it.

Free up menu bar space (quit other menu bar apps, or use a menu bar manager) and everything returns to normal.

On macOS 27 and later this recovery is off. The system folds items that do not fit behind a chevron next to the notch.

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped. A provider whose stars all lack data disappears, icon included. When nothing has data, the strip shows the app icon. Stars follow your Customize order: Always Visible metrics first, then On Demand ones. A metric can be starred whether it is Always Visible or On Demand.
