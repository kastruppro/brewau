#!/bin/bash
# PreToolUse hook: refuse outward release commands whose output is piped into
# head/tail/grep/awk/sed/less/cut. The pipe hides the exit status and the error, so
# a failed push or upload looks like success (2026-11-09: a tap push failed silently).
cmd="$(jq -r '.tool_input.command // empty')"
outward='(git[[:space:]]([^|]*[[:space:]])?push([[:space:]]|$)|gh[[:space:]]+release|notarytool|stapler|make[[:space:]]([^|]*[[:space:]])?(release|tap)([[:space:]]|$))'
filter='\|[[:space:]]*(head|tail|grep|awk|sed|less|cut)([[:space:]]|$)'
# Check each command of a list (split on ;, && and ||) on its own.
if printf '%s\n' "${cmd}" | sed -E 's/(;|&&|\|\|)/\n/g' | grep -Eq "${outward}.*${filter}"; then
  echo "Run push/release/notarize/tap commands without piping their output (no | head, tail, grep...): the pipe hides failures. Run it unpiped, check the exit code, then verify the remote state (e.g. git ls-remote origin HEAD, gh release view, git status -sb)." >&2
  exit 2
fi
exit 0
