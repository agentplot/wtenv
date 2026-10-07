# Spike results

The spike in [`spike.md`](spike.md), run on 6 October 2026 against
WilldanGroup/switchboard-kit (devenv 2.4.0, Nix 2.32.0, aarch64-darwin,
Claude Code 2.1.286) and a small mise repository. The machine was shared
with other agents throughout: load averages ran from 8 to 26, and every
timing here is wall-clock under that load. Every number names the command
that produced it; the scripts are in [`../spike/`](../spike/).

The switchboard-kit evidence is branch `spike/wtenv-paths` (local only),
commit `214a1307`: every `${config.devenv.root}` read at run time, and
treefmt finding its tree by `devenv.nix`.

## What the spike answers

| # | Question | Result | Numbers |
|---|---|---|---|
| 1 | A fresh worktree loads from a hit fast enough | pass | `wtenv export` 0.53–0.54 s; the first in a worktree 1.13 s, because it runs devenv's shell tasks once. Session: process start to SessionStart done 1.23–1.27 s, the hook 0.71–0.76 s |
| 2 | A cached environment is the same as a fresh one | pass | devenv: 148 variables identical, 2 differ, both per-worktree by devenv's design (below). mise: 80 identical, 0 differ |
| 3 | Concurrent misses evaluate once | pass | 20 worktrees at once: 1 evaluation (33.9 s), 0 "database is locked", 20 of 20 exports carry their own `DEVENV_ROOT`, all done in 39.6 s |
| 4 | The path check catches what it must | pass | before: all 29 interpolations named (27 refused in the shell, 2 named in tasks), plus devenv's treefmt wrapper; after the fix: passes |
| 5 | What devenv's own commands cost in a fresh worktree | measured | `devenv tasks run` 30.4 s cold, 1.86 s warm; `devenv up` 32.4 s cold. `wtenv exec` cannot stand in for either; it does stand in for `devenv shell`'s own tasks |
| 6 | How much one nixpkgs saves | measured, not taken | 1–3.5 s of a 21–24 s cold evaluation (5–15 %); 18 s in the first pair. No input can follow another without moving a pinned tool |
| 7 | What a miss looks like to an agent | chosen: start without, swap in | wait: SessionStart 29.4 s, session 43.3 s, 0 refusals. Swap: SessionStart 0.59 s, 2 Bash attempts held then refused, the 3rd ran in the environment, session 30.2 s |
| 8 | The plugin's guards close the gaps | pass | a `cd` with a 5 s CwdChanged hook: unguarded, the next command ran in the old environment; guarded, in the new one. Resume: the stale file is emptied and the resumed session loads its own root |
| 9 | Loosely coupled | pass | mise adapter: miss 0.44 s, hit 0.17 s, 80 identical / 0 differing |

## Baseline: switchboard-kit as it is

In a fresh worktree of `main` at `2d9f07b3`:

| What | Time | Command |
|---|---|---|
| First `devenv shell -- true` | 106.5 s | `/usr/bin/time -p devenv shell -- true` |
| The same, again | 5.6 s | same |
| `devenv print-dev-env`, warm | 1.43 s | `/usr/bin/time -p devenv print-dev-env` |
| `devenv shell -- true` after editing `devenv.nix` in that worktree | 189.1 s | same |
| `devenv eval task.config` in the warm worktree (an attribute the shell had not cached under that name) | 65.8 s, then 1.7 s | `time devenv eval task.config` |
| Later fresh worktrees of the fixed branch, same command | 24.3–45.2 s | traced, question 6 |

Cold evaluation varied from 21 s to 189 s on the same machine on the same
day with the same store; the spike's 150–202 s and this morning's 106 s were
not reproduced later in the day. The evaluation phase itself (devenv's
"Evaluating shell" span) was 17.8–34.3 s in every traced run. The spread is
the machine, not the configuration: no package was downloaded or compiled in
any run but one (noted under question 6).

`grep -n 'config.devenv.root' devenv.nix` finds 29 interpolations: 22
scripts, 2 tasks (`devenv:git-hooks:install`, `ministack:ready`) and 5
lines of `enterShell`.

## 1. Load time on a hit

`wtenv export` in fresh worktrees of `spike/wtenv-paths`, with the entry
already built (`/usr/bin/time -p wtenv export`):

