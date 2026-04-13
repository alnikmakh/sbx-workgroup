# Phase 04 — Workgroup CLI (manifest → tmux → agents)

## Purpose

The user-facing layer. Parse a manifest, provision a git worktree, initialize a bridge namespace (via Phase 03 helpers), build a tmux session, and launch one `claude` per pane with the right role briefing injected into its system prompt. This is the phase that turns the infrastructure into a product.

## Manifest format (definitive)

```yaml
name: feature-x              # [a-z0-9][a-z0-9-]{0,30}

worktree:
  branch: wg/feature-x       # optional, default: wg/<name>
  base: main                 # optional, default: current HEAD of /work

agents:
  - id: planner
    role: planner            # resolves to templates/roles/<role>.md
  - id: reviewer
    role: reviewer
  - id: executor
    role: executor
    role_file: ./roles/my-executor.md   # optional per-workgroup override

# Directed edges: sender -> receiver
edges:
  - planner -> reviewer
  - reviewer -> planner
  - reviewer -> executor
  - executor -> reviewer

layout: tiled                # tiled | even-horizontal | even-vertical | main-vertical
```

Validation rules (all enforced by `lib/manifest.sh`, all produce non-zero exit with a clear message):

- `name` matches `[a-z0-9][a-z0-9-]{0,30}`.
- `agents` non-empty; no duplicate ids.
- Each agent has either `role` (must resolve to a template file) or `role_file` (must exist and be non-empty).
- Every edge endpoint is a declared agent id.
- `layout` is one of the supported values.
- If `worktree.base` is given and `--worktree` is not passed, the base branch/ref must exist in `/work`.

## CLI surface

```
workgroup up    <file.yaml> [--worktree PATH] [--no-worktree]
workgroup down  <name>      [--force]
workgroup ls
workgroup attach <name>
workgroup status <name>
workgroup logs   <name> <agent>
```

### `workgroup up <file.yaml>`

Steps:

1. Parse + validate manifest (`lib/manifest.sh`).
2. Sanity-check the project's sidecar is reachable from inside the VM: `curl -sS "http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/mcp" -o /dev/null`. Fail with a clear message pointing at Phase 01's `provision.sh` if not. **Does not bring the sidecar up** — the sidecar is started by `provision.sh` on the host before the VM is created and is not `workgroup`'s concern. (Earlier drafts of this doc referenced `127.0.0.1:8811`; Phase 01's checkpoint overrode that contract — see `plans/checkpoints/phase-01.md` §2.)
3. Resolve worktree (`lib/worktree.sh`):
   - default: `git -C /work worktree add /work/worktrees/<name> -b <branch> <base>`.
   - `--worktree PATH`: assert PATH exists and is a valid git worktree; use as-is.
   - `--no-worktree`: use `/work` directly; print a warning about concurrent writes.
4. `bridge-init <name> --agents <csv> --edges "a->b,b->c"` (delegates to Phase 03). Agents are comma-separated; edges are arrow-pairs joined by commas, exactly as `bridge-init` expects.
5. For each agent: resolve role source (template by name, or `role_file`), copy the content to `/bridge/<name>/roles/<agent-id>.md`.
6. `lib/tmux.sh create <name> <layout> <agents…>`:
   - `tmux new-session -d -s <name> -n agents`.
   - For the first agent, configure the initial pane; for subsequent agents, split with the chosen layout.
   - `tmux new-window -t <name>: -n watch 'bridge-watch <name>'`.
7. For each agent pane, `tmux send-keys` the launch command:
   ```sh
   cd <worktree> && \
   BRIDGE_DIR=/bridge/<name> \
   AGENT_ID=<id> \
   AGENT_PEERS_OUT=<csv> \
   AGENT_PEERS_IN=<csv> \
   claude --append-system-prompt "$(cat /bridge/<name>/roles/<id>.md)"
   ```
   Derive `AGENT_PEERS_OUT` / `AGENT_PEERS_IN` from `edges` at launch time.
8. Print: `Workgroup "<name>" up. Attach with: workgroup attach <name>` and a summary table of agents + edges.

If a session with the same name already exists, `up` errors out with a message and suggests `workgroup attach` or `workgroup down <name>`. We do not auto-reattach because the user might want to recreate intentionally.

