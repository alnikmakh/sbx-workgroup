# Phase 08 — Standalone workgroups (decouple from sbx)

## Purpose

Extract the tmux/bridge/roles runtime from the sbx microVM coupling so a user
on any Linux or macOS host can `brew install` (or clone) the tool, drop a
manifest, and run `workgroup up feature-x.yaml` directly against a checkout
on disk. No microVM, no sidecar, no cgc requirement. The sbx integration
remains supported as one optional deployment mode, not the default.

## Goals

- One repo, one CLI (`workgroup`), runs on Linux and macOS without sbx.
- Zero hard-coded absolute paths (`/work`, `/bridge`, `/opt/workgroup`,
  `/etc/workgroup/*`). All locations come from config + env + sensible
  defaults under `$XDG_*` / `$HOME`.
- macOS portability: no GNU-isms that BSD userland lacks (`readlink -f`,
  `flock`, `date -d`, `stat -c`, `find -printf`).
- cgc / MCP integration becomes an **opt-in hook**, not a required
  precondition. The sidecar reachability check in `cmd_up` is removed from
  the standalone path.
- Existing sbx mode still works: it becomes a thin wrapper that sets the
  same env vars `postinstall.sh` sets today.

## Non-goals

- Rewriting the CLI in Go. Stay in POSIX sh + `jq` + `yq`.
- Changing the bridge protocol, signal schema, or manifest format. Phase 03
  contracts are stable.
- Multi-host / networked bridges. Bridge is still local-FS only.
- Building a package / Homebrew formula in this phase. Just make the repo
  runnable from a clone; packaging is a follow-up.

## Current coupling (what to cut)

Inventory of every place the runtime assumes "I'm inside the sbx VM":

1. **Path constants** in `bin/workgroup`:
   - `BRIDGE_ROOT=/bridge`, `WORK_ROOT=/work`, `WORKGROUP_ROOT=/opt/workgroup`
   - reads `/etc/workgroup/worktree-root`
2. **Sidecar reachability check** in `cmd_up` reads
   `/etc/workgroup/sidecar-port` and curls `host.docker.internal:<port>/mcp`.
3. **`bridge.sh`** defaults `BRIDGE_ROOT=/bridge`.
4. **`worktree.sh`** computes default worktree path from `WORKTREE_ROOT` /
   `WORK_ROOT/worktrees`.
5. **`postinstall.sh`** is the only place that materializes the
   `/work` ↔ `/bridge` ↔ `/opt/workgroup` symlinks, writes
   `/etc/workgroup/{sidecar-port,worktree-root}`, installs apt packages,
   and registers the cgc MCP server with `claude mcp add`.
6. **`tmux.conf`** ships to `/etc/tmux.conf` (Linux-only convention; macOS
   users keep their own).
7. **`flock`** in `cmd_up` and `bridge.sh` — not present on stock macOS.
8. **`readlink -f`** in the dispatcher — BSD readlink lacks `-f`.
9. **Test harness** (`test-workgroup.sh`) already runs on the host; verify
   it still does on macOS.

## Target layout

```
$XDG_CONFIG_HOME/workgroup/config.yaml      # per-machine config (was machine.yaml)
$XDG_DATA_HOME/workgroup/bridges/<name>/    # bridge namespaces (was /bridge)
$XDG_DATA_HOME/workgroup/worktrees/<proj>/  # default worktree root
$XDG_DATA_HOME/workgroup/archive/           # archived bridges
<repo-clone>/workgroup/                     # the CLI payload itself (was /opt/workgroup)
```

`config.yaml` shape (everything optional, all keys have defaults):

```yaml
# Where the CLI looks for project source trees when a manifest names a
# project by id rather than absolute path. Optional.
projects_root: ~/src

# Override bridge root.
bridge_root: ~/.local/share/workgroup/bridges

# Override worktree root.
worktree_root: ~/.local/share/workgroup/worktrees

# Optional MCP servers to register per workgroup. Empty = none.
mcp:
  - name: cgc
    transport: http
    url: http://127.0.0.1:8765/mcp
```

Resolution order for every path: CLI flag → env var → `config.yaml` →
XDG default. No file under `/etc/` is ever read in standalone mode.

## Env var contract (new)

