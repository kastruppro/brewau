# Fixes

Findings from four code reviews of `1cea65c` (0.3.0), checked against the code and against
Homebrew 7.0.10's source. Sources: **R0** own review, **R1**/**R2**/**R3** the three external
reviews, **V** found while verifying or fixing, **F** found by a review of the fixes themselves.
All fixed items have tests (`make test`) except where root is needed (noted).

## Fixed

### Security

| # | Finding | Source | Fix |
|---|---|---|---|
| 1 | `--adopt` registers an app the user owns as a cask. Homebrew compares only the `Info.plist` versions (nothing for `auto_updates` casks) and keeps the owner, so e.g. OrbStack's `postflight` and `uninstall script:` run the user's `orbctl` as `_brewau`. | R1 #1 | `--adopt` removed from the allowlist. |
| 2 | Cask apps were locked only at install and before scheduled cask upgrades. A cask shipping group/world-writable files stayed writable after a user's `brew install --cask`. | R2 sec 1, V, F | Apps are locked right after every `install`/`reinstall`/`upgrade` through the policy (also when brew fails or is interrupted: INT, TERM, HUP, QUIT and PIPE are trapped, and ignored while locking), before any command that can run their code (`uninstall`, `upgrade`, `reinstall`, `install --force`), and on every nightly run. A command that would run code from an app that could not be locked is refused; the job skips that cask (`status=protect-failed`). |
| 3 | `brewau_protect_apps` ran `find`/`chown -h`/`chmod` as root over user-writable bundles, following a symlinked intermediate directory (e.g. `chown` of `/etc/sudoers`). | R0 #1, F | New `brewau_lock_tree`: directories are locked top-down, each only after all its parents, with a physical-path check that survives newlines in names; user flags (`uchg`, `uappnd`) are cleared first; files are handled only inside locked directories; `-h` everywhere. A directory it cannot lock no longer stops the rest; it is reported. |
| 4 | Users can hard-link any file, root's included (verified: `ln /private/etc/hosts /tmp/x` works), so a root `chown`/`chmod -N` over a user tree could change files elsewhere. | V, F | A hard-linked file is replaced by a copy before it is taken over (left alone, and reported, if it has user flags). Write bits and ACLs are never removed from someone else's hard-linked file. |
| 5 | Uninstall chowned the prefix back first and then ran root `chmod` from `original-modes` through paths the owner could already swap. `read` trimmed whitespace; `.` and `..` components were accepted (`700 /opt/homebrew/..` changed `/opt`). | R0 #2, V, F | Modes are restored while `_brewau` still owns the prefix; lines are parsed verbatim; `.`/`..` components are refused; names with a newline are not recorded; `chmod -h`. |
| 6 | Uninstall handed apps back top-down (`find` + `chown -h`), so the new owner could swap a directory before root reached its contents. | V | Depth-first (`find -d`). The prefix is also handed back children first, parents last. |
| 7 | Uninstall left root daemons running from kegs that `chown -hR` gave back to the owner, undoing Homebrew's own `take_root_ownership`. | R1 #2, F | Kegs of `/Library/LaunchDaemons/homebrew.mxcl.*` stay root-owned without group/world write, and brewau warns if the new prefix owner is not an admin (the `opt/` links stay under the owner's control, as in vanilla Homebrew). Needs root; not covered by tests. |
| 8 | A config line that did not parse (`FORBIDDEN_CASKS = "firefox"`, lowercase keys) or a misspelt key (`FORBIDEN_CASKS`) was skipped, which dropped the restriction. | R1 #7, F | Both are always fatal, with the line number. No key has ever been retired, so this breaks no old config. |
| 9 | A custom tap remote with a trailing slash was passed to Homebrew without it; Homebrew strips slashes only for GitHub, GitLab and Codeberg, so the tap was not blocked although `doctor` said it was. | R3 #6 | The remote is passed on unchanged. |

### Policy and allowlists

