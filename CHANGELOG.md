# Changelog

All notable changes to brewau. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). Details of each finding behind
0.4.0 are in [FIXES.md](FIXES.md).

## [0.7.0] - 2026-11-03

### Added

- Self-update through Homebrew: brewau's own tap `kastruppro/tap` carries a `brewau` cask
  (`brew install --cask kastruppro/tap/brewau`). After each scheduled upgrade, a root
  LaunchDaemon (`com.kastruppro.brewau.selfupdate`) installs a newer cask while it holds the
  scan/upgrade lock; `sudo brewau self-update` does so at once. The upgrade job leaves the
  brewau cask to it. Off when `kastruppro/tap` is not in `ALLOWED_TAPS` or `brewau` is in
  `UPGRADE_EXCLUDE`.
- `kastruppro/tap` is added to `ALLOWED_TAPS` once on install (new and existing
  configurations); removing it afterwards sticks.
- `PreventUninstall` in an MDM custom settings payload for `com.kastruppro.brewau` (computer
  scope) makes `sudo brewau uninstall` refuse. Example in `mdm/`; `brewau status` shows it.
- `make tap` points the tap's cask at a release (`scripts/update-tap`).

### Changed

- `brew uninstall brewau` is denied: it would only drop the cask record. Use
  `sudo brewau uninstall`, which now also removes that record.
- A first install started by `brew install --cask` finishes after `brew` has exited, instead
  of taking `/opt/homebrew` over under it.
- The package's preinstall no longer waits for brewau's jobs while a self-update (which holds
  their lock) installs it.

## [0.6.1] - 2026-11-03

### Fixed

- The 0.6.0 installer failed ("The installation failed") on a Mac whose `_brewau` had no
  trusted taps yet: Homebrew lists an empty trust store as `[]`, and the empty search result
  stopped `brewau-setup` under `pipefail`, after brew.env but before the LaunchDaemons. The same
  stopped `sudo brewau reload` and `config`. Tap trust now only warns when it cannot be read.

### Changed

- A denial that the configuration can lift now ends with the exact command to run, e.g.
  `sudo brewau config add ALLOWED_SERVICES tailscale` (also for taps and options), instead
  of `sudo brewau config (ALLOWED_SERVICES="tailscale")`, which was not a command.
  Values that are not plain names, and `--adopt`, get no such hint.
