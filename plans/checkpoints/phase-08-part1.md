# Phase 08 — Part 1 checkpoint

Branch: `standalone-workgroup`. All three test suites green:
`test-bridge.sh` (32), `test-workgroup.sh` (39), `test-standalone.sh` (11).

## What shipped in part 1

Decoupled the workgroup runtime from the sbx VM so the same code runs
unchanged on any Linux or macOS host that has tmux + git + jq + yq.

### Files added

- `workgroup/lib/config.sh` — XDG-aware loader. Reads
  `${WORKGROUP_CONFIG:-$XDG_CONFIG_HOME/workgroup/config.yaml}` if present
  and exports `WORKGROUP_HOME`, `BRIDGE_ROOT`, `WORKTREE_ROOT`,
  optional `WORKGROUP_PROJECTS_ROOT`, and `WORKGROUP_MCP_BLOCK`
  (TSV: `name<TAB>transport<TAB>url`). All values respect a
  pre-set env var, so the existing sbx flow that exports env vars in
  postinstall.sh keeps working untouched.
- `workgroup/test-standalone.sh` — exercises the new code paths with
  `HOME` / `XDG_DATA_HOME` / `XDG_CONFIG_HOME` pointed at a tmpdir and
  no preset `WORK_ROOT` / `BRIDGE_ROOT`. Resolves source from a
  manifest's `worktree.source`, asserts state.json paths, validates
  `down --force`.
- `docs/INSTALL-standalone.md` — short Linux + macOS quickstart.
- `plans/08-standalone.md` — the design plan (already written).
- `plans/checkpoints/phase-08-part1.md` — this file.

### Files modified

- `workgroup/bin/workgroup`
  - Replaced `readlink -f` with a portable `_resolve_dir` (POSIX
    `pwd -P` + manual symlink loop). Works on macOS without coreutils.
  - Sources `lib/config.sh` first; calls `config_load` to populate
    XDG defaults.
  - Removed the `/etc/workgroup/sidecar-port` reachability check from
    `cmd_up`. Replaced with optional `claude mcp add` loop driven by
    `WORKGROUP_MCP_BLOCK`. Failures are warnings, not fatal.
  - `cmd_up` now resolves `WORK_ROOT` from (in order): `--source`
    flag, manifest's `worktree.source`, pre-set env, manifest dir if
    in a git repo, cwd if in a git repo, `$WORKGROUP_PROJECTS_ROOT/
    <name>`. Hard error with a clear message if none match.
  - `cmd_up`'s `state.json` mutation now uses `locked_subshell`.
  - New `doctor` subcommand: prints resolved paths, checks for tmux,
    git, jq, yq, claude, flock, inotifywait, sniffs go-yq vs python
    yq, exits non-zero if a hard requirement is missing.

- `workgroup/lib/bridge.sh`
  - `BRIDGE_ROOT` default changed from `/bridge` to
    `$XDG_DATA_HOME/workgroup/bridges` (only kicks in when no caller
    set it).
  - Inlined `locked_subshell` — uses `flock(1)` when present, falls
    back to atomic `mkdir`-of-sibling-dir with EXIT-trap cleanup on
    macOS. Inlined rather than split into a separate file because
    test-bridge.sh sources bridge.sh directly and we can't reliably
    locate a sibling include from inside a sourced library.
  - `bridge_next_signal_id` rewritten to use `locked_subshell` via a
    helper function `_bridge_next_id_body`.

- `workgroup/lib/worktree.sh`
  - Stopped reading `/etc/workgroup/worktree-root`. `WORK_ROOT` no
    longer defaults to `/work`; the dispatcher resolves it before
    calling in.
  - `worktree_remove_if_clean` runs `git worktree remove` from inside
    the worktree itself instead of from `$WORK_ROOT`, so `cmd_down`
    no longer needs to know the source repo path.

