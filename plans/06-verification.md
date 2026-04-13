# Phase 06 — End-to-end verification

## Purpose

A single checklist that exercises the whole system. Only meaningful once Phases 01–05 are in place. Lives as its own phase so that whenever something big changes, there's one canonical place to re-run for confidence.

## Scope

- Manual smoke-test checklist (below). No test framework in v1.
- `sbx/scripts/smoke.sh`: automates the non-interactive steps (manifest validation, tmux session creation, bridge send/recv, teardown). Interactive Claude steps stay manual.

## End-to-end checklist

Prereqs: host has Docker `sbx` installed; `~/.config/sbx-workgroup/machine.yaml` populated; `${projects_root}/<project>` exists; `~/sbx-bridge` will be created.

### 0. Sidecar primitives (Phase 02, precedes everything)
- [ ] `sbx/host-mcp/build.sh` builds `sbx-cgc-sidecar:local` without error.
- [ ] `sbx/host-mcp/sidecar-up.sh <project>` exits 0 and prints a single-line host port in 8000-8999.
- [ ] `docker ps` shows `cgc-sidecar-<project>` running with label `sbx.project=<project>`.
- [ ] `curl -sS http://127.0.0.1:<port>/mcp` on the host returns an MCP handshake response.
- [ ] **Concurrency check (load-bearing).** Two concurrent MCP clients call a cgc tool at overlapping times; both succeed; `docker exec cgc-sidecar-<project> ps` shows exactly one `cgc mcp start` child process. If this fails, the multiplexer is broken — stop and fix before continuing.
- [ ] Re-running `sidecar-up.sh <project>` is a no-op and prints the same port.
- [ ] `sidecar-down.sh <project>` then `sidecar-up.sh <project>` cycle preserves `${cgc_data_root}/<project>/`; a previously-indexed query returns data without reindexing.

