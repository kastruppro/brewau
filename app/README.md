# brewau for macOS

Native SwiftUI, macOS 14+, Apple Silicon only. The app lives in the menu bar and
has a separate settings window. There is no main window or Dock icon.

## Install and use

Install the signed `build/brewau.pkg` produced by `make release`, then open
`/Applications/brewau.app`. A new backend is required; running the app against
the old CLI installation shows an explicit installation message.

The popover shows actual Homebrew outdated packages, with installed and available
versions. Pinned and excluded packages stay visible and are labeled. **Opdater
alle** starts the existing protected upgrade flow. **Vis log** opens the service
log. Work runs independently of the GUI.

A finished run is described by what the service recorded, not by a generic failure:
`state/last-result.json` (upgrades) and `state/last-scan-result.json` (scans) name the
packages that were upgraded, failed or blocked, and why. The popover names the package
and the reason. A run that found no network is reported as skipped, not as a failure.
Both files are optional: a brewau that has not written them yet leaves the GUI on its
previous information.

A cask that macOS App Management keeps the background job from replacing is reported
once, as blocked: it is skipped until a newer version appears or the user upgrades it
by hand. **Åbn Systemindstillinger…** opens Anonymitet og sikkerhed › App-administration,
and **Prøv igen** asks the helper to drop the block list and starts a new upgrade.

- **Tidsplan:** scans every 15/30 minutes, 1/6/12 hours or daily. Upgrades can run
  by hour interval, daily, or weekly, with up to 24 distinct local times. Press
  **Gem** to apply the schedule. Schedules and Homebrew preferences apply to all
  brewau users on the Mac; notification/restart preferences apply to your session.
- **Genstart:** active apps with an installation timestamp newer than their launch
  time appear as pending. A manual restart asks for confirmation and tries normal
  termination. Only apps explicitly allowed in settings can be forcibly terminated
  after a 15-second grace period. The allowlist is tied to cask, app path and bundle
  identity. Failed or refused restarts are reported and do not spin in a retry loop.
- **Notifikationer:** separately select discovery, completion, restart and failure
  events. A blocked package is notified once per package and version, not on every
  scheduled run, and a run without network is not notified at all.
  Request macOS permission from this page; a denied permission is shown.
  Login startup uses `SMAppService.mainApp` and reflects the actual system status.
- **Homebrew:** refresh Homebrew before scanning, include self-updating apps, and
  repair terminal completions. Homebrew itself always updates before upgrading.

Keep the menu bar app running for notifications and session app restarts. The
background scheduler checks once per minute, including when the app is closed.
It catches up after sleep, coalesces missed calendar runs, and records attempts
before work so a failure waits until the next scheduled occurrence. Scans and
upgrades share a POSIX file lock. A crash does not leave a permanently held lock.

No apps are force-restarted by default. An allowed app can lose unsaved work.
Restart detection uses Homebrew's installation timestamps and app artifacts;
pkg-based apps can also be resolved from Homebrew's uninstall bundle identifiers.
A cask that exposes neither cannot be reliably mapped to a running app and is
still updated, but is not automatically restarted. Other user sessions are not
managed by this session's GUI. macOS App Management restrictions may require an
administrator/MDM permission before an app can be protected or replaced.

## Terminal completions

The root-only helper copies supported completion files into
`/opt/brewau/share/zsh/site-functions`. It resolves source links only inside the
Homebrew prefix, publishes regular files with root ownership and mode 0644, and
removes stale copies. The containing tree stays root-owned. New completion
snapshots are produced after background work and mutating CLI commands.

Shell setup places this directory in `fpath` and removes the `_brewau`-owned
Homebrew entries before completion initialization. `brew shellenv` through the
wrapper preserves this rule. Both login and non-login interactive zsh sessions
are covered through `.zprofile` and `.zshrc`; `compinit` security checks remain on.
Existing profile symlinks are preserved and a one-time `.brewau-backup` is kept.
`brewau restore-shell` removes the managed changes, and uninstall runs that for
local users. Custom `ZDOTDIR` setups or a plugin that later reinserts Homebrew
paths may need their own shell integration.

## Build and check

```sh
make app agent             # development-signed app and helper
make app-check             # native logic and completion safety checks
make test lint             # shell behavior and static checks
make pkg                   # complete unsigned installer
make release               # Developer ID signatures, notarization, stapling
```

The privileged helper accepts only eight validated schedule preferences as JSON
on stdin. It cannot edit taps, forbidden packages, allowed services, arbitrary
files, commands or paths. Only `brewau_users` receive sudo access to its fixed
`configure`, `completions` and `clear-blocked` entry points; root remains
responsible for access policy. Settings are parsed as data and atomically
replaced. `clear-blocked` takes no arguments and only creates the state marker
that makes the next upgrade retry blocked casks; it opens that path with
`O_NOFOLLOW` and never truncates, so a symlink in the `_brewau`-owned state
directory cannot aim root at another file. The helper and GUI
are separate arm64 executables with hardened runtime signing for release.

Changing preferences does not reload or kill running workers. Installer preflight
and daemon reload refuse to replace an active worker. The upgrade flow preserves
app protection and signature verification, and forces noninteractive confirmation
and no automatic cask quitting using Homebrew's supported environment settings.

The app, the scheduler and the helper log operations, failures and privileged calls
to the unified log under subsystem `com.kastruppro.brewau`, in the categories `app`,
`agent` and `helper`:

```sh
log show --last 1h --predicate 'subsystem == "com.kastruppro.brewau"'
```

Lines carry package names and versions, job names, the fixed command lines of helper
calls and their exit codes, marked `.public` so they stay readable. Child output,
file contents, environments and the localized error descriptions that can contain
them are deliberately kept out: a failure is logged as the fact that the job failed,
and the detail stays in `/opt/brewau/var/log/upgrade.log`.

The scheduler's own lines in that log are English and use the same
`<timestamp> [<job>] <message>` shape as the shell layer. Every line passes through
one formatter that flattens control characters, line and paragraph separators, so a
package name or a child's output cannot forge a second, untagged entry. Result files
are read with a 1 MB limit, at most 500 items per array, and each string bounded and
flattened as it is parsed.

The original visual prototype remains in `mockup/` for design reference and is
not included in the installer.

API references: [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra),
[SMAppService](https://developer.apple.com/documentation/ServiceManagement/SMAppService),
[notifications](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter),
[Homebrew flags](https://docs.brew.sh/Manpage),
[zsh completion security](https://zsh.sourceforge.io/Doc/Release/Completion-System.html).