- `workgroup/lib/manifest.sh` — parses `worktree.source` into
  `WG_SOURCE` (with `~` / `~/foo` tilde expansion). Backwards-compat:
  unset is fine, falls through to the other resolution rules.

- `workgroup/bin/{bridge-init,bridge-send,bridge-recv,bridge-peek,
  bridge-watch}` — replaced the `readlink -f -- $0 || …` line with
  the inline POSIX symlink-resolver loop. macOS-safe.

### macOS portability status

- `readlink -f`: gone from every entry point.
- `flock`: replaced via `locked_subshell` shim.
- `date`: still POSIX `date -u +…`. No GNU `-d`.
- `stat`, `find -printf`: not used in the runtime.
- `bash`: dispatcher is `/bin/sh`. test scripts are `/bin/sh`.
- Untested on real macOS hardware. The risk is small but real —
  `workgroup doctor` is the first thing to run on a Mac.

### What was NOT done (deferred to part 2)

- **Step 9 from `plans/08-standalone.md`**: rewriting
  `workgroup/etc/postinstall.sh` to write a `config.yaml` instead of
  `/etc/workgroup/{sidecar-port,worktree-root}`. The sbx flow still
  works because the dispatcher honors pre-set env vars set by the
  current postinstall, but the duplication should be cleaned up.
- **README rewrite**. Top-level `README.md` still leads with the sbx
  story. Demoting sbx to "optional sandboxed mode" is a separate
  commit so the diff is reviewable on its own.
- **Removing `etc/postinstall.sh`'s sidecar port write** — keep until
  part 2 lands so sbx mode keeps registering cgc.
- **Real macOS bring-up rehearsal**. Need to actually run
  `workgroup doctor` and `test-standalone.sh` on a Mac. Linux runs
  pass; macOS coverage is theoretical.
- **Manifest `mcp:` per-workgroup block**. Plan calls for merging a
  per-manifest `mcp:` list with the config-level one. Today only the
  config-level block is honored. Add when first user asks.

## How to resume in part 2

1. Rewrite `workgroup/etc/postinstall.sh` to:
   - Stop writing `/etc/workgroup/sidecar-port` and
     `/etc/workgroup/worktree-root`.
   - Instead write `${WORKGROUP_HOME:=/var/lib/workgroup}/config.yaml`
     containing `worktree_root:` and an `mcp:` block with the cgc URL
     using the same `$SIDECAR_PORT` it already has.
   - Set `WORKGROUP_HOME=/var/lib/workgroup` (or wherever) in
     `/etc/profile.d/workgroup.sh` so login shells inside the VM see
     it without needing the symlinks.
   - Drop the `link_contract /work /bridge /opt/workgroup` symlinks
     once the standalone CLI is the only path. Optional convenience
     aliases can stay.
2. Re-run sbx provision + the in-sandbox smoke test from
   `plans/06-verification.md` to confirm the in-VM workflow still
   produces a working workgroup.
3. Rewrite top-level `README.md`: lead with standalone clone-and-run,
   demote sbx to a "sandboxed mode" subsection. Use the structure of
   `docs/INSTALL-standalone.md` for the quickstart; sbx specifics
   move to `docs/INSTALL-sbx.md` (rename of the current README intro).
4. Rehearse on macOS: clone, `brew install tmux git jq yq`,
   `workgroup doctor`, `test-standalone.sh`. Fix whatever breaks.
   Most likely suspects: `sleep 0.05` (BSD `sleep` accepts decimals
   but warn if not), `mkdir` lock race window, `tmux send-keys`
   quoting around `$()`.
5. Optional: implement per-manifest `mcp:` block merging.

## Test commands for the next session

```sh
git status                               # confirm branch
./workgroup/test-bridge.sh               # 32 pass
./workgroup/test-workgroup.sh            # 39 pass (legacy env-preset path)
./workgroup/test-standalone.sh           # 11 pass (new XDG/source path)
./workgroup/bin/workgroup doctor         # human-readable env summary
```

All three suites must stay green through every part-2 step.
