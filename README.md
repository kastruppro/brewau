# brewau

Unattended, isolated Homebrew for macOS, modelled on [Workbrew](https://workbrew.com)'s agent
but local and self-hosted. Apps and formulae stay up to date every night, including casks that
need `sudo`, without anyone typing a password.

## How it works

```
you ── brew ──▶ /opt/brewau/bin/brew                     (wrapper, root-owned)
                   │ sudo -u _brewau  (brewau_users only)
                   ▼
               /opt/brewau/libexec/brew-policy           (allowlist, audit log)
                   │ exec, clean environment
                   ▼
               /opt/homebrew/bin/brew  as _brewau        (owns /opt/homebrew)
                   │ sudo -E  (NOPASSWD, only for _brewau)
                   ▼
               root: pkg installers, /Applications moves

launchd ── daily ──▶ brewau-upgrade as _brewau ──▶ brew update / upgrade --greedy / cleanup
```

| Piece | Workbrew equivalent |
|---|---|
| `_brewau` hidden service account, owns `/opt/homebrew` | `workbrew` + `_workbrewd` |
| `/etc/sudoers.d/brewau`: `_brewau ALL=(root) NOPASSWD: ALL` | `/etc/sudoers.d/workbrew` |
| `brewau_users` group gates who may run `brew` | `workbrew_users` |
| `/opt/brewau/bin/brew` wrapper + `brew-policy` | `/opt/workbrew/bin/brew` |
| LaunchDaemon `com.kastruppro.brewau.upgrade` | `com.workbrew.workbrew-agent` |
| `/opt/brewau/etc/brewau.conf` | Console policies / Brew Configurations |

## Security model

`_brewau` can become root without a password; that is what makes unattended cask upgrades
possible. Whatever can make `_brewau` run code therefore gets root, so the isolation only
holds if nothing but the policy can steer `_brewau`:

- `/opt/homebrew` is owned by `_brewau` with group/world write and ACLs removed, so neither
  you nor other admins' processes can plant code that Homebrew will run.
- The wrapper reaches `_brewau` only through `brew-policy`, which is root-owned and
  default-deny. It and the other privileged scripts pin `PATH` before running anything, and
  sudoers sets `secure_path` for `_brewau`, so programs planted in your `PATH` never run there.
  - only allowlisted subcommands (`install`, `upgrade`, `info`, …). `sh`, `ruby`, `irb`, `edit`,
    `extract`, `bundle`, `services`, `tap-new`, developer commands and unknown commands are refused;
  - only allowlisted options (`--cc`, `--appdir`, `--interactive`, `--debug`, … are refused);
  - the command line is checked the way `brew` will see it (`brew -v sh` is `brew sh -v`);
  - package arguments must be plain names: no paths, URLs or `file://`;
  - packages and taps outside `homebrew/*` must be in `ALLOWED_TAPS`; taps that are installed
    but not allowed are passed to Homebrew as `HOMEBREW_FORBIDDEN_TAPS`, so unqualified names
    and dependencies cannot resolve to them either;
  - brew runs with `env -i` plus a fixed environment and a private temp directory, so `HOMEBREW_*`
    variables cannot be injected. `/etc/homebrew/brew.env` (with
    `HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY`) keeps prefix or user `brew.env` files from overriding
    the enforced settings.
- Apps installed by casks are owned by `_brewau`, without group/world write or ACLs, because cask
  upgrade/uninstall steps can run code from inside the app (e.g. `uninstall script:`). They are
  locked right after every `install`, `reinstall` and `upgrade`, and again before any command
  that can run their code (`uninstall`, `upgrade`, `reinstall`, `install --force`) and on every
  nightly run, in case an updater replaced them. If an app cannot be locked, brew refuses those
  commands for its cask and the nightly job skips it (`brewau doctor` reports it). Locking runs
  as root over files users may still be changing, so it works top-down, never follows a symlink,
  and replaces hard-linked files by copies rather than change the file they share. `--adopt` is
  refused: it would register an app you own, and can keep changing, as a cask.
- Every invocation is logged with the calling user to `/opt/brewau/var/log/audit.log`.

Residual risk, shared with Workbrew:
- A cask that ships a `.pkg` runs its installer as root. You are trusting the casks you install
  and the taps in `ALLOWED_TAPS`.
- Whoever owned `/opt/homebrew` and the cask apps before brewau took them over is trusted:
  anything they planted there beforehand runs as `_brewau` later. Locking an app stops further
  changes; it cannot undo changes made while the app was writable.
- Admins can write to `/Applications` itself, so an admin account can swap a protected app for
  its own copy and then run `brew uninstall`/`upgrade` on that cask. For admin members of
  `brewau_users`, app protection closes accidental drift (self-updaters), not a deliberate attack.
  Standard users cannot do this.
- Everyone in `brewau_users` shares one package set: they can uninstall or untap what others use.

## Install

Requires an Apple Silicon Mac with Homebrew in `/opt/homebrew`.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kastruppro/brewau/main/install.sh)"
/opt/brewau/bin/brewau setup-shell   # points `brew shellenv` in your profile at the wrapper
# open a new terminal
brewau doctor
```

`install.sh` only installs a package that is notarized and signed by the brewau release team
(override with `BREWAU_TEAM_ID` for forks).

Alternatively download `brewau.pkg` from Releases, or deploy it with MDM. The installer:
creates `_brewau` and `brewau_users`, transfers `/opt/homebrew` and the apps of installed casks
to `_brewau`, allowlists any taps you already have, and loads the daily job. On the first install
only, it also adds the console user and the previous prefix owner to `brewau_users`; upgrades
leave group membership alone, so `deny-user` sticks.

## Usage

`brew` works as before, within the policy. Additionally:

```sh
brewau status          # schedule, last run, what was upgraded
brewau run             # run the upgrade job now
brewau log -f          # follow the upgrade log
brewau log --audit     # who ran which brew command
brewau doctor          # health check
brewau restore-shell   # undo setup-shell

