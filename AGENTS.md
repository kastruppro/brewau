# brewau

Apple Silicon macOS only. The existing shell tools isolate Homebrew under `_brewau`.
Preserve that privilege boundary; do not bypass policy or weaken permissions.

- Run shell checks with `make test` and `make lint` when changing shell behavior.
- `mockup/` is a native SwiftUI design prototype. It uses sample data and must not
  execute Homebrew, change system settings, send real notifications, or restart apps.
- Build the prototype with `make mockup`; run its self-check with `make mockup-check`.
- `app/` is the real native app and its narrow privileged helper. Run `make app-check`,
  `make test`, and `make lint` for changes to the app/service. `make pkg` includes both.
- `CLAUDE.md` references this file; keep project instructions here.
- Save code reviews in the repository root as
  `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md`, with lowercase agent/model names.
