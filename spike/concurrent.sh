#!/usr/bin/env bash
# concurrent.sh <git-dir> <base-ref> <dir> <n>
# Creates n worktrees of <base-ref> under <dir>, then runs `wtenv export` in
# all of them at once. Prints, per worktree, its exit code, wall time and
# whether it evaluated, then the totals: evaluations, and "database is
# locked" anywhere in the output.
set -uo pipefail
git_dir=$1 base=$2 dir=$3 n=$4
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$dir"
for i in $(seq -w 1 "$n"); do
  git -C "$git_dir" worktree add -q "$dir/c$i" -b "spike-tmp/c$i" "$base"
done
t0=$(python3 -c 'import time;print(time.time())')
for i in $(seq -w 1 "$n"); do
  ( cd "$dir/c$i" && s=$(python3 -c 'import time;print(time.time())')
    "$here/bin/wtenv" export >"$dir/c$i.out" 2>"$dir/c$i.err"; rc=$?
    e=$(python3 -c 'import time;print(time.time())')
    python3 -c "print('c$i rc=$rc %.1f s' % ($e-$s))" >"$dir/c$i.time" ) &
done
wait
t1=$(python3 -c 'import time;print(time.time())')
cat "$dir"/c*.time
echo "evaluations: $(cat "$dir"/c*.err | grep -c 'miss: evaluating')"
echo "database is locked: $(cat "$dir"/c*.err "$dir"/c*.out | grep -ci 'database is locked')"
echo "exports carrying WTENV_ROOT: $(grep -l '^export WTENV_ROOT=' "$dir"/c*.out | wc -l)"
python3 -c "print('all done in %.1f s' % ($t1-$t0))"
