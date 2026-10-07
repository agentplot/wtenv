#!/bin/sh
# wtenv's loader, for SessionStart, CwdChanged and FileChanged.
#
# A hit is written to this event's env file at once. A miss starts a detached
# build that writes the file when it is done, and the file says meanwhile
# which root it waits for (WTENV_PENDING), so the PreToolUse guard holds Bash
# commands until then. Whichever event loaded last owns the environment: the
# session's other env files are emptied, so a resumed session never sources a
# previous process's file.
#
#   load.sh <event>     hook input on stdin

event=$1
input=$(cat)
wtenv=${WTENV_BIN:-wtenv}
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
dir=$(dirname "$CLAUDE_ENV_FILE")

case "$event" in
cwd-changed) cwd=$(printf '%s' "$input" | jq -r '.new_cwd // .cwd') ;;
*) cwd=$(printf '%s' "$input" | jq -r '.cwd') ;;
esac

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

own() { # make $1 the only env file with content
  for f in "$dir"/*.sh; do
    [ "$f" = "$CLAUDE_ENV_FILE" ] || : >"$f"
  done
}

write() { # atomically replace this event's env file
  printf '%s\n' "$1" >"$CLAUDE_ENV_FILE.wtenv.$$" && mv -f "$CLAUDE_ENV_FILE.wtenv.$$" "$CLAUDE_ENV_FILE"
}

cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""

if out=$(WTENV_QUIET=1 "$wtenv" export --format claude --no-build --timeout "${WTENV_LOAD_WAIT:-0}" 2>"$dir/wtenv.log"); then
  write "$out"
  own
  status="loaded"
else
  # A miss: the build runs detached and writes this file when it is done.
  write "export WTENV_PENDING=$(shq "$root")
true"
  own
  WTENV_QUIET=1 "$wtenv" warm --write "$CLAUDE_ENV_FILE" >/dev/null 2>&1
  status="building"
fi

# The key files to watch for this root.
watch=""
for f in devenv.nix devenv.yaml devenv.lock devenv.local.nix flake.nix flake.lock mise.toml .tool-versions; do
  [ -n "$root" ] && [ -e "$root/$f" ] && watch="$watch${watch:+,}\"$root/$f\""
done

case "$event" in
session-start)
  msg="wtenv: environment for $root $status."
  [ "$status" = building ] && msg="$msg Bash commands wait for it (a first build takes minutes)."
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s,"watchPaths":[%s]}}\n' "$(printf '%s' "$msg" | jq -Rs .)" "$watch"
  ;;
cwd-changed | file-changed)
  printf '{"watchPaths":[%s]}\n' "$watch"
  ;;
esac
exit 0
