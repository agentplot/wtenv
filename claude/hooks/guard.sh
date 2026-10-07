#!/bin/sh
# wtenv's guard, PreToolUse on Bash.
#
# CwdChanged and FileChanged hooks are not awaited, and a miss loads in the
# background, so a command can arrive before its environment. The guard
# compares the root the session's env files hold (WTENV_ROOT) with the root
# of the directory the command runs in, waits up to WTENV_GUARD_WAIT seconds
# for them to agree, and otherwise refuses the command, saying why.

input=$(cat)
session=$(printf '%s' "$input" | jq -r '.session_id')
cwd=$(printf '%s' "$input" | jq -r '.cwd')
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$session"

want=""
if root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  for f in devenv.nix devenv.yaml flake.nix mise.toml .tool-versions; do
    if [ -e "$root/$f" ]; then want=$root; break; fi
  done
fi

loaded() { # the root the env files hold; "-" while one waits for a build
  cat "$dir"/*.sh 2>/dev/null | sed -n \
    -e "s/^export WTENV_ROOT='\(.*\)'\$/\1/p" \
    -e "s/^export WTENV_PENDING='.*'\$/-/p" | tail -1
}

# A deadline by the clock, well inside the hook's own timeout: a PreToolUse
# hook that times out is cancelled and the command runs.
# A mismatch that outlives a loader's run, with no build pending, is loaded
# here, into the session's SessionStart file.
start=$(date +%s)
deadline=$((start + ${WTENV_GUARD_WAIT:-10}))
healed=0
while :; do
  have=$(loaded)
  [ "$have" = "$want" ] && exit 0
  now=$(date +%s)
  [ "$now" -ge "$deadline" ] && break
  if [ $healed -eq 0 ] && [ "$have" != "-" ] && [ $((now - start)) -ge 2 ]; then
    healed=1
    printf '{"cwd":"%s"}' "$cwd" | CLAUDE_ENV_FILE="$dir/sessionstart-hook-0.sh" \
      WTENV_BIN="${WTENV_BIN:-$(dirname "$0")/../../bin/wtenv}" sh "$(dirname "$0")/load.sh" heal >/dev/null 2>&1
    continue
  fi
  sleep 0.2
done

if [ "$have" = "-" ]; then
  why="wtenv: the environment for $want is still loading (its first build takes minutes). Retry this command shortly; anything not needing the project's tools can run meanwhile."
else
  why="wtenv: environment still loading for ${want:-this directory} (loaded: ${have:-none}). Retry this command."
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(printf '%s' "$why" | jq -Rs .)"
exit 0