| Var                | Default                                  | Replaces                       |
|--------------------|------------------------------------------|--------------------------------|
| `WORKGROUP_HOME`   | `$XDG_DATA_HOME/workgroup`               | (new root)                     |
| `WORKGROUP_ROOT`   | dir of the `workgroup` script's repo     | `/opt/workgroup`               |
| `BRIDGE_ROOT`      | `$WORKGROUP_HOME/bridges`                | `/bridge`                      |
| `WORKTREE_ROOT`    | `$WORKGROUP_HOME/worktrees`              | `/etc/workgroup/worktree-root` |
| `WORK_ROOT`        | unset (must come from manifest or `cwd`) | `/work`                        |
| `WORKGROUP_CONFIG` | `$XDG_CONFIG_HOME/workgroup/config.yaml` | (new)                          |

The sbx mode keeps its current values by exporting them in
`postinstall.sh`. No change to in-VM behavior.

## Manifest changes

Backwards-compatible additions only:

- `worktree.source:` — absolute path to the source repo. Optional. If
  absent, the dispatcher falls back to (a) `--source PATH` flag, (b) cwd
  if it's a git repo, (c) `projects_root/<name>` from config.
- `mcp:` block at top level (same shape as the config-level block); merged
  on top of config-level entries. Per-workgroup `claude mcp add` calls run
  before pane launch.

No change to `agents`, `edges`, `layout`, `name`, `worktree.branch`,
`worktree.base`. Existing manifests keep working unmodified.

## CLI changes

- `cmd_up`:
  - Remove the `/etc/workgroup/sidecar-port` block entirely. Replace with
    a generic "register MCP servers from config" step gated on the `mcp:`
    block being non-empty. `claude mcp add` failures become warnings, not
    fatal — the workgroup is still useful without the index.
  - Compute `WORK_ROOT` from manifest/flag/cwd before calling
    `worktree_resolve`.
- `cmd_down`: unchanged in logic; just reads paths from env, not `/etc`.
- New `workgroup doctor` subcommand: prints resolved paths, checks for
  `tmux`, `git`, `jq`, `yq`, `claude`, `flock`-or-shim, and prints
  `OK`/`MISSING` per dependency. This is the single thing a new user runs
  after cloning to confirm their machine is ready.

## macOS portability work

- **`readlink -f`**: replace with a small POSIX shim
  (`cd "$(dirname "$0")" && pwd -P`) at the top of `bin/workgroup` and
  every other entry-point script. No external dep.
- **`flock`**: introduce `lib/lock.sh` with `lock_acquire <path>` /
  `lock_release`. Implementation:
  - If `command -v flock` exists, use it.
  - Else use `mkdir <path>.lock` (atomic on POSIX) with a trap to clean up.
  Both `cmd_up`'s state.json mutation and `bridge.sh`'s lock sites use
  the wrapper.
- **`date -u +%Y%m%dT%H%M%SZ`**: already POSIX, keep.
- **`stat`**: audit; replace any `stat -c` (GNU) with `stat -f` fallbacks
  or pure-shell alternatives.
- **`find -printf`**: audit; not used today, keep that way.
- **bash version**: dispatcher is `/bin/sh` already. Verify
  `test-workgroup.sh` runs under `/bin/sh` too (the shebang says `bash`
  today; check whether the body needs it).
- **`tmux capture-pane -t <name>:agents.<idx>`**: works identically on
  macOS tmux. No change.

## cgc / sbx as optional plugins

After this phase:

- `sbx/` directory stays. `provision.sh` keeps doing what it does, but
  the in-VM `postinstall.sh` simply exports `WORKGROUP_HOME=/var/lib/workgroup`
  (or similar) and the standalone `workgroup` binary works unchanged
  inside the VM. The `/work`, `/bridge`, `/opt/workgroup` symlinks become
  optional convenience aliases, not load-bearing.
- The cgc registration that today lives in `postinstall.sh` moves into
  `config.yaml`'s `mcp:` block, populated by `provision.sh` at first
  boot. Standalone users who want cgc add the same block manually.
- `host-mcp/` (sidecar + `mcp_mux.py`) stays in tree as the recommended
  cgc deployment, but is not invoked by `workgroup up` anywhere.

## Stepwise execution plan

Each step is a self-contained commit; the tree stays green between steps.

