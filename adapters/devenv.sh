# devenv adapter.
#
#   key files      devenv.nix, devenv.yaml, devenv.lock, devenv.local.{nix,yaml}
#   export         `devenv shell -- true` (one evaluation, the shell and its
#                  tasks), then `devenv print-dev-env`, which that evaluation
#                  answers from devenv's own cache
#   root vars      DEVENV_ROOT, DEVENV_DOTFILE (and what lies under it),
#                  DEVENV_RUNTIME (a hash of DEVENV_DOTFILE)
#   per worktree   the shellHook (enterShell) and the tasks devenv runs
#                  before it (files, git hooks), once per worktree and entry
# shellcheck shell=bash

adapter_devenv_detect() { [ -f "$1/devenv.nix" ] || [ -f "$1/devenv.yaml" ]; }

adapter_devenv_key_files() {
  local f
  for f in devenv.nix devenv.yaml devenv.lock devenv.local.nix devenv.local.yaml; do echo "$f"; done
}

adapter_devenv_tool_version() {
  if [ -z "${_WTENV_DEVENV_VERSION:-}" ]; then
    _WTENV_DEVENV_VERSION="$(devenv version 2>/dev/null | head -1)"
  fi
  echo "$_WTENV_DEVENV_VERSION"
}

# The runtime directory devenv derives from the dotfile path
# (devenv-core/src/paths.rs, resolve_runtime_dir).
_devenv_runtime() {
  local h
  h="$(printf '%s' "$1/.devenv" | sha256_stdin)"
  echo "${XDG_RUNTIME_DIR:-/tmp}/devenv-${h:0:7}"
}

adapter_devenv_export() {
  local out=$1
  devenv shell -- true
  devenv print-dev-env >"$out/raw.sh"
  # The tasks devenv ran for that shell, as devenv's evaluation cache recorded
  # them.
  sqlite3 .devenv/nix-eval-cache.db \
    "select json_output from cached_eval where attr_name='devenv.config.task.config:build' order by updated_at desc limit 1" |
    jq -r . >"$out/tasks-path"
  # Every file the evaluation read, as devenv recorded it, less its own
  # generated files and runtime directory.
  local f rel
  : >"$out/inputs"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$PWD/.devenv/"* | /tmp/devenv-* | "${XDG_RUNTIME_DIR:-/nonexistent}"/devenv-*) continue ;; esac
    case "$f" in "$PWD/"*) rel=${f#"$PWD/"} ;; *) rel=$f ;; esac
    hash_files "$f" | sed "s|  $f\$|  $rel|" >>"$out/inputs"
  done <.devenv/input-paths.txt
  adapter_devenv_key_files | while IFS= read -r f; do
    grep -q "  $f\$" "$out/inputs" || hash_files "$f" >>"$out/inputs"
  done
  LC_ALL=C sort -k2 -o "$out/inputs" "$out/inputs"
}