### `workgroup down <name> [--force]`

Steps:

1. `tmux has-session -t <name>` — if present, `tmux kill-session -t <name>`.
2. `mv /bridge/<name> /bridge/_archive/<name>-$(date -u +%Y%m%dT%H%M%SZ)/`.
3. `--force` only: if `git -C /work/worktrees/<name> status --porcelain` is empty, `git -C /work worktree remove /work/worktrees/<name>`; otherwise refuse with an "uncommitted changes" message.
4. Print summary.

**Note on worktree lifecycle:** without `--force`, `down` intentionally leaves the worktree on disk — the user may want to inspect or keep work in progress. Worktrees are only ever removed explicitly with `--force` on a clean tree. There is no auto-remove path.

### `workgroup ls`

List archived and active workgroups. Active = tmux session exists. Shows name, created_at (from `state.json`), agent count, worktree path, running/archived status.

### `workgroup attach <name>`

`tmux attach -t <name>`. Error if no such session.

### `workgroup status <name>`

Reads `state.json` and the bridge inboxes. Prints a table:

```
agent     inbox    last-activity
planner   0        2m ago
reviewer  1        now
executor  0        5m ago
```

v1: `last-activity` comes from `tmux list-panes -t <name> -F "#{pane_title} #{t:pane_activity}"`. Simple; extend later if needed.

### `workgroup logs <name> <agent>`

`tmux capture-pane -t <name>:agents.<pane-index> -p -S -3000`. Prints the last 3000 lines of the agent's pane.

## Role injection at pane launch (load-bearing)

The shell command sent into each pane MUST use `claude --append-system-prompt "$(cat …)"`. This is the only mechanism that survives `/clear` — the role content becomes part of the system prompt, which `/clear` does not wipe. Verification checklist (Phase 06 step 7) is specifically about this.

## Inputs

- Phase 01: VM, packages, mounts, `workgroup` on PATH; sidecar running on the host (driven by `provision.sh`).
- Phase 02: sidecar image built; `http://127.0.0.1:8811/mcp` reachable from inside the VM.
- Phase 03: `bridge-init`, `bridge-send`, `state.json` schema, `/bridge/<name>/` layout.
- Phase 05 (soft): role templates under `workgroup/templates/roles/`. If missing, `up` errors with a clear message pointing at the template path.

## Outputs / contracts published

- The `workgroup` command on PATH.
- The manifest schema (above) as the user-facing contract. Changing it is a breaking change.
- `/bridge/<name>/state.json` populated per `00-overview.md` schema.
- A tmux session named `<name>` with one pane per agent plus a `watch` window.

## Verification

1. `workgroup up examples/feature-x.yaml` exits 0; prints the attach command.
2. `tmux ls` shows `feature-x`; `tmux list-panes -a -t feature-x` shows N agent panes + 1 watch window.
3. `git -C /work worktree list` includes `/work/worktrees/feature-x` on branch `wg/feature-x`.
4. `workgroup status feature-x` prints all inboxes at 0.
5. Attach a pane and run `/clear`, then ask "what is your role?" — expected answer names the role. **This is the load-bearing test for role injection.**
6. `workgroup up examples/bad-*.yaml` with various invalid manifests — each exits non-zero with a precise error naming the offending field.
7. `workgroup up feature-x.yaml` when the session already exists — exits non-zero with the attach/down hint.
8. `workgroup down feature-x` — `tmux ls` no longer contains it; `/bridge/_archive/feature-x-*` exists; `/work/worktrees/feature-x` still exists.
9. `workgroup down feature-x --force` on a second run — cleanly removes the worktree if clean; refuses otherwise.

## Open items

- `workgroup status` richness beyond inbox + last-activity — defer to user feedback.
- Whether `up` should stream the gateway health check output or stay silent on success. Starting: silent on success, log on failure.
- Whether we should expose a `workgroup reload <name> <agent>` that restarts a single pane with a fresh `claude` invocation (useful if a session dies). Deferred to v2.
- Shell vs Go: starting with POSIX shell + `yq`/`jq`; if the dispatcher exceeds ~500 lines of shell, reconsider.