sudo brewau config     # edit policy/schedule ($VISUAL/$EDITOR); only applied if it validates
sudo brewau allow-user alice
sudo brewau repair     # re-apply ownership, permissions and system files
sudo brewau uninstall  # closes access to _brewau first, then returns /opt/homebrew, apps,
                       # permissions and shell profiles
```

On uninstall, Homebrew system daemons keep running; their kegs stay owned by root, as
`sudo brew services start` leaves them, and brewau warns if the new owner of `/opt/homebrew`
is not an administrator. It also names services whose data is still in
`~/Library/Application Support/brewau/var`: move it back to `/opt/homebrew/var` before the
next `brew services start` or `restart` of that service.

## Configuration

`/opt/brewau/etc/brewau.conf` (root-owned, parsed and never executed):

| Key | Default | Meaning |
|---|---|---|
| `ALLOWED_TAPS` | existing taps | extra taps users may install from |
| `FORBIDDEN_FORMULAE`, `FORBIDDEN_CASKS` | empty | never installable |
| `EXTRA_ALLOWED_OPTIONS` | empty | brew options to allow beyond the built-in list |
| `AUTO_UPGRADE` | `1` | enable the nightly job; with `0`, `brewau run` still starts one by hand |
| `UPGRADE_GREEDY` | `1` | include self-updating casks |
| `ALLOWED_SERVICES` | empty | formulae whose `brew services` run as root system daemons (e.g. `tailscale`) |
| `UPGRADE_EXCLUDE` | empty | never auto-upgrade these, with or without their tap (formulae are pinned, so they are not upgraded as dependencies either) |
| `UPGRADE_HOUR`, `UPGRADE_MINUTE` | `4`, `0` | when to run; a run missed while asleep happens on wake, a run missed while powered off is skipped (`brewau doctor` warns after 48 hours) |

`AUTO_UPGRADE` and `UPGRADE_GREEDY` also accept `yes`/`no`, `true`/`false` and `on`/`off`.
`sudo brewau config` refuses anything it does not understand. A file edited by hand is checked
on every `brew` command: a line that is not `KEY="value"` or an unknown key blocks brew until it
is fixed (either could be a misspelt restriction), while an invalid time or switch, or an
invalid tap or service name, only warns, and the default is used or the entry is ignored. After
editing by hand, run `sudo brewau reload`: forbidden packages are enforced through
`/etc/homebrew/brew.env`, which takes priority over everything else (`brewau doctor` reports a
stale one).

## Services

`brew services` works, in two modes:

- **As you (default).** Homebrew starts the service as a LaunchAgent for your account, like
  vanilla Homebrew, without any extra privileges. Because you cannot write to
  `/opt/homebrew/var`, brewau moves the service's paths there (logs, data, working directory) to
  `~/Library/Application Support/brewau/var`. Only the agent of the service you start is moved.
  Data directories that a formula normally creates during installation (e.g. a database cluster)
  start out empty there, and brewau names them; initialise them yourself, e.g.
  `initdb -D ~/Library/Application\ Support/brewau/var/postgresql@17`. Data the service had in
  `/opt/homebrew/var` before brewau is now `_brewau`'s; brewau prints the command an
  administrator can use to copy it over. Config files in `/opt/homebrew/etc` that point into
  `/opt/homebrew/var` (e.g. `redis.conf`) are named too: run the service with a copy that uses
  your own paths. `brew services run` is not supported, because Homebrew would run the service
  with its files in `/opt/homebrew/var`; use `start` and `stop`.
- **As a system daemon (root).** Formulae listed in `ALLOWED_SERVICES` run as root
  LaunchDaemons, started at boot. Use it for services that need root, which Homebrew marks as
  `require_root` (e.g. `tailscale`, `dnsmasq`, `unbound`); brewau refuses to start those as you.
  Only `list`, `info`, `start`, `stop`, `restart` and `kill` are allowed, without
  `--file` or `--sudo-service-user`. The nightly job restarts them after upgrading their formula.
  Homebrew makes a root service's keg root-owned; brewau hands it back to `_brewau` (which has
  root anyway), so upgrades keep working. If you ran the service as your own agent before it
  was allowed, `brew services stop` it first: brewau will not start a second, system copy.
  `brew services list --json` returns one array, with allowed services as the system sees them.

```sh
sudo brewau config            # ALLOWED_SERVICES="tailscale"
brew install tailscale
brew services start tailscale # root daemon
sudo tailscale up             # first login; add --operator=$USER to use tailscale without sudo
```

Anything in `ALLOWED_SERVICES` runs as root, so a vulnerability in it is a root compromise.

## Troubleshooting

**`Operation not permitted` when a cask changes its app** (e.g. Parallels:
`chown: /Applications/Parallels Desktop.app/...: Operation not permitted`). macOS App Management
blocks changes to app bundles, even by root, unless the app that started the command is allowed.
Enable your terminal (Terminal, iTerm, Ghostty, ...) in System Settings → Privacy & Security →
App Management and run the command again. The nightly job has no terminal; on managed Macs
grant App Management with an MDM Privacy Preferences (PPPC) profile, otherwise update such
apps by hand (`brewau doctor` reports it).

## Limitations

- `brew bundle` is blocked: Brewfiles are Ruby.
- Files under `/opt/homebrew` are no longer writable by you. That includes `npm -g`,
  `gem install` into Homebrew's Ruby, and editing configs in `/opt/homebrew/etc`. Use
  per-user prefixes (`npm config set prefix ~/.npm-global`), or `sudo -u _brewau` for one-off config edits.
- Apps installed by casks can no longer update themselves as you (they are owned by
  `_brewau`); the nightly job updates them instead, including self-updating ones with
  `UPGRADE_GREEDY=1`.
- macOS "App Management" privacy protection may stop the background job from replacing some
  apps. Check `brewau log` after the first run.
- Intel Macs (`/usr/local`) are not supported.

## Building and releasing

```sh
make test                  # policy, config and shell-profile tests
make pkg                   # unsigned build/brewau-<version>-unsigned.pkg
make install               # install this checkout locally (sudo)

# one-time: store notarization credentials
xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>

make release INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" NOTARY_PROFILE=<profile>
# upload build/brewau.pkg to a GitHub release
```
