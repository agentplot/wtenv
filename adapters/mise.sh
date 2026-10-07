# mise adapter.
#
#   key files      mise.toml, .mise.toml, mise.local.toml, .tool-versions
#   export         `mise env -s bash`, run from a clean environment and diffed
#   root vars      none: mise renders {{config_root}} into values, and those
#                  are plain text, so the root is written back as @ROOT@
#   per worktree   nothing
# shellcheck shell=bash

adapter_mise_detect() { [ -f "$1/mise.toml" ] || [ -f "$1/.mise.toml" ] || [ -f "$1/.tool-versions" ]; }

adapter_mise_key_files() {
  local f
  for f in mise.toml .mise.toml mise.local.toml .tool-versions; do echo "$f"; done
}

adapter_mise_tool_version() { mise --version 2>/dev/null | cut -d' ' -f1; }

adapter_mise_export() {
  local out=$1 base=(HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin)
  [ -n "${MISE_TRUSTED_CONFIG_PATHS:-}" ] && base+=(MISE_TRUSTED_CONFIG_PATHS="$MISE_TRUSTED_CONFIG_PATHS")
  local mise; mise="$(command -v mise)"
  env -i "${base[@]}" bash -c 'env -0' >"$out/before"
  env -i "${base[@]}" bash -c 'eval "$("$1" env -s bash)" && env -0' _ "$mise" >"$out/after"
  env_diff "$out/before" "$out/after" >"$out/raw.sh"
  local f
  : >"$out/inputs"
  for f in $(adapter_mise_key_files) "$HOME/.config/mise/config.toml"; do hash_files "$f" >>"$out/inputs"; done
}

adapter_mise_templatize() {
  local out=$1
  ROOT="$PWD" perl -pe 'BEGIN{$r=quotemeta($ENV{ROOT});} s/$r(?=[\/\x27":) \n;]|$)/\@ROOT\@/g' "$out/raw.sh" >"$out/env.sh"
}

adapter_mise_render() {
  local entry=$1 work=$2 s
  s="$(<"$entry/env.sh")"; s=${s//@ROOT@/$ROOT}
  printf '%s\n' "$s" >"$work/env.sh"
}

adapter_mise_apply() {
  local work=$2
  bash -c 'source "$1/env.sh" && env -0 >"$1/after"' _ "$work"
}