### 1. Host provisioning
- [ ] `./sbx/provision.sh <project>` exits 0.
- [ ] `sbx ls` shows the VM in running state with the project's hashed host port published to guest `8811`.
- [ ] `docker ps` shows `cgc-sidecar-<project>` running (brought up by `provision.sh`'s sidecar step).

### 2. Inside-VM sanity
- [ ] `sbx exec <name> -- sh -c 'ls -ld /work /bridge /opt/workgroup'` — all three present.
- [ ] `sbx exec <name> -- sh -c 'curl -fsS http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/health >/dev/null && echo ok'` prints `ok` — proves sbx policy + HTTP proxy reach the host sidecar. (Note: the original draft said `http://127.0.0.1:8811/mcp` via `sbx ports --publish`; that wiring doesn't apply — see Phase 01 checkpoint §2.)
- [ ] `command -v workgroup bridge-send bridge-recv bridge-peek bridge-watch bridge-init` — all resolve.
- [ ] (The earlier "docker absent inside VM" negative check was based on a wrong assumption about the `shell-docker` template, which ships docker on purpose. Removed.)

### 3. MCP sidecar from inside the VM
- [ ] In a plain `claude` session inside the VM: `claude mcp list` shows `cgc` as connected.
- [ ] Ask the session to use a `cgc` tool against `/work` — returns a real response.
- [ ] Restart the project's sidecar container (`docker restart cgc-sidecar-<project>`) while the VM session is idle; next tool use reconnects transparently.

### 4. Bridge primitives (Phase 03, Claude-free)
- [ ] `bridge-init test-wg --agents a,b --edges "a->b"` creates the full tree and `state.json`.
- [ ] `AGENT_ID=a BRIDGE_DIR=/bridge/test-wg bridge-send --to b --kind note --file /tmp/hi.md --subject "ping"` — exits 0, prints id.
- [ ] Signal present in `/bridge/test-wg/inbox/b/`; audit copy in `/bridge/test-wg/outbox/a/`; payload in `/bridge/test-wg/notes/`.
- [ ] `AGENT_ID=b BRIDGE_DIR=/bridge/test-wg bridge-recv` lists it.
- [ ] `bridge-recv --pop <id>` prints payload, moves signal to archive.
- [ ] `AGENT_ID=b BRIDGE_DIR=/bridge/test-wg bridge-send --to a ...` exits non-zero with "no edge b->a".
- [ ] `bridge-watch test-wg` in a separate shell prints a `NEW` line within 1s of a fresh send.

### 5. Manifest validation (Phase 04)
- [ ] `workgroup up examples/bad-edges.yaml` exits non-zero with "edge planner->ghost: ghost is not a declared agent".
- [ ] A manifest with duplicate agent ids is rejected with a matching error.
- [ ] A manifest with a bad `name` format is rejected with a matching error.

### 6. Happy path (Phase 04 + Phase 05)
- [ ] `workgroup up examples/feature-x.yaml` exits 0; prints attach command.
- [ ] `git -C /work worktree list` shows `/work/worktrees/feature-x` on branch `wg/feature-x`.
- [ ] `tmux list-panes -a -t feature-x` shows 3 agent panes + 1 watch window.
- [ ] `workgroup status feature-x` shows inbox=0 for every agent.

### 7. Role persistence (load-bearing)
- [ ] Attach to planner pane: `workgroup attach feature-x`.
- [ ] Run `/clear` in the planner's Claude session.
- [ ] Ask "what is your role?" — answer names "planner". **If this fails, `--append-system-prompt` is broken; stop and fix before continuing.**
- [ ] Repeat for reviewer and executor.

### 8. Bridge happy path through Claude
- [ ] In planner pane: ask Claude to draft a short plan and hand off via `bridge-send` to reviewer.
- [ ] `watch` window prints the `NEW` line for the send.
- [ ] In reviewer pane: ask Claude to `bridge-recv`, read the plan, write a report, and `bridge-send` back.
- [ ] Host-side `~/sbx-bridge/feature-x/plans/` and `/reports/` contain the files.

### 9. Topology enforcement through Claude
- [ ] In executor pane: ask Claude to `bridge-send --to planner ...`. Claude's shell call exits non-zero with "no edge executor->planner".
- [ ] Confirm no stray file was created in `/bridge/feature-x/inbox/planner/` or `/bridge/feature-x/plans/`.

### 10. MCP tool use inside a workgroup
- [ ] In any pane: ask Claude to use `cgc` to answer a code question about `/work`. Confirm a non-error tool response.

### 11. Teardown
- [ ] `workgroup down feature-x`.
- [ ] `tmux ls` no longer lists `feature-x`.
- [ ] `/bridge/_archive/feature-x-<ts>/` exists with all previous content.
- [ ] `/work/worktrees/feature-x` still exists.
- [ ] `workgroup down feature-x --force` on a clean worktree removes it.
- [ ] `workgroup down feature-x --force` on a dirty worktree refuses with a message.

### 12. Parallel isolation
- [ ] `workgroup up examples/feature-a.yaml` and `workgroup up examples/feature-b.yaml` both succeed (manifests ship with Phase 05).
- [ ] Each has its own tmux session, bridge dir, and worktree.
- [ ] From a feature-a agent: `bridge-send --to <feature-b agent>` exits non-zero (different `state.json`, different workgroup namespace).
- [ ] `workgroup ls` lists both as running.

### 13. VM rebuild preserves cgc index
- [ ] Note a cgc query result inside the VM.
- [ ] `./sbx/teardown.sh <project>` (removes VM + sidecar); re-run `./sbx/provision.sh <project>`; attach.
- [ ] Same cgc query returns results immediately (no reindex wait) — confirms the DB survived on the host at `${cgc_data_root}/<project>/` across a full VM+sidecar cycle.

## `sbx/scripts/smoke.sh`

Automates steps 0, 4, 5, 6 (manifest validation), 11, 12 — the Claude-free parts. Steps 7, 8, 9, 10, 13 stay manual because they require a human to interact with a Claude session or to observe VM rebuild timing.

The script:

1. Cleans up any previous `test-wg*` bridge dirs.
2. Runs the bridge primitive checks.
3. Runs `workgroup up` against each `examples/bad-*.yaml`, asserting non-zero exit and an expected substring in stderr.
4. Runs `workgroup up examples/feature-x.yaml`, asserts tmux session exists and worktree exists, then `workgroup down feature-x` and asserts the archive exists.
5. Runs the parallel isolation scenario.
6. Exits 0 on full success, non-zero with a summary on first failure.

## Inputs

Phases 01–05 complete.

## Outputs

A green checklist. Failures drive fix commits in whichever phase owns the broken behavior; no fix commits land in Phase 06 itself unless the checklist or smoke script needs updating.

## Open items

- Whether to add a GitHub Actions job that runs `smoke.sh` against a cached VM image. Deferred: we don't have CI wired up yet, and sbx-in-CI is its own rabbit hole.
- Whether to record a short screencast of the happy path for the README. Deferred.
