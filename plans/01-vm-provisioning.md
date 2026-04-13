# Phase 01 — sbx microVM provisioning

## Purpose

Go from a fresh host to a running sbx microVM that has every system dependency later phases need. Nothing workgroup-specific lives here — this phase delivers a clean environment and hands off to Phases 02/03/04 via the mount and PATH contracts defined in `00-overview.md`.

## Scope

### `sbx/provision.sh` (runs on the host)

Usage: `./sbx/provision.sh <project> [--name <sandbox-name>] [--memory <SIZE>]`. `<project>` is required and must correspond to a directory under `${projects_root}/<project>`.

Responsibilities:

1. Verify the `sbx` CLI (Docker Sandboxes, v0.24+) is installed; if not, print install pointer and exit non-zero.
2. Load `~/.config/sbx-workgroup/machine.yaml`; error with a precise message if missing.
3. Resolve the project source path to `${projects_root}/<project>`. Verify it exists.
4. Ensure `~/sbx-bridge` exists; create if missing.
5. **Ensure the project's sidecar is up** — `port=$(sbx/host-mcp/sidecar-up.sh <project>)`. `sidecar-up.sh` is idempotent; on first call it builds the sidecar image if missing, starts the container, and waits for `/health` to answer. Capture the printed host port for step 7a.
6. Check whether a sandbox with the chosen name already exists (`sbx ls -q`). If yes, re-run postinstall (idempotent) and exit 0; the user runs `sbx run <name>` manually.
7. `sbx create shell` the sandbox with:
   - Name (default: `sbx-<project>`; override via `--name`).
   - `--memory` (default: `8g`; override via `--memory`). `sbx` does not expose `--cpus` or `--disk`.
   - Positional workspace paths: `<project_dir> ~/sbx-bridge <repo>/workgroup:ro`. **`sbx` always mounts host paths at the same path inside the sandbox**; the `/work`, `/bridge`, `/opt/workgroup` contract is materialized as symlinks by `postinstall.sh`.
   - The `shell` agent is used (not `claude`) — we run tmux + multiple claude panes ourselves in Phase 04, so the sandbox must not auto-launch an agent.
7a. `sbx ports <name> --publish 127.0.0.1:${port}:8811` — publishes the sidecar's hashed host port to the sandbox's fixed guest port 8811. `sbx` does not accept `--publish` at create time; it is a separate post-create subcommand.
8. On first-boot success: `sbx exec -u root -e WORK_SRC=... -e BRIDGE_SRC=... -e WORKGROUP_SRC=... <name> <repo>/workgroup/etc/postinstall.sh`. The env vars tell postinstall the real host paths so it can materialize the `/work`, `/bridge`, `/opt/workgroup` symlinks. The postinstall script is invoked by its real host path because `/opt/workgroup` does not exist until it has run at least once.
9. Print the `sbx run <name>` command the user should use next and the one-time `claude mcp add` line.

Idempotency: re-running `provision.sh` on an already-provisioned sandbox is safe — it detects the sandbox, skips `sbx create shell` + `sbx ports`, re-runs `postinstall.sh` (idempotent), and exits 0. The sidecar check at step 5 is always run and is itself idempotent.

### `sbx/teardown.sh` (runs on the host)

Usage: `./sbx/teardown.sh <project> [--name <sandbox-name>]`.

1. `sbx stop <name>` (ignored if absent/already stopped), then `sbx rm <name>` (no-op if absent). `sbx` uses `rm`, not `delete`.
2. `sbx/host-mcp/sidecar-down.sh <project>` — stops and removes the sidecar container. `${cgc_data_root}/<project>/` is intentionally preserved so a later `provision.sh` re-attaches to the same DB without reindexing.

This is the only supported lifecycle-coupling between sandbox and sidecar. `workgroup down` does not touch either.

### `workgroup/etc/postinstall.sh` (runs inside the sandbox, once at first boot + on demand)

Lives under `workgroup/` rather than `sbx/` because it is the guest-side companion to the host-side `sbx/` scripts and is delivered into the sandbox through the `<repo>/workgroup` workspace mount. Invoked by its real host path (not `/opt/workgroup/...`) on first run because the `/opt/workgroup` symlink does not exist until step 0 below runs.

Inputs (passed via `sbx exec -e`): `WORK_SRC`, `BRIDGE_SRC`, `WORKGROUP_SRC` — the real host paths that `provision.sh` asked `sbx create shell` to mount.

Responsibilities:

0. **Materialize the guest-path contract.** Create `/work`, `/bridge`, `/opt/workgroup` as symlinks to `WORK_SRC`, `BRIDGE_SRC`, `WORKGROUP_SRC` respectively. Refuse to clobber non-symlink entries at those paths. Idempotent.
1. Detect package manager (Alpine/Debian/Ubuntu likely). Install: `tmux`, `git`, `inotify-tools`, `yq`, `jq`, `flock` (via `util-linux`), `curl`, `ca-certificates`. **No docker inside the sandbox** — the MCP stack runs on the host.
2. Install Claude Code (follow the official install instructions for the sandbox's distro).
3. Symlink `/opt/workgroup/bin/*` onto PATH (into `/usr/local/bin`): `workgroup`, `bridge-send`, `bridge-recv`, `bridge-peek`, `bridge-watch`, `bridge-init`. Empty-bin is a graceful no-op until Phases 03/04 populate it.
4. Ensure `/work` and `/bridge` are present and writable.
5. Sanity-check sidecar reachability: `curl -sS http://127.0.0.1:8811/mcp -o /dev/null` (or `/health` as a fallback probe) must succeed (proves the `sbx ports --publish <host-port>:8811` forwarding lands on the project's sidecar). Fail postinstall with a clear message if not.
6. Print a summary: package versions, mount listing, gateway reachability, and the one-time `claude mcp add` command the user should run next.

Idempotent: every step is guarded so re-running just reports "already installed" for done work.

### `sbx/README.md`

Short, host-facing: prerequisites, `./sbx/provision.sh` usage, how to tear down (`sbx delete <name>`), where logs live, and a pointer to `plans/00-overview.md` for conceptual context.

## Inputs

- Host has Docker Sandboxes (`sbx` v0.24+) installed, user is in the `kvm` group, and `sbx login` has been run once.
- Host has `~/.config/sbx-workgroup/machine.yaml` populated (Phase 02 contract).
- Host has the project source tree at `${projects_root}/<project>`.
- Phase 02's sidecar primitives are present: `sidecar-up.sh`, `sidecar-down.sh`, `build.sh`, and the `sbx-cgc-sidecar:local` image is buildable.

## Outputs / contracts published

- A sandbox reachable via `sbx run <name>`, with `sbx ports --publish 127.0.0.1:<host-port>:8811` forwarding the project's sidecar into the guest.
- Inside the sandbox:
  - `/work`, `/bridge`, `/opt/workgroup` exist as symlinks to the real host paths (mounts live at `${projects_root}/<project>`, `~/sbx-bridge`, `<repo>/workgroup` respectively, since `sbx` mounts host paths at the same path inside the guest).
  - `workgroup`, `bridge-*` commands on PATH (Phase 01 installs the symlinks; the actual binaries come from Phases 03 and 04).
  - `http://127.0.0.1:8811/mcp` is reachable (proves host↔sandbox wiring lands on the sidecar).
- `sbx/teardown.sh` is the canonical sandbox+sidecar removal path.
- `sbx/README.md` documents the recreation path.

## Verification

1. `./sbx/provision.sh <project>` exits 0; `sbx ls` shows the new sandbox in running state; `docker ps` shows `cgc-sidecar-<project>` running.
2. `sbx exec <name> sh -c 'ls -ld /work /bridge /opt/workgroup'` shows all three present (as symlinks).
3. `sbx exec <name> sh -c 'curl -sS http://127.0.0.1:8811/mcp -o /dev/null && echo ok'` prints `ok`.
4. `sbx exec <name> sh -c 'command -v workgroup && command -v bridge-send'` — deferred until Phases 03/04 populate `workgroup/bin/`.
5. Re-running `./sbx/provision.sh <project>` exits 0 and prints "already provisioned".
6. `./sbx/teardown.sh <project>` removes the sandbox and stops the sidecar; `${cgc_data_root}/<project>/` is still intact on disk.
7. **Deferred from Phase 02, step 9 — end-to-end host↔sandbox↔sidecar reachability.** From inside a provisioned sandbox (`sbx run <name>`): `curl -sS http://127.0.0.1:8811/mcp` succeeds against the project's sidecar, `claude mcp add --transport http cgc http://127.0.0.1:8811/mcp` followed by `claude mcp list` shows `cgc` connected, and a cgc tool call scoped to `/work` returns a real response. This closes the Phase 02 verification matrix — it could not run during Phase 02 because no sandbox existed yet.

## Open items

- Default sandbox memory. Starting: `8g` via `sbx create --memory 8g`. `sbx` does not expose `--cpus` or `--disk`; CPU is a fraction of host and disk is managed by the sandbox runtime. Revisit memory after first real workload — can likely drop now that cgc runs on the host instead of in the sandbox.
- Whether to pin the sandbox base image via `sbx create --template`. Starting assumption: whatever the `shell` agent's default image is, as long as it has a supported Claude Code install path. If it doesn't, pass `--template` to a Debian-based alternative.
- Whether `postinstall.sh` should also run `claude mcp add --transport http cgc ...` on behalf of the user. Starting: no (per-user Claude config).
- Default sandbox network policy. `sbx login` requires the user to pick a default policy (Open / Balanced / Locked Down). Package install + Claude Code install + `claude mcp add` all need outbound HTTPS to a small set of hosts — if the user picked Locked Down, `provision.sh` may need to allowlist those hosts via `sbx policy` before `postinstall.sh` runs.
