# Review notes

Deliberate, documented limitations and review findings that were checked and should not be
reported again as new bugs. Add evidence when an entry changes.

## Known limitations

- **Open write handles survive the Homebrew prefix takeover** (review of `cca8c4f`, 2026-11-26).
  A local user who opened a file under `/opt/homebrew` for writing while it was still group- or
  world-writable (before `brewau-setup install` took the prefix over) can keep writing through
  that descriptor after the modes are tightened. brewau does not replace every previously
  writable file with a fresh inode at install time. Whoever could write there before the takeover
  could also change Homebrew's code directly, which `check_repos` flags as far as git can tell.
  Mitigation for a clean boundary: install brewau before other users have write access to the
  prefix, or log other users out / reboot after installing. Tracked as a follow-up in FIXES.md.

- **Uninstall does not stop root services that run Homebrew code** (owner decision 2026-11-26,
  after review of `3f45c41`). Uninstall hands `/opt/homebrew` back to its recorded original owner
  and modes, which is stock Homebrew. Root services (`sudo brew services`, custom system daemons)
  that then run admin-writable Homebrew code are Homebrew's normal model, and admins can already
  become root, so this is not a brewau boundary after uninstall. Uninstall refuses to hand the
  prefix back when the original owner is not an admin, because only then would it create new
  access. Do not report missing service shutdown, leftover workers, launchd label selection or
  restart instructions during uninstall as brewau bugs. An interrupted uninstall (for example
  App Management refusing a required change) leaves the same stock-Homebrew state and can be
  resumed.
