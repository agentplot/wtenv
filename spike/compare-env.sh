#!/usr/bin/env bash
# compare-env.sh <adapter> — in the current worktree, load the environment two
# ways from the same starting environment, wtenv's cached one and the tool's
# own, and print every variable whose value differs (excluded ones aside).
#
#   devenv: `source <(devenv print-dev-env)` in Nix's bash 5
#   mise:   `eval "$(mise env -s bash)"`
set -euo pipefail
adapter=$1
here="$(cd "$(dirname "$0")/.." && pwd)"
bash5=${BASH5:-/run/current-system/sw/bin/bash}
tmp="$(mktemp -d "${TMPDIR:-/tmp}/compare.XXXXXX")"
WTENV_QUIET=1 "$here/bin/wtenv" export >"$tmp/wtenv.sh"
"$bash5" -c 'source "$1" >/dev/null 2>&1; env -0' _ "$tmp/wtenv.sh" >"$tmp/a"
case "$adapter" in
devenv) devenv print-dev-env 2>/dev/null >"$tmp/native.sh"
        "$bash5" -c 'source "$1" >/dev/null 2>&1; env -0' _ "$tmp/native.sh" >"$tmp/b" ;;
mise)   "$bash5" -c 'eval "$(mise env -s bash)"; env -0' >"$tmp/b" ;;
esac
"$bash5" -s -- "$tmp/a" "$tmp/b" <<'PY'
declare -A A B
while IFS= read -r -d '' kv; do A["${kv%%=*}"]="${kv#*=}"; done <"$1"
while IFS= read -r -d '' kv; do B["${kv%%=*}"]="${kv#*=}"; done <"$2"
skip=" PWD OLDPWD SHLVL _ SHELL TMPDIR TMP TEMP TEMPDIR NIX_BUILD_TOP CLAUDE_ENV_FILE DEVENV_CMDLINE WTENV_ROOT WTENV_ENTRY "
same=0; diff=0
for k in $(printf '%s\n' "${!A[@]}" "${!B[@]}" | sort -u); do
  [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  case "$skip" in *" $k "*) continue ;; esac
  if [ "${A[$k]+s}" != "${B[$k]+s}" ] || [ "${A[$k]-}" != "${B[$k]-}" ]; then
    diff=$((diff+1)); echo "DIFF $k"; echo "  wtenv:  ${A[$k]-<unset>}" | cut -c1-300; echo "  native: ${B[$k]-<unset>}" | cut -c1-300
  else same=$((same+1)); fi
done
echo "identical: $same  differing: $diff"
PY
rm -rf "$tmp"
