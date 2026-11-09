# brewau

Apple Silicon macOS only. The existing shell tools isolate Homebrew under `_brewau`.
Preserve that privilege boundary; do not bypass policy or weaken permissions.

- Run shell checks with `make test` and `make lint` when changing shell behavior.
- `mockup/` is a native SwiftUI design prototype. It uses sample data and must not
  execute Homebrew, change system settings, send real notifications, or restart apps.
- Build the prototype with `make mockup`; run its self-check with `make mockup-check`.
- `app/` is the real native app and its narrow privileged helper. Run `make app-check`,
  `make test`, and `make lint` for changes to the app/service. `make pkg` includes both.
- Outward release steps (`git push`, tags, `gh release`, notarize/staple, `make release`,
  `make tap` and the push of `../homebrew-tap`): never pipe their output into `head`, `tail`,
  `grep` or similar, because the pipe hides the exit status and the error. Push with an explicit
  remote and branch (`git push origin main`), then verify the remote state before reporting
  success: `git ls-remote origin HEAD` matches the local commit, `gh release view v<version>`
  lists both pkgs, and the tap's `Casks/brewau.rb` on GitHub has the new version and sha256.
  `.claude/hooks/block-piped-release.sh` enforces the pipe rule for Claude Code.
- `CLAUDE.md` references this file; keep project instructions here.
- Save code reviews in the repository root as
  `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md`, with lowercase agent/model names.