- When `brewau-setup` (the installer's postinstall, `reload`, ...) stops on a failing command,
  it now names the line and command, so `/var/log/install.log` shows why an install failed
  instead of only the Installer's generic error.

## [0.6.0] - 2026-11-03

### Added

- `sudo brewau config add|remove <KEY> <value>...` and `config set <KEY> <value>` change one
  setting without an editor, validate the result and apply it; `brewau config show` prints the
  configuration.
- Homebrew 7 tap trust: `brewau reload` (and install) runs `brew trust --tap` as `_brewau`
  for every tap in `ALLOWED_TAPS` and untrusts taps removed from it. `brew trust`/`brew untrust`
  with arguments are denied with a hint; without arguments they only list.

### Changed

- `sudo brewau config` opens `nano` instead of `vi` when neither `$VISUAL` nor `$EDITOR` is set.
- A comma in a list setting is refused with "separate the entries with spaces, not commas"
  instead of a generic invalid-value error.

## [0.5.1] - 2026-10-24

### Fixed

- Restarting a pending app took two tries: the confirmation alert took focus from the
  menu bar panel, which closed. Restart confirmation and errors are now shown inline.
- macOS asked "downloaded from the Internet?" again after every cask upgrade. Users
  cannot write to `_brewau`-owned apps, so Gatekeeper never stored their approval, and
  Homebrew only carries an existing approval over. brewau now marks an upgraded app as
  approved when it is signed by the Team ID recorded for the previous version and
  `spctl --assess` accepts it. First installs still ask.

## [0.5.0] - 2026-10-24

### Added

- Native Apple Silicon menu bar app with current/available version lists, settings,
  independent scans, interval/daily/weekly upgrade schedules and multiple times.
- Local notifications, launch at login, pending-restart detection and explicit per-app
  permission for forced restarts. Session actions remain in the logged-in GUI.
- A narrow native helper for validated schedule changes and trusted completion copies.
- Persistent scheduler and manual scan/upgrade LaunchDaemons with a shared OS lock,
  wake catch-up, atomic snapshots, failure reporting and safe reload behavior.
- Root-owned zsh completion copies, automatic shell setup with backups, and a repair
  action. zsh security checks remain enabled.
- brewau logo, app icon and menu bar icon (masters, exports and guidelines in
  `branding/logo/`). The menu bar icon shows waiting updates and running jobs.

### Fixed

- Unattended Homebrew upgrades no longer wait for the new default confirmation prompt.
- Homebrew leaves running cask apps open; restart is coordinated by the session app.
- A failed Homebrew refresh stops an upgrade before using stale metadata.
- The menu bar popover no longer shows an empty update list: `MenuBarExtra` windows
  sized its scroll view to zero, so it now gets the measured content height.
- Login Items lists the LaunchDaemons under brewau.app (`AssociatedBundleIdentifiers`)
  instead of the signing developer name. The app icon uses a larger mark, and the
  popover and settings headers use the brewau mark instead of a system symbol.

## [0.4.0] - Unreleased

### Security

- `brew install` gets the same check as `upgrade` before it runs: it upgrades an outdated cask,
  which runs code from the old app.
- A cask app path that is a symlink is refused instead of skipped, so brew no longer runs a
  cask's steps from wherever an admin pointed it.
- Cask apps are locked inside a directory only root can change, so an admin renaming things in
  `/Applications` can no longer point root's locking at other folders. Two runs locking the same
  app at once can no longer nest one copy inside the other.
- Locked cask apps are pinned in place with an `everyone deny delete` ACL, so admins can no
  longer swap one between brewau's signature check and Homebrew running its code.
- `brew install --adopt` is refused: it registered an app the user owned, and could keep
  changing, as a cask whose steps then ran that code as `_brewau`.
- Cask apps are locked right after every `install`, `reinstall` and `upgrade`, before any
  command that can run their code, and on every nightly run. Commands that would run code from
  an app that cannot be locked are refused.
- Locking no longer follows symlinks or changes hard-linked files elsewhere, so a user can no
  longer redirect it to system files.
- brewau records who signed each cask app. An app that others could have changed is replaced by
  a fresh copy, which must carry an intact signature from the same developer; otherwise it is
  marked untrusted until an administrator runs `sudo brewau trust-app`.
- Install and `brewau doctor` check Homebrew's repository and taps for local changes, commits
  that are not upstream, hooks, and git config that could run commands.
- Uninstall restores permissions and returns ownership without following paths users control.
  Kegs of root system daemons stay owned by root.
- `brew update-reset` no longer accepts repository paths.
- A line in `brewau.conf` that does not parse, or an unknown key, now blocks brew instead of
  being skipped, since it could be a misspelt restriction.

### Added

- `sudo brewau trust-app <app>` to trust an app again after checking it.
- `sudo brewau move-service-data <user> <formula>` to copy a service's data from before brewau.
- `brewau doctor` reports a stale `/etc/homebrew/brew.env`, untrusted apps, apps that could not
  be protected, and problems in Homebrew's repository and taps.
- `AUTO_UPGRADE` and `UPGRADE_GREEDY` accept `yes`/`no`, `true`/`false` and `on`/`off`.

### Changed

- User services are started from the plist in the formula's keg, with their paths moved to the
  user's own directory before they are first loaded. Only the service you start is touched.
- Config files a service is given as an argument (e.g. `redis.conf`) are copied with the user's
  own paths, and the service reads the copy.
- `brew services run` is refused (it could not work); use `start` and `stop`.
- `brew services list --json` returns a single JSON array, with system services included.
- Uninstall copies the data of the prefix owner's stopped services back to `/opt/homebrew/var`.
- The nightly job skips casks whose apps cannot be protected, and reports failed service
  restarts (`restart-failed`) and unprotected apps (`protect-failed`).
- Invalid schedule values and invalid tap or service names now warn and fall back to the
  default, instead of blocking every brew command; `sudo brewau config` still refuses them.
- `sudo brewau config` uses `$VISUAL` before `$EDITOR`.

### Fixed

- Services are found under Homebrew 7's names (`sh.brew.<formula>`). Before, user services were
  never relocated and system services never restarted after upgrades with current Homebrew.
- System services no longer leave their kegs owned by root, which made upgrades, cleanup and
  uninstall fail.
- Allowed commands and options at the end of a line in the allowlist (`--config`, `--help`,
  `-s`, `--pinned`, `update-reset`, ...) were refused.
- `UPGRADE_EXCLUDE` works for formulae from taps, and pinned formulae and casks no longer make
  every nightly run fail.
- `brew -v services` and `brew services --json` list system services.
- Taps with a custom remote ending in `/` are blocked.
- A first install that failed part-way grants users access when run again, including the
  previous owner of `/opt/homebrew`.
- `deny-user` on a user without access, and `doctor` with an unreadable last-run file.
- Upgrading from 0.2.0 with old config values no longer blocks brew.

## [0.3.0] - 2026-10-20

### Added

- `brew services`: services run as the calling user by default, with their files moved out of
  `/opt/homebrew/var`, which users cannot write to.
- `ALLOWED_SERVICES` lets formulae run as root system daemons (e.g. `tailscale`); services that
  need root but are not listed are refused. The nightly job restarts them after upgrades.

### Security

- Every privileged script pins `PATH`, and sudoers sets `secure_path` for `_brewau`: a program
  planted in the caller's `PATH` could run as `_brewau`.
- ACLs are removed from the prefix and cask apps; they could still grant write access.
- Uninstall closes access to `_brewau` before handing the prefix back.
- Installed taps that are not allowed are blocked by their remote URL when they use a custom
  remote.

### Fixed

- The nightly job reports failing `brew outdated` instead of "ok", and restores lost
  `UPGRADE_EXCLUDE` pins.
- `AUTO_UPGRADE=0` removes the schedule but keeps `brewau run` working.
- `brewau status` with `UPGRADE_HOUR` 08 or 09; `EDITOR` with arguments.

## [0.2.0] - 2026-10-20

### Security

- The policy checks the command line the way `brew` sees it: `brew -v sh` gave a shell as
  `_brewau`.
- Cask apps are owned by `_brewau` without group/world write, because cask uninstall steps can
  run code from inside the app.
- Installed taps that are not allowed are blocked, and `/etc/homebrew/brew.env` enforces the
  settings over other `brew.env` files.
- Audit log entries cannot be forged; `install.sh` only accepts packages from the release team.

### Added

- `brewau restore-shell`, run for every user by uninstall.
- `sudo brewau repair`.
- `UPGRADE_EXCLUDE` pins formulae, so they are not upgraded as dependencies either.

### Changed

- `sudo brewau config` only applies a configuration that parses.
- Users are added automatically only on the first install, so `deny-user` survives upgrades.
- Uninstall returns cask apps and prefix permissions to the original owner.

### Fixed

- A lock left by a killed run stopped all later runs; `brewau doctor` warns after 48 hours
  without a run.
- The LaunchDaemon is only reloaded when it changed.
- `setup-shell` works with symlinked dotfiles.

## [0.1.1] - 2026-10-20

### Fixed

- `brewau setup-shell` handles every way a profile puts `brew` in `PATH`, so the real `brew` no
  longer runs instead of the wrapper.

## [0.1.0] - 2026-10-20

### Added

- First release: a hidden `_brewau` account owns `/opt/homebrew` and runs Homebrew, including
  casks that need root, without passwords.
- The `brew` wrapper reaches `_brewau` only through `brew-policy`: allowlisted commands and
  options, plain package names, allowed taps, a clean environment and an audit log.
- A daily LaunchDaemon runs `brew update`, `upgrade --greedy` and `cleanup`.
- The `brewau` command for status, runs, logs, `doctor`, `setup-shell` and administration.
- A signed and notarized `.pkg`, and `install.sh`.
