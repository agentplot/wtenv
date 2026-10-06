# wtenv

Every git worktree gets its developer environment in about a second, whatever
the environment tool, and every command an agent runs is already inside it.

A repository's environment depends on a handful of files: `devenv.nix`,
`devenv.yaml` and `devenv.lock`, or `flake.nix` and `flake.lock`, or
`mise.toml`. wtenv evaluates the environment once per machine for each content
of those files, keeps the result in the repository's git common dir, and hands
it to every worktree with that worktree's own paths and per-worktree values put
back. A new worktree, a hundred agents, or a fresh Claude Code session all read
the same entry.

It ships as three small parts:

- `wtenv`, the cache and its CLI, also installed as `wt-env` so worktrunk runs
  it as `wt env`.
- An adapter per environment tool: devenv first, then Nix flakes, mise and
  Flox.
- A Claude Code plugin whose hooks load the environment into every Bash command
  of a session, its subagents included.

Nothing is built yet. The spike that decides the design is in
[`docs/spike.md`](docs/spike.md).

MIT licensed.
