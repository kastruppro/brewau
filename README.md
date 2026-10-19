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

- `/opt/homebrew` is owned by `_brewau` with group/world write removed, so neither you nor
  other admins' processes can plant code that Homebrew will run.
- The wrapper reaches `_brewau` only through `brew-policy`, which is root-owned and
  default-deny:
  - only allowlisted subcommands (`install`, `upgrade`, `info`, …). `sh`, `ruby`, `irb`, `edit`,
    `extract`, `bundle`, `services`, `tap-new`, developer commands and unknown commands are refused;
  - only allowlisted options (`--cc`, `--appdir`, `--interactive`, `--debug`, … are refused);
  - package arguments must be plain names: no paths, URLs or `file://`;
  - packages and taps outside `homebrew/*` must be in `ALLOWED_TAPS`;
  - brew runs with `env -i` plus a fixed environment, so `HOMEBREW_*` variables, `~/.homebrew/brew.env`
    and similar cannot be injected.
- Every invocation is logged with the calling user to `/opt/brewau/var/log/audit.log`.

Residual risk, shared with Workbrew:
- A cask that ships a `.pkg` runs its installer as root. You are trusting the casks you install
  and the taps in `ALLOWED_TAPS`.
- Apps in `/Applications` that you can write to may include uninstall scripts that a cask
  uninstall stanza runs as root.

## Install

Requires an Apple Silicon Mac with Homebrew in `/opt/homebrew`.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kastruppro/brewau/main/install.sh)"
brewau setup-shell   # points `brew shellenv` in your profile at the wrapper
# open a new terminal
brewau doctor
```

Alternatively download `brewau.pkg` from Releases, or deploy it with MDM. The installer:
creates `_brewau` and `brewau_users`, adds the console user and the previous prefix owner to
`brewau_users`, transfers `/opt/homebrew` to `_brewau`, allowlists any taps you already have,
and loads the daily job.

## Usage

`brew` works as before, within the policy. Additionally:

```sh
brewau status          # schedule, last run, what was upgraded
brewau run             # run the upgrade job now
brewau log -f          # follow the upgrade log
brewau log --audit     # who ran which brew command
brewau doctor          # health check

sudo brewau config     # edit policy/schedule and apply it
sudo brewau allow-user alice
sudo brewau uninstall  # returns /opt/homebrew to its original owner
```

## Configuration

`/opt/brewau/etc/brewau.conf` (root-owned, parsed and never executed):

| Key | Default | Meaning |
|---|---|---|
| `ALLOWED_TAPS` | existing taps | extra taps users may install from |
| `FORBIDDEN_FORMULAE`, `FORBIDDEN_CASKS` | empty | never installable |
| `EXTRA_ALLOWED_OPTIONS` | empty | brew options to allow beyond the built-in list |
| `AUTO_UPGRADE` | `1` | enable the nightly job |
| `UPGRADE_GREEDY` | `1` | include self-updating casks |
| `UPGRADE_EXCLUDE` | empty | never auto-upgrade these |
| `UPGRADE_HOUR`, `UPGRADE_MINUTE` | `4`, `0` | when to run; missed runs happen on wake |

## Limitations

- `brew services` and `brew bundle` are blocked. Services would run as `_brewau`, and
  Brewfiles are Ruby.
- Files under `/opt/homebrew` are no longer writable by you. That includes `npm -g`,
  `gem install` into Homebrew's Ruby, and editing configs in `/opt/homebrew/etc`. Use
  per-user prefixes (`npm config set prefix ~/.npm-global`), or `sudo -u _brewau` for one-off config edits.
- macOS "App Management" privacy protection may stop the background job from replacing some
  apps. Check `brewau log` after the first run.
- Intel Macs (`/usr/local`) are not supported.

## Building and releasing

```sh
make test                  # policy unit tests
make pkg                   # unsigned build/brewau-<version>-unsigned.pkg
make install               # install this checkout locally (sudo)

# one-time: store notarization credentials
xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>

make release INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" NOTARY_PROFILE=<profile>
# upload build/brewau.pkg to a GitHub release
```
