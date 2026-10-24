# brewau · native design prototype

This is a clickable **SwiftUI macOS menu bar prototype**, built for arm64 only.
It has no main window or Dock icon. The gear button opens a separate settings window.
Requires macOS 14+ and Xcode command-line tools to build. No dependencies.

```sh
make mockup-check
open "build/brewau Mockup.app"
```

Click the circular-arrows icon in the menu bar. **Opdater alle** simulates an update;
running apps then move into **Afventer genstart**. **Genstart…** asks for confirmation
and removes the sample app from that list. **Nulstil demo** restores the initial data.
Scanning restores the sample update list, so the flow can be tried again.

Settings are usable but kept in memory and reset when the prototype quits:

- **Generelt:** launch-at-login preference and a summary of selected behavior.
- **Tidsplan:** independent scanning cadence; automatic upgrade by interval, daily,
  or weekly, with one or more local times. Examples: hourly, Monday at 03:00,
  daily at 03:00 and 15:00.
- **Genstart:** per-app force-restart permission, off by default, with confirmation.
- **Notifikationer:** master switch, event preferences, and a sample notification.
- **Homebrew:** update Homebrew before scanning, include self-updating casks, and
  an illustrative zsh completion warning with a proposed repair explanation.

The prototype never executes Homebrew, installs anything, changes permissions,
registers login items, requests notification permission, or closes other apps.
Homebrew status and app versions are sample data, not a machine inventory.

## Design

Native controls, system typography, SF Symbols, semantic system colors, and one
blue action color. A 410 pt menu popover provides everyday actions; an 800 × 620 pt
settings window holds detailed preferences in five sidebar destinations. Settings
use native grouped forms, and both surfaces follow macOS light/dark appearance.
App glyphs are placeholders, not third-party brand artwork.

The installed **ui-ux-pro-max** skill informed the minimalism, SwiftUI forms,
keyboard/accessibility labels, and platform-first approach. Its initial generic
AI/landing-page recommendation was rejected as unsuitable; the focused minimalism
result and native SwiftUI guidance were used instead.

Generate actual SwiftUI view previews with:

```sh
make mockup-previews
```

The files in `previews/` are rendered from the same views used by the app.
They show content without the system window chrome.

## Boundaries for the real app

After design approval, connect this UI to the existing privilege boundary through
a narrow, validated service interface. Preferences in this prototype are not a new
configuration format and do not modify `brewau.conf` or launchd.

The user-session app should manage notifications and app lifecycle. The `_brewau`
service continues to own Homebrew operations. A running process may retain its old
version after an app bundle is upgraded; distinguish package installation from a
successful restart. Handle session ownership, missing notification permission,
failed upgrades, and restart refusal explicitly.

The current upgrade job already runs `brew update`. The full implementation needs
independent scans, old/new version data, richer schedules, and user-session restart
coordination. Missed schedules during sleep and wake behavior need an explicit
implementation decision.

The zsh warning is consistent with `_brewau` owning completion files: zsh checks
for ownership by root or the current user, as well as writable directories. A
candidate fix is a root-owned completion snapshot, refreshed after Homebrew
changes and placed in `fpath` before `compinit`, with safe symlink handling. Validate
the final design with `compaudit` and preserve the existing isolation. No repair
has been implemented here, and disabling the security check is not part of this
prototype.

References: [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra),
[zsh completion security](https://zsh.sourceforge.io/Doc/Release/Completion-System.html).
