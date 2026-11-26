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