| # | Finding | Source | Fix |
|---|---|---|---|
| 10 | Allowlist entries at the end of a line never matched (`--config`, `missing`, `update-reset`, `--help`, `-s`, `--pinned`, `--include-test`, …). | R1 #8 | Shared `brewau_in_words` splits on any whitespace and rejects words containing whitespace. It also replaces the four duplicated word-list loops. |
| 10a | Fixing #10 made `update-reset` reachable, whose arguments are repository paths relative to `/`: `brew update-reset tmp` ran git as `_brewau` on a `/tmp/.git` any user can create. | F | `update-reset` takes options only. |
| 11 | `--quiet` and `--casks` were listed twice. | R2 | Removed. |
| 12 | `brew -v services` / `brew services --json` took the option as the action, so system services were not listed and the policy refused the command. | R2 bug 1 | Action and formula are the first two words wherever options are, in the wrapper and the policy. (R2's patch was not used: it dropped the formula name.) |
| 13 | The deny message told admins to edit `brewau.conf` by hand, which leaves `brew.env` stale. | R3 #4 | It now says `sudo brewau config`. |

### `brew services`

| # | Finding | Source | Fix |
|---|---|---|---|
| 14 | `brew services start/restart` as root made the keg root-owned and sticky, so `_brewau` could no longer upgrade, clean up or uninstall it. | R0 #3, R1 #3 | The keg is handed back to `_brewau` after `start`/`restart`, by the policy and by the job's restarts. `repair`/postinstall fix existing installs. |
| 15 | Any `start`/`restart`/`run` rewrote and restarted every Homebrew LaunchAgent, moving pre-brewau services' data paths away from their data. | R0 #4 | Only the named service's agent is relocated (all agents only for `--all`). |
| 16 | `brew services run` never worked: Homebrew loads the keg's plist (not relocated), and root refuses `run`. | R0 #5, R1 #5, R3 #1 | Refused with a pointer to `start`, in the wrapper and the policy. |
| 16a | Homebrew's action aliases (`s`, `load`, `r`, `ls`, …) skipped system routing and relocation. | F | Resolved to the actions they mean, in the wrapper and the policy. |
| 17 | An allowed service the user had already started as their own agent could not be stopped through brew, and a second system copy could be started. | R0 #6 | `start`/`restart` refuse while a user agent exists; `stop`/`kill` stop the user agent and the system daemon. |
| 18 | `brew services list --json` printed two arrays and a text header. | R0 #7, R1 #9 | One merged array; allowed services come from the system listing. |
| 19 | Homebrew fails creating directories in `/opt/homebrew/var` after writing the agent, so `start` reported failure although relocation then loaded the service. Conversely, a failed relocation (agent already booted out) reported success. | R3 #9, F | Exit code 0 once the relocated agent is loaded, with a note about Homebrew's error; non-zero when relocation fails. |
| 20 | `brewau_rewrite_file` returned `rm`'s status, so a failed rewrite looked like success. | R3 #7 | Returns the filter's (and the write's) status; callers report the failure. |

### Upgrade job

| # | Finding | Source | Fix |
|---|---|---|---|
| 21 | `brew outdated --quiet` prints tap formulae as `user/repo/name` (or the alias they were installed by), while pins and `UPGRADE_EXCLUDE` use plain names: user-pinned tap formulae made every run `upgrade-failed`, and tap services were never restarted. | R3 #5 | `brew outdated --json=v2` is used; pinned entries are left out; names are compared without their tap. |
| 22 | Qualified `UPGRADE_EXCLUDE` names (`acme/tools/db`) were never pinned, so they could be upgraded as dependencies. | R1 #4 | Pinned by their plain name. |
| 23 | Pinned casks were passed to `brew upgrade --cask`, which fails for a pinned cask named explicitly, so every run was `upgrade-failed`. | V | Covered by #21. |
| 24 | A failed system-service restart left `status=ok`. | R1 #6 | `status=restart-failed`. |
| 25 | `brew list --pinned` ran twice, and every brew call rescanned all taps with git. | R0 #10 | One `outdated` call; forbidden taps are computed once per run (`brewau_cache_forbidden_taps`). |

### Install, config and doctor

| # | Finding | Source | Fix |
|---|---|---|---|
| 26 | The stricter 0.3.0 validation died on old values (`AUTO_UPGRADE="no"`), failing the pkg postinstall and every brew command. | R0 #9 | `sudo brewau config` is strict. Otherwise booleans accept yes/no/true/false/on/off, an invalid schedule falls back to the default, and invalid `ALLOWED_TAPS`/`ALLOWED_SERVICES` entries are ignored (all with a warning). |
| 26a | An app that could not be locked made `brewau-setup install` (pkg postinstall, `repair`) abort under `set -e` before loading the daemon. | F | Logged as a warning; those casks are refused until the app is fixed (#2). |
| 27 | Invalid `ALLOWED_TAPS` entries (`my-tap`) were accepted silently. | R2 sec 2 | Refused by `brewau config`, ignored with a warning otherwise. |
| 28 | An install that failed after writing `original-owner` (inside `take_over_prefix`) was treated as a re-install on retry, so no users were granted access. | R3 #2 (partly) | First install unless the marker exists, or `original-owner` and sudoers both do (finished pre-marker installs). |
| 29 | `doctor` reported "no scheduled run for ~20000 days" for an unreadable `last-run`. | R2 bug 3, R3 #8 | Reports the file as unreadable. |
| 30 | `doctor` could not tell that `/etc/homebrew/brew.env` (which Homebrew applies over the policy's environment) was stale. | R3 #4 | Compares it with `brewau.conf`. |
| 31 | `deny-user` on a non-member died with dseditgroup's error. | R2 bug 4 | Says the user has no access. A deleted user's leftover membership can still be removed. (R2's patch was not used: it reported success when removal failed.) |
| 32 | `daemon_loaded` existed twice. | R3 #10 | `brewau_daemon_loaded` in `common.sh`. |
| 33 | `brewau config` ignored `VISUAL`. | V | Uses `$VISUAL`, then `$EDITOR`. |

## Mitigated, not fully solved

- **Formula config files hard-code `/opt/homebrew/var`** (R0 #8). Rewriting them generically is
  unsafe: the user var path contains a space (`Application Support`), which most config syntaxes
  would split. Relocation now names such config files (e.g. `redis.conf`) so the user can run the
  service with their own copy.
- **Service data stranded at uninstall** (R3 #3). Uninstall names every relocated service and
  where its data is, but does not move databases automatically.
- **Pre-brewau service data** (R0 #4). It is owned by `_brewau` after install, so the user cannot
  copy it; relocation prints the `sudo ditto … && sudo chown …` command for an admin.
- **Generating the user plist instead of relocating Homebrew's** (R3 #9) would remove the
  start/stop/relocate dance, but means re-implementing Homebrew's service logic. Not done.

## Residual risk (documented in README)

- Whoever owned `/opt/homebrew` and the cask apps before brewau took them over is trusted:
  locking stops further changes but cannot undo changes made while something was writable.
- Admins can write to `/Applications` and so swap a protected app.

## Review claims that did not hold

- R2 bug 2 (missing `else` after `exec`): a failed `exec` ends a non-interactive bash (rc 126), so
  nothing falls through. The services path is restructured anyway.
- R2 security 3 (`EDITOR` lost under sudo): macOS's default sudoers keeps `EDITOR` and `VISUAL`.
  `sudo -E` would hand the whole environment to root.

## Open

- `VERSION` is still `0.3.0`; bump it before the next release.
