#!/usr/bin/env bash
# claude-run.sh <out-prefix> <cwd> <prompt> [claude args...]
# A headless Claude Code session with wtenv's hooks (spike/settings.json),
# outside the calling session: its CLAUDE*_ variables are dropped, the
# config dir kept. Writes <out-prefix>.jsonl (stream-json) and
# <out-prefix>.debug, and prints the session id and the wall time.
set -euo pipefail
out=$1 cwd=$2 prompt=$3; shift 3
here="$(cd "$(dirname "$0")" && pwd)"
unset_args=()
for v in $(env | sed -n 's/^\(CLAUDECODE\|CLAUDE_CODE_[A-Z_]*\|CLAUDE_PID\|CLAUDE_EFFORT\|CLAUDE_JOB_DIR\)=.*/\1/p'); do unset_args+=(-u "$v"); done
cd "$cwd"
t0=$(python3 -c 'import time;print(time.time())')
env "${unset_args[@]}" claude -p "$prompt" --settings "$here/settings.json" --setting-sources project \
  --permission-mode dontAsk --allowedTools Bash Read --model sonnet \
  --output-format stream-json --verbose --debug-file "$out.debug" "$@" >"$out.jsonl" 2>"$out.err" || true
t1=$(python3 -c 'import time;print(time.time())')
sid=$(head -1 "$out.jsonl" | jq -r '.session_id // empty')
python3 -c "print('session $sid wall %.1f s' % ($t1-$t0))"