1. **Path indirection**: introduce env-var defaults in `bin/workgroup`,
   `bridge.sh`, `worktree.sh`. No behavior change yet — defaults still
   resolve to `/bridge` etc when the env vars are unset on Linux. Verify
   with `test-bridge.sh` + `test-workgroup.sh`.
2. **XDG defaults**: switch the unset-fallbacks from `/bridge` etc to
   `$XDG_DATA_HOME/workgroup/...`. Update both test scripts to set
   `WORKGROUP_HOME` to a tmpdir explicitly so they don't pollute the
   user's real XDG dir.
3. **Config loader**: add `lib/config.sh` that reads
   `$WORKGROUP_CONFIG` (yq-based, optional) and exports the resolved
   env vars. Sourced once at the top of `bin/workgroup`.
4. **Lock shim**: add `lib/lock.sh`, replace direct `flock` calls in
   `cmd_up` and `bridge.sh`. Test on a Linux box with `flock` PATH-
   masked to confirm the mkdir fallback works.
5. **`readlink -f` removal**: replace in all `bin/` scripts. Run both
   test scripts.
6. **Sidecar check removal**: delete the `/etc/workgroup/sidecar-port`
   block from `cmd_up`. Replace with the new `mcp:`-block registration
   loop (stub: read the block, log what it would register, skip the
   actual `claude mcp add` until step 8).
7. **`workgroup doctor`**: new subcommand. Used as the smoke test for
   steps 1–6 on a clean macOS box.
8. **MCP registration**: enable the `claude mcp add` calls in the loop
   from step 6. Failures print a warning and continue.
9. **sbx postinstall update**: postinstall stops writing
   `/etc/workgroup/sidecar-port` and `/etc/workgroup/worktree-root`;
   instead writes a `config.yaml` under `$WORKGROUP_HOME` with the
   right `mcp:` block and `worktree_root:`. Verify the in-VM smoke test
   in `plans/06-verification.md` still passes.
10. **Docs**: rewrite top-level `README.md` with standalone-first
    quickstart; demote sbx to "optional sandboxed mode" section.
    Add `docs/INSTALL-standalone.md` (Linux + macOS).

After step 10 the standalone story is shippable. sbx mode still works
because postinstall now produces a config the standalone CLI consumes.

## Risks

- **Manifest source resolution ambiguity**: cwd vs config vs flag — if
  this gets wrong the user runs a workgroup against the wrong tree.
  Mitigation: `workgroup up` always prints the resolved source repo
  path, branch, and worktree path before launching panes; the existing
  summary table already shows worktree, just add `source` next to it.
- **Lock fallback correctness**: `mkdir`-based locks don't auto-release
  on process death. Mitigation: trap EXIT/INT/TERM to rmdir; document
  that crashed `workgroup` runs may leave a stale lock that the user
  removes manually. State.json mutations are short, so the window is
  tiny.
- **macOS `tmux` config drift**: users have varied `~/.tmux.conf`. We
  do not ship a system-wide tmux.conf in standalone mode; the workgroup
  session inherits the user's config. Acceptable.
- **`yq` flavor**: Mike Farah's Go `yq` vs Python `yq` differ in CLI.
  Today's code uses Go yq. `workgroup doctor` should detect the wrong
  flavor and tell the user which to install.

## Verification

- `test-bridge.sh` and `test-workgroup.sh` pass on Linux unchanged after
  every step.
- New `test-standalone.sh`: runs `workgroup up` against a tmpdir-based
  source repo with `WORKGROUP_HOME` set to another tmpdir; asserts
  bridge dir, worktree, tmux session created and torn down cleanly.
- Manual: clone fresh on a Mac, `brew install tmux git jq yq`, `bash
  workgroup/bin/workgroup doctor`, then run the smoke test.
- Manual: re-run `sbx/provision.sh tg-digest` after step 9 and confirm
  the in-VM workflow still produces a working workgroup.

## Open items

- Should `workgroup` ship a default role set inside the repo, or expect
  the user to write their own? Today's `templates/roles/{planner,
  reviewer,executor}.md` are good defaults — keep shipping them.
- Naming: `workgroup` is fine inside this repo, but as a standalone
  tool the binary name might collide. Consider `tmux-workgroup` or
  `wg` as alternates. Defer to packaging phase.
- Whether `down` should default to `--force` in standalone mode (the
  worktree lives under `$WORKGROUP_HOME` and is disposable). Defer.