| Run | Time |
|---|---|
| 1 (runs devenv's shell tasks once for this worktree) | 1.13 s |
| 2–5 | 0.53, 0.53, 0.53, 0.54 s |

`wt env warm`, the worktrunk `post-start` hook, runs the export once in the
background whenever a worktree is created, hit or miss, so the first export
anyone waits on is a run-2 export.

Where the 0.53 s goes: the key and the entry lookup 0.21–0.27 s (`wtenv
key`), sourcing the rendered script and its shellHook 0.14 s, of which
`wt step eval` (switchboard-kit's `MINISTACK_PORT`) is 0.11 s. Most of the
first part is the spike being bash: a re-exec into bash 5, `devenv
version`, and `shasum` (perl) per input. A compiled tool keeps only the
shellHook's own cost.

A Claude Code session on a hit (`spike/claude-run.sh`, three runs, timings
from `--debug-file`):

| Run | Process start to SessionStart done | The wtenv hook |
|---|---|---|
| 1 | 1.23 s | 0.72 s |
| 2 | 1.27 s | 0.76 s |
| 3 | 1.24 s | 0.71 s |

The loader alone (`load.sh session-start` with a fake hook input) takes
0.58–0.63 s. Every session's `command -v moon` answered
`/nix/store/…-moon-2.5.5/bin/moon`.

## 2. Same environment

`spike/compare-env.sh devenv` loads both from the same starting
environment in bash 5 — `wtenv export`, and the worktree's own `devenv
print-dev-env` — and compares every variable but PWD, OLDPWD, SHLVL, _,
SHELL, TMPDIR, TMP, TEMP, TEMPDIR, NIX_BUILD_TOP, CLAUDE_ENV_FILE,
DEVENV_CMDLINE and wtenv's own two.

Result in a fresh worktree: 148 identical, 2 differing.

- `DEVENV_TASK_FILE`: devenv's is a store path built for this worktree;
  wtenv's is `.devenv/wtenv/tasks/tasks.json`, the cached task file with
  this worktree's root put back. Every task's metadata is identical
  (`jq` over name, before, after, status, cwd, env, input), and every
  command is identical line for line, blank lines aside, except one store
  path name: devenv
  names the copy of `.claude/settings.json` after its absolute target path,
  and the two copies are byte-identical (`cmp`).
- `NIX_CFLAGS_COMPILE`: only `-frandom-seed=`, which stdenv derives from
  the shell derivation's output path. devenv puts `DEVENV_ROOT` in that
  derivation, so the seed differs per worktree however the project is
  written.

Both are values devenv itself makes per worktree. wtenv recomputes the
first; the second only seeds a compiler's randomness.

mise (`spike/compare-env.sh mise`): 80 identical, 0 differing.

## 3. Concurrent misses

`spike/concurrent.sh <git-dir> spike/wtenv-paths <dir> 20` with no entry:
20 new worktrees, then `wtenv export` in all of them at once.

- Evaluations: 1 (worktree c07; the build, cold `devenv shell` included,
  took 33.9 s).
- "database is locked": 0.
- Each export's `DEVENV_ROOT` is its own worktree: 20 of 20.
- Each export finished in 38.7–39.5 s; all done in 39.6 s.

The other 19 waited on `<key>.lock` (a directory made atomically, holding
the builder's pid; a lock whose holder is dead is taken over), then hit.

## 4. The path check

`wtenv check` in a fresh worktree of `main`, then in `spike/wtenv-paths`.
The check searches the rendered template (variables and shellHook) and
every locally built store path (`nix path-info --json`, `ultimate`) in the
closure of what the loaded environment exports; nothing substituted from a
binary cache can hold this machine's paths.

Before, 28 refused places:

- 5 shellHook lines, the 5 `enterShell` interpolations (`git -C <root>`,
  `cd <root>`, `cat <root>/infra/ministack/region`, `git -C <root>
  rev-parse --git-common-dir`, `_moon_cache=<root>/.moon/cache`);
- 22 script bodies (`cd <root>`, `exec sh <root>/.moon/scripts/…`,
  `exec sh <root>/.config/hooks/main-red-check.sh`);
- devenv's treefmt wrapper, `--tree-root <root>`, which devenv's treefmt
  module writes unless `treefmt.config.projectRootFile` is set.

and in devenv's task file, named: the two project tasks
(`devenv:git-hooks:install`, `ministack:ready`) and 23 lines of devenv's
own `devenv:files` and `devenv:files:cleanup`.

After (`214a1307`): passes. What remains is devenv's 23 task lines, which
the adapter templates.

## 5. devenv's own commands

In fresh worktrees loaded with `wtenv exec -- true`:

| Command | Cold | Warm |
|---|---|---|
| `wtenv exec -- devenv tasks run wtenv-spike-none` | 30.4 s | 1.86 s |
| `wtenv exec -- devenv up --mode single wtenv-spike-none` | 32.4 s | — |

A missing task and a missing process make devenv evaluate and stop before
starting anything; no ministack container ran before or after
(`docker ps`).

`wtenv exec` cannot stand in for them: both evaluate inside devenv's own
binary, through its per-root cache, and a rendered `DEVENV_TASK_FILE` did
not spare the evaluation. They keep their cold start, once per worktree.
What wtenv does stand in for is the work `devenv shell` does around the
environment: the shellHook and the tasks that run before it (`devenv:files`,
`devenv:files:cleanup`, `devenv:git-hooks:install`). A commit in a worktree
that never ran `devenv shell`, under `wtenv exec`, ran switchboard-kit's
commit hook (prek, treefmt) and passed.

## 6. One nixpkgs

What needs `nixpkgs-unstable`: proto 0.62.3 and moon 2.5.5 (commits
`70ea84ac`, `06be7b0c`; CI pins `moon-version: "2.5.5"`, ADR 0038). The
locked devenv-nixpkgs carries proto 0.61.2 and moon 2.5.3 (`nix eval` of
`legacyPackages.aarch64-darwin.{moon,proto}.version` at each locked rev).
Dropping devenv-nixpkgs for nixpkgs-unstable instead moves biome 2.5.13 to
2.5.14 (`package.json` pins 2.5.13 and `scripts/ci/biome.sh` refuses
another), playwright 1.61.1 to 1.63.0, gh, nodejs 22, prek and secretspec.

Cold `devenv --trace-to json:file:<f> shell -- true`, each in a fresh
worktree, in rounds (round 1 alone; rounds 2 and 3 back to back, in
opposite orders). Wall time, then devenv's "Evaluating shell" span:

| Variant | Round 1 | Round 2 | Round 3 |
|---|---|---|---|
| b0: two nixpkgs, as is | 45.2 s (34.3) | 24.4 s (20.8) | 24.3 s (21.3) |
| f1: `nixpkgs-unstable: follows: nixpkgs`, `devenv.nix` unchanged | 110.3 s¹ | 26.4 s (23.4) | 25.0 s (21.9) |
| f1b: f1, and `pkgs-unstable = pkgs` | 27.1 s (20.8) | 23.9 s (20.8) | 22.5 s (19.4) |
| f2: `nixpkgs` is nixpkgs-unstable at `c9fe7d12`, unstable follows it | 313.6 s² | 20.8 s (17.8) | 21.4 s (18.2) |

¹ untraced, under load. ² downloaded and built the packages whose versions
moved.

`follows` alone saves nothing while `devenv.nix` imports the input a second
time; one nixpkgs instance saves 1–3.5 s once the machine is warm. Not worth
moving a pinned tool for, so `spike/wtenv-paths` carries no `follows`
change. The cache is what removes the cost; one nixpkgs only shortens the
one evaluation a key still needs.

## 7. A miss, seen by an agent

A true miss (an empty `WTENV_CACHE`, a fresh worktree, devenv's own cache
cold), prompt: run `command -v moon && echo ROOT=$WTENV_ROOT`, retrying if
refused.

| Strategy | SessionStart hook | Bash | Session |
|---|---|---|---|
| Wait (`WTENV_LOAD_WAIT=180`) | 29.4 s | ran first time | 43.3 s |
| Start without, swap in | 0.59 s | 2 attempts held 9.5–9.8 s and refused, the 3rd ran in the environment | 30.2 s |

Chosen: start without and swap in. The session starts at once and can read
and plan; only Bash waits, and the detached build writes the session's env
file itself when done.

## 8. The guards

`cd` straight after loading. Two worktrees with the same key, a session in
the first told to run `cd <second>` and then, as a separate call, `echo
ROOT=$WTENV_ROOT DEV=$DEVENV_ROOT PWD=$PWD`. The CwdChanged hook was slowed
by 5 s to open the window:

| Settings | Second command printed |
|---|---|
| no guard | `ROOT=q1 DEV=q1 PWD=q2`: the old environment |
| guard | `ROOT=q2 DEV=q2 PWD=q2` |

Without the delay both printed `q2`: the model's turn outlasts a 0.6 s hit.

Resume. Session one in q1 ran `cd q2`, which wrote the CwdChanged env file;
session two resumed it from q1 and printed its environment:

| Settings | Resumed session printed | Env files after |
|---|---|---|
| SessionStart not run on resume | `ROOT=q2 DEV=q2 PWD=q1`: the stale file | cwdchanged 35 KB |
| the plugin | `ROOT=q1 DEV=q1 PWD=q1` | cwdchanged emptied, sessionstart 35 KB |

The first control also showed a guard defect: a wait counted in poll
iterations ran past the hook's 30 s timeout, and a PreToolUse hook that
times out is cancelled and lets the command run. The guard now waits by the
clock, 10 s, and loads a mismatch that outlives 2 s with no build pending
itself: rerun without resume handling, the command ran in `q1`'s environment
after a 2.7 s guard.

## 9. A second adapter

mise, on a two-tool repository (`node`, `bun`, an `[env]` value and a
`{{config_root}}/bin` path), `MISE_TRUSTED_CONFIG_PATHS` set to its parent:

| What | Time |
|---|---|
| Miss | 0.44 s |
| Hit in a new worktree | 0.17 s ×5 |
| `mise env -s bash` itself | 0.17–0.53 s |

Comparison: 80 identical, 0 differing. worktrunk on the same repository,
with wtenv's `bin/` on `PATH` and the user config in
[`../worktrunk/config.toml`](../worktrunk/config.toml): `wt env key` named
the entry, `wt switch --create` ran `post-start: env (user)` without an
approval prompt, and `wt env exec -- sh -c 'echo $GREETING; command -v
node'` answered from mise's install.

## The design as it stands

### The cache

```
<git-common-dir>/wtenv/
  <key>/
    <variant>/
      env.sh        the adapter's script; the root written as @ROOT@ and
                    each derived value as its own placeholder
      tasks/        the adapter's other templates (devenv: every task)
      inputs        every file the evaluation read, with its hash
      meta.json     adapter, tool version, system, built from, build time
      gcroots/      one indirect root per store path the environment uses
      last-used
  <key>.lock/       held while one process builds the key
```

The key hashes the adapter's own code, its key files, the tool's version
and the system. A key holds one variant per content of the inputs the
evaluation read, so two worktrees whose inputs differ (a changed
`biome.json`) each keep theirs; a variant is valid while every input has
its hash.

`wtenv export`:

1. Finds the root and the adapter.
2. **Hit:** renders the template with this worktree's root and derived
   values, runs the adapter's per-worktree step in the adapter's shell, and
   prints the difference from the caller's environment. A value that is the
   caller's with something put before or after it (PATH) is written
   relative to it.
3. **Miss:** takes the lock, runs the adapter's export once, and checks it.
   An environment that carries the worktree's path anywhere the adapter
   does not own is not stored: this worktree is served from its own
   evaluation, and the check names every place. Callers waiting on the lock
   then hit.
4. `--no-build`: on a miss, starts the build detached and waits at most
   `--timeout` seconds; exit 2 means still building.

`wtenv exec -- <cmd>`, `wtenv warm [--write FILE]` (a detached export, hit
or miss; with `--write`, the result goes to FILE if FILE still waits for
this root), `wtenv gc --days N`, `wtenv check`, `wtenv key`.

### The devenv adapter

- Key files: `devenv.nix`, `devenv.yaml`, `devenv.lock`,
  `devenv.local.nix`, `devenv.local.yaml`. Inputs: devenv's own
  `.devenv/input-paths.txt`, less `.devenv/` and the runtime directory.
- Export: `devenv shell -- true` (one evaluation for the shell and its
  tasks), then `devenv print-dev-env` (answered from that evaluation's
  cache), then the task file's store path from devenv's evaluation cache
  (`cached_eval`, `devenv.config.task.config:build`). Reading devenv's
  sqlite is the spike's one coupling to its internals; a stable command for
  the task file would remove it.
- Owned places: `DEVENV_ROOT`, everything under `DEVENV_DOTFILE`,
  `DEVENV_RUNTIME` (`${XDG_RUNTIME_DIR:-/tmp}/devenv-` and the first 7 hex
  of sha256 of the dotfile path, recomputed per worktree), devenv's own
  shellHook lines, and devenv's task file, whose commands its files module
  writes the root into.
- Per worktree: the shellHook, every time; devenv's tasks that run before
  the shell, once per worktree and variant, from
  `.devenv/wtenv/tasks/`, with `DEVENV_TASK_FILE` pointing there.
- The check's scope: the template, and the closure of what the loaded
  environment exports, less the task file.

### worktrunk

`wt-env` on `PATH` makes `wt env`. The user config's `post-start` runs `wt
env warm`, which builds a miss, or runs a hit's per-worktree step, in the
background; `[aliases] shell = "wt env exec -- $SHELL"`.

### The Claude Code plugin

- `SessionStart` (startup, resume, clear, compact), `CwdChanged` and
  `FileChanged` (no matcher; SessionStart and CwdChanged return the root's
  key files as `watchPaths`) run the loader: `wtenv export --format claude
  --no-build`. A hit is written to the event's env file, atomically, and
  then every other env file of the session is emptied, so whichever event
  loaded last owns the environment and a resume never sources another
  process's file. A miss writes `export WTENV_PENDING='<root>'`, empties the
  others, and starts `wtenv warm --write <that file>`.
- `PreToolUse` on Bash: compares the loaded root (`WTENV_ROOT`, or pending)
  with the root of the command's directory. It waits by the clock, at most
  10 s and inside the hook's 30 s timeout; a mismatch with nothing pending
  that outlives 2 s it loads itself into the SessionStart file; a mismatch
  at the deadline is refused, saying the environment is loading.

### In each project

Scripts, tasks and `enterShell` read `$DEVENV_ROOT` when they run, and
wrappers find the tree from where they run (treefmt's
`projectRootFile`). The check names whatever does not.

### The real tool

A single compiled binary. The spike's hit is half process spawns that a
compiled tool does not need (bash re-exec, `devenv version`, perl's
`shasum`, `jq`, `perl`, `sqlite3`); what stays is the adapter's own
per-worktree work, 0.14 s for switchboard-kit. It also removes the spike's
need for bash 5 on a Mac whose `/bin/bash` is 3.2.

## Comment drafted for cachix/devenv#3204

Not posted: it goes up when the owner says so.

> We measured the worktree cost on a real project (devenv 2.4.0,
> aarch64-darwin): a fresh worktree's first `devenv shell` took 21–189 s
> depending on machine load, nothing built or downloaded, against 5.6 s
> warm. We tried caching outside devenv: evaluate once per content of
> `devenv.nix`/`devenv.yaml`/`devenv.lock` (plus the inputs devenv records
> in `.devenv/input-paths.txt`), keep `print-dev-env`'s script in the git
> common dir with the root as a placeholder, and render it per worktree
> (root, dotfile, the runtime dir's hash), then run the shellHook and the
> tasks before it. A fresh worktree then loads in 0.53 s, the result
> matches that worktree's own `print-dev-env` in all but two variables,
> and 20 worktrees created at once evaluate once.
>
> What made it harder than it needs to be:
> - the shell derivation carries `DEVENV_ROOT`, so its output path (and
>   stdenv's `-frandom-seed`) differs per worktree whatever the project
>   does;
> - devenv's own modules write the root into store files: the files tasks
>   (and the settings copy's store name), and treefmt's wrapper unless
>   `projectRootFile` is set;
> - the task file's path is only reachable through the evaluation cache's
>   sqlite.
>
> If the shell and task derivations read the root at run time (#3021), the
> evaluation cache could be keyed without the root and shared across
> worktrees, and none of this would be needed.

## Cleanup

Every scratch worktree and its `spike-tmp/*` branch was removed; the
switchboard-kit cache under its git common dir was deleted; the shared
pre-commit hook was pointed back at the main checkout by `devenv shell --
true` there.
