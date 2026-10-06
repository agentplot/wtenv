# Spike: one environment per machine, every worktree in a second

## The problem

A project whose environment comes from devenv pays a full Nix evaluation for
every new git worktree, even when every package is already in the store.
Measured on WilldanGroup/switchboard-kit (devenv 2.4.0, aarch64-darwin,
6 October 2026):

| What | Time |
|---|---|
| First `devenv shell -- true` in a fresh worktree | 150–202 s |
| of which: evaluating `nixpkgs-unstable` | 0–68 s |
| of which: evaluating `devenv-nixpkgs`, a second nixpkgs | 69–200 s |
| Packages built or downloaded | none |
| `devenv shell -- true` again, warm | 2–3 s |
| A hook that loads the warm environment into a Claude Code session | 0.8–1.4 s |

Two things make the cost repeat per worktree:

1. devenv's evaluation cache is per project root. Its key includes the root,
   dotfile and runtime paths, the hostname and the user name, and its input
   records are absolute paths, so a copied cache misses
   ([cachix/devenv#3204](https://github.com/cachix/devenv/issues/3204);
   `devenv-eval-cache/DESIGN.md`, `devenv-core/src/nix_args.rs`).
2. Projects write the worktree's path into the environment
   (`${config.devenv.root}` in scripts: 29 places in switchboard-kit), so each
   worktree's environment really is different.

For agents the cost lands at the worst moment: a Claude Code session waits for
its `SessionStart` hook, so a new worktree's first session stalls for about
three minutes, and a hundred agents in new worktrees evaluate a hundred times.

## What exists, and what this takes from it

| Exists | Takes it as is |
|---|---|
| Claude Code hooks with `CLAUDE_ENV_FILE` (SessionStart, CwdChanged, FileChanged, Setup): exports apply to every later Bash command ([hooks](https://code.claude.com/docs/en/hooks)) | yes: the one way an environment reaches an agent |
| `devenv print-dev-env`, hidden in 2.x (`devenv/src/cli.rs`) | yes: the devenv adapter's export on a miss |
| `follows` on inputs, to drop a duplicate nixpkgs ([devenv inputs](https://devenv.sh/inputs/)) | yes: documented per project, not part of wtenv |
| worktrunk's custom subcommands (`wt-<name>` on `PATH` runs as `wt <name>`), hooks (`post-start` runs in the background in the new worktree) and template filters (`hash_port`) ([extending](https://worktrunk.dev/extending/#custom-subcommands), [hooks](https://worktrunk.dev/hook/), [tips](https://worktrunk.dev/tips-patterns/#aliases-and-hooks)) | yes: `wt env`, warming on `post-start` |
| Snapshot keyed by setup inputs: Codex cloud, Claude Code cloud environments, Cursor cloud agents, Devin, E2B, Daytona, devcontainer prebuilds | the pattern, applied locally |
| Community hooks loading devenv or direnv into Claude Code ([#3090 comment](https://github.com/cachix/devenv/issues/3090), [eshaham gist](https://gist.github.com/eshaham/8e3b63fb077530dffc2964b648145ec9), [lyngon/devkit#5](https://github.com/lyngon/devkit/pull/5)) | the hook shape; none caches across worktrees |

What does not solve it: nix-direnv, lorri and direnv-instant cache per
directory; Nix's flake evaluation cache is turned off inside devenv, which
embeds its own Nix; Determinate Nix's lazy trees and parallel evaluation do not
apply to devenv's embedded evaluator; devenv has no option to relocate
`.devenv`. devenv's maintainers have not answered #3204, and nothing on their
tracker plans a shared cache.

## The design under test

### The cache

```
<git-common-dir>/wtenv/
  <key>/
    env.sh        the exported environment; the worktree root written as @ROOT@
    inputs        every file the evaluation read, with its hash
    meta.json     adapter, tool version, system, created, last used
    gcroot        keeps the environment's store paths from `nix gc`
  <key>.lock      held while one process builds the entry
```

The key is a hash of the adapter's key files, the tool's version and the
system. An entry is valid while every file in `inputs` still has its hash.

`wtenv export` (also `wt env export`) in a worktree:

1. Finds the root and the adapter from the files present.
2. **Hit:** prints `env.sh` with `@ROOT@` replaced by this root, then runs the
   adapter's per-worktree step, which recomputes every value derived from the
   path or branch (a port from `hash_port`, links, hooks). Nothing derived from
   the path is ever read from the cache.
3. **Miss:** takes `<key>.lock`, runs the adapter's export once, and refuses to
   store a result that contains the worktree path anywhere but the adapter's
   own root variables, naming each place. Other callers with the same key wait
   for the lock, then hit.

`wtenv exec -- <cmd>` runs a command in the environment; `wtenv warm` builds a
missing entry in the background; `wtenv gc` drops entries unused for N days.

### Adapters

An adapter states its key files, its export command, its root variables and its
per-worktree step. devenv: `devenv.nix`, `devenv.yaml`, `devenv.lock` and
imports; `devenv print-dev-env`; `DEVENV_ROOT`, `DEVENV_DOTFILE`,
`DEVENV_STATE`, `DEVENV_RUNTIME`; its `enterShell`. A Nix flake: `flake.nix`,
`flake.lock`; `nix print-dev-env`. mise: `mise.toml`, `.tool-versions`;
`mise env -s bash`. Flox: `.flox/env/manifest.lock`; `flox activate
--print-script`.

### worktrunk

```toml
# ~/.config/worktrunk/config.toml (user config, so no per-project approval)
[post-start]
env = "wt env warm"            # background: a miss is built before anyone waits on it

[aliases]
shell = "wt env exec -- $SHELL"
```

A project's own hooks run checks through `wt env exec -- <cmd>` instead of
entering the environment tool themselves.

### Claude Code plugin

- `SessionStart` (startup, resume, clear, compact): empties the session's other
  env files, then writes `wtenv export --format claude` to `CLAUDE_ENV_FILE`,
  ending with `true` so commands Claude joins with `&&` still parse.
- `CwdChanged`, and `FileChanged` on the adapter's key files: the same export.
- `PreToolUse` on Bash: refuses with "environment still loading" while the
  loaded root is not the current directory's root, because CwdChanged and
  FileChanged hooks are not awaited.

### In each project

Scripts read `$DEVENV_ROOT` (or the tool's root variable) when they run; none
writes the worktree's path in at evaluation time. The miss-time check enforces
it.

## What the spike answers

| # | Question | Passes when |
|---|---|---|
| 1 | Does a fresh worktree of switchboard-kit load from a hit fast enough? | under 1 s for `wtenv export`; a Claude Code session ready in under 2 s |
| 2 | Is a cached environment the same as a fresh one? | `wtenv export` in a worktree and that worktree's own `devenv print-dev-env` differ only in excluded variables |
| 3 | Do concurrent misses evaluate once? | 20 worktrees created at once: one evaluation, no "database is locked" ([#3133](https://github.com/cachix/devenv/issues/3133), PR [#3156](https://github.com/cachix/devenv/pull/3156)) |
| 4 | Does the path check catch what it must? | it names each of switchboard-kit's 29 interpolations, and passes after they read `$DEVENV_ROOT` |
| 5 | What do devenv's own commands cost in a fresh worktree? | `devenv up` and `devenv tasks run` measured; whether `wtenv exec` can stand in for them, or they keep their cold start, written down |
| 6 | How much does one nixpkgs save? | switchboard-kit's cold evaluation measured with `follows` |
| 7 | What does a miss look like to an agent? | the session-start behaviour on a miss chosen (wait with a timeout, or start without and swap in) with measurements |
| 8 | Do the plugin's guards close the gaps found earlier? | a `cd` straight after loading never runs in the old environment; a resume never reads a stale env file |
| 9 | Is it loosely coupled? | a second adapter (mise or a flake) passes questions 1 and 2 on a small repository |

## How it runs

1. Baseline switchboard-kit in a scratch worktree: cold and warm times, the
   interpolation list.
2. `wtenv` as a script with the devenv adapter, the cache, the lock and the path
   check. The language of the real tool is chosen from what the spike shows.
3. On a switchboard-kit branch: `follows`, and the scripts moved to
   `$DEVENV_ROOT`. The branch is evidence for the spike; it merges there only
   through that repository's own process.
4. `wt-env`, the worktrunk hooks and aliases.
5. The Claude Code plugin.
6. The second adapter.
7. `docs/spike-results.md` with every measurement, and a comment on
   [cachix/devenv#3204](https://github.com/cachix/devenv/issues/3204) with the
   numbers and the approach.

Out of scope: CI images and containers (a later adapter), and anything about
how a platform builds or gates a repository.

## Sources

- devenv: [#3204 worktree workflows](https://github.com/cachix/devenv/issues/3204),
  [#3090](https://github.com/cachix/devenv/issues/3090),
  [#3133](https://github.com/cachix/devenv/issues/3133),
  [#3154](https://github.com/cachix/devenv/issues/3154),
  [#3021 read-only root variables](https://github.com/cachix/devenv/issues/3021),
  [environment variables](https://devenv.sh/reference/environment-variables/),
  [Claude Code integration](https://devenv.sh/integrations/claude-code/),
  [devenv 2.2](https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/),
  [devenv-nixpkgs](https://github.com/cachix/devenv-nixpkgs)
- Claude Code: [hooks](https://code.claude.com/docs/en/hooks),
  [cloud environments](https://code.claude.com/docs/en/cloud-environments),
  declined [#48873](https://github.com/anthropics/claude-code/issues/48873) and
  [#42229](https://github.com/anthropics/claude-code/issues/42229)
- worktrunk: [extending](https://worktrunk.dev/extending/#custom-subcommands),
  [hooks](https://worktrunk.dev/hook/),
  [tips and patterns](https://worktrunk.dev/tips-patterns/#aliases-and-hooks)
- Others: [nix-direnv](https://github.com/nix-community/nix-direnv),
  [direnv-instant](https://github.com/Mic92/direnv-instant),
  [mise directories](https://mise.jdx.dev/directories.html),
  [mise settings](https://mise.jdx.dev/configuration/settings.html),
  [flox activate](https://flox.dev/docs/man/flox-activate),
  [Codex cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environment),
  [Cursor cloud agent builds](https://cursor.com/docs/cloud-agent/builds),
  [E2B templates](https://e2b.dev/docs/template/how-it-works),
  [Daytona declarative builder](https://www.daytona.io/docs/en/declarative-builder/)