# Writes env.sh and tasks/ (templates), and refuses when the worktree's path
# remains anywhere outside devenv's own root variables.
adapter_devenv_templatize() {
  local out=$1 root=$PWD runtime
  runtime="$(_devenv_runtime "$root")"
  ROOT="$root" RUNTIME="$runtime" perl -e '
    use strict; my $root = $ENV{ROOT}; my $rt = $ENV{RUNTIME};
    my $r = quotemeta($root); my $b = q{(?=[/\x27":) \n;]|$)};
    local $/; open(my $fh, "<", shift) or die; my $s = <$fh>; close $fh;
    $s =~ s/\Q$rt\E(?=[\/\x27" \n]|$)/\@RUNTIME\@/g;
    $s =~ s/$r\/\.devenv$b/\@ROOT\@\/.devenv/g;
    $s =~ s/^DEVENV_ROOT=\x27$r\x27$/DEVENV_ROOT=\x27\@ROOT\@\x27/m;
    $s =~ s/\*":$r:"\*/*":\@ROOT\@:"*/g;
    open(my $o, ">", shift) or die; print $o $s; close $o;
  ' "$out/raw.sh" "$out/env.sh"
  local bad=0
  # 1. The template: every remaining occurrence, named by variable or by its
  #    line in the shellHook.
  ROOT="$root" perl -ne '
    BEGIN { $r = quotemeta($ENV{ROOT}); $b = q{(?=[/\x27":) \n;]|$)}; }
    if (/^shellHook=/) { $in = 1; $n = 0; }
    if ($in) { $n++; }
    if (/$r$b/) {
      chomp; my $t = $_; $t =~ s/^\s+//;
      if ($in) { print "  shellHook line $n: $t\n" }
      elsif (/^(?:declare -x |export )?([A-Za-z_][A-Za-z0-9_]*)=/) { print "  variable $1: $t\n" }
      else { print "  line $.: $t\n" }
    }
    if ($in && /^export shellHook/) { $in = 0; }
  ' "$out/env.sh" >"$out/found-template"
  # 2. The store: locally built paths in the closure of what the loaded
  #    environment exports (nothing substituted from a binary cache can hold
  #    this machine's paths). The tasks file is left to step 3.
  local bash; bash="$(grep -m1 -oE "^CONFIG_SHELL='[^']+'" "$out/raw.sh" | cut -d"'" -f2)"
  env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin "$bash" -c 'source "$1" >/dev/null 2>&1; env -0' _ "$out/raw.sh" |
    tr '\0' '\n' | grep -v '^DEVENV_TASK_FILE=' |
    grep -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?-]+' | sort -u |
    while IFS= read -r p; do [ -e "$p" ] && echo "$p"; done >"$out/store-paths"
  nix-store -qR $(cat "$out/store-paths") 2>/dev/null | sort -u >"$out/closure"
  nix path-info --json $(cat "$out/closure") 2>/dev/null |
    jq -r 'if type=="array" then .[] | select(.ultimate==true) | .path else to_entries[] | select(.value.ultimate==true) | .key end' >"$out/local-paths"
  : >"$out/found-store"
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -rIlF -- "$root" "$p" 2>/dev/null | while IFS= read -r f; do
      ROOT="$root" F="$f" perl -ne 'BEGIN{$r=quotemeta($ENV{ROOT}); $b=q{(?=[/\x27":) \n;]|$)};} if (/$r$b/) { chomp; s/^\s+//; print "  $ENV{F}: $_\n" }' "$f"
    done >>"$out/found-store"
  done <"$out/local-paths"
  # 3. devenv's tasks: every command templated by the same substitution, and
  #    the task file pointed at the templates. devenv's own modules write the
  #    root into them, so they are reported, not refused.
  mkdir -p "$out/tasks"
  local tasks name cmd; tasks="$(cat "$out/tasks-path")"
  : >"$out/found-tasks"
  if [ -f "$tasks" ]; then
    jq -r '.[] | select(.command != null) | "\(.name)|\(.command)"' "$tasks" |
      while IFS='|' read -r name cmd; do
        ROOT="$root" RUNTIME="$runtime" perl -pe 'BEGIN{$r=quotemeta($ENV{ROOT});} s/\Q$ENV{RUNTIME}\E/\@RUNTIME\@/g; s/$r(?=[\/\x27":) \n;]|$)/\@ROOT\@/g' "$cmd" >"$out/tasks/$name.sh"
        grep -nF -- "$root" "$cmd" | sed "s|^|  task $name line |" || true
      done >>"$out/found-tasks"
    jq 'map(if .command != null then .command = "@TASKS@/" + .name + ".sh" else . end)' "$tasks" >"$out/tasks/tasks.json"
    # The ones devenv runs before the shell, in its order.
    jq -r '[.[] | select((.before // []) | index("devenv:enterShell")) | select(.command != null)] | .[] | "\(.name)|\(.command)|\((.after // []) | join(","))|\((.before // []) | join(","))"' "$tasks" >"$out/tasks/list"
    _devenv_task_order "$out/tasks/list" >"$out/tasks/order"
  fi
  if [ -s "$out/found-template" ] || [ -s "$out/found-store" ]; then bad=1; fi
  if [ $bad -eq 1 ]; then
    echo "the worktree path $root is written into the environment:"
    cat "$out/found-template" "$out/found-store"
    echo "$(($(wc -l <"$out/found-template") + $(wc -l <"$out/found-store"))) places"
  fi
  if [ -s "$out/found-tasks" ]; then
    echo "in devenv's tasks, templated ($(wc -l <"$out/found-tasks") lines):"
    cat "$out/found-tasks"
  fi
  return $bad
}

# The tasks in an order that keeps every after/before edge among them.
_devenv_task_order() {
  local list=$1 name cmd a b x ok progress
  local -a names=() deps=()
  local -A need=() placed=()
  while IFS='|' read -r name cmd a b; do names+=("$name"); need[$name]="$a"; done <"$list"
  # "X before Y" is "Y after X".
  while IFS='|' read -r name cmd a b; do
    IFS=, read -ra deps <<<"$b"
    for x in "${deps[@]}"; do
      [ -n "${need[$x]+set}" ] && need[$x]="${need[$x]},$name"
    done
  done <"$list"
  progress=1
  while [ $progress -eq 1 ]; do
    progress=0
    for name in "${names[@]}"; do
      [ -n "${placed[$name]:-}" ] && continue
      ok=1
      IFS=, read -ra deps <<<"${need[$name]}"
      for x in "${deps[@]}"; do
        [ -n "$x" ] && [ -n "${need[$x]+set}" ] && [ -z "${placed[$x]:-}" ] && ok=0
      done
      if [ $ok -eq 1 ]; then placed[$name]=1; echo "$name"; progress=1; fi
    done
  done
}

adapter_devenv_gcroot() {
  local entry=$1
  mkdir -p "$entry/gcroots"
  # shellcheck disable=SC2046
  nix-store --add-root "$entry/gcroots/r" --indirect --realise \
    $(cat "$entry/store-paths") $(cat "$entry/tasks-path" 2>/dev/null) >/dev/null
}

# This worktree's copy of the template.
adapter_devenv_render() {
  local entry=$1 work=$2 s
  RUNTIME_DIR="$(_devenv_runtime "$ROOT")"
  s="$(<"$entry/env.sh")"; s=${s//@RUNTIME@/$RUNTIME_DIR}; s=${s//@ROOT@/$ROOT}
  printf '%s\n' "$s" >"$work/env.sh"
}

# Load the environment as `devenv shell` would: the tasks before the shell
# (written out and run once per worktree and entry), then the shellHook, then
# the dump.
adapter_devenv_apply() {
  local entry=$1 work=$2 bash s f name
  bash="$(grep -m1 -oE "^CONFIG_SHELL='[^']+'" "$work/env.sh" | cut -d"'" -f2)"
  [ -x "$bash" ] || bash="$(command -v bash)"
  local dir="$ROOT/.devenv/wtenv" want run_tasks=0
  want="$(basename "$(dirname "$entry")")/$(basename "$entry")"
  if [ -f "$entry/tasks/tasks.json" ] && [ "$(cat "$dir/entry" 2>/dev/null)" != "$want" ]; then
    run_tasks=1
    rm -rf "$dir/tasks"; mkdir -p "$dir/tasks"
    for f in "$entry"/tasks/*.sh; do
      s="$(<"$f")"; s=${s//@RUNTIME@/$RUNTIME_DIR}; s=${s//@ROOT@/$ROOT}
      printf '%s\n' "$s" >"$dir/tasks/$(basename "$f")"; chmod +x "$dir/tasks/$(basename "$f")"
    done
    s="$(<"$entry/tasks/tasks.json")"; printf '%s\n' "${s//@TASKS@/$dir/tasks}" >"$dir/tasks/tasks.json"
    cp "$entry/tasks/order" "$dir/tasks/order"
  fi
  "$bash" -c '
    dir=$1 run_tasks=$2 want=$3 work=$4
    cd "$5" || exit 1
    if [ "$run_tasks" = 1 ]; then
      (
        source "$work/env.sh" >/dev/null 2>&1
        while IFS= read -r t; do "$BASH" "$dir/tasks/$t.sh" || exit 1; done <"$dir/tasks/order"
      ) >&2 || exit 1
      echo "$want" >"$dir/entry"
    fi
    source "$work/env.sh" >&2
    [ -f "$dir/tasks/tasks.json" ] && export DEVENV_TASK_FILE="$dir/tasks/tasks.json"
    env -0 >"$work/after"
  ' _ "$dir" "$run_tasks" "$want" "$work" "$ROOT"
}
