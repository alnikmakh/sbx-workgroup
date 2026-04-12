# Phase 01 — sbx microVM provisioning

## Purpose

Go from a fresh host to a running sbx microVM that has every system dependency later phases need. Nothing workgroup-specific lives here — this phase delivers a clean environment and hands off to Phases 02/03/04 via the mount and PATH contracts defined in `00-overview.md`.

## Scope

### `sbx/provision.sh` (runs on the host)

Usage: `./sbx/provision.sh <project> [--name <vm-name>]`. `<project>` is required and must correspond to a directory under `${projects_root}/<project>`.

Responsibilities:

1. Verify `sbx` CLI (Docker sbx) is installed; if not, print install pointer and exit non-zero.
2. Load `~/.config/sbx-workgroup/machine.yaml`; error with a precise message if missing.
3. Resolve the project source path to `${projects_root}/<project>`. Verify it exists.
4. Ensure `~/sbx-bridge` exists; create if missing.
5. **Ensure the project's sidecar is up** — `port=$(sbx/host-mcp/sidecar-up.sh <project>)`. `sidecar-up.sh` is idempotent; on first call it builds the sidecar image if missing, starts the container, and waits for `/mcp` to answer. Capture the printed host port for step 7.
6. Check whether a VM with the chosen name already exists (`sbx ls`). If yes, print a note and exit 0; the user runs `sbx attach <name>` manually.
7. `sbx create` the VM with:
   - Name (default: `sbx-<project>`; override via `--name`).
   - vCPUs / RAM (default: 4 vCPU, 8 GB; override via flags).
   - `--mount ${projects_root}/<project>:/work`.
   - `--mount ~/sbx-bridge:/bridge`.
   - `--mount <repo>/workgroup:/opt/workgroup:ro`.
   - `--publish ${port}:8811` — forwards the sidecar's hashed host port to the VM's fixed guest port.
8. On first-boot success: `sbx run <name> -- /opt/workgroup/etc/postinstall.sh`.
9. Print the `sbx attach <name>` command the user should use next and the one-time `claude mcp add` line.

Idempotency: re-running `provision.sh` on an already-provisioned VM is safe — it detects the VM, skips `sbx create`, re-runs `postinstall.sh` (idempotent), and exits 0. The sidecar check at step 5 is always run and is itself idempotent.

### `sbx/teardown.sh` (runs on the host)

Usage: `./sbx/teardown.sh <project> [--name <vm-name>]`.

1. `sbx delete <name>` (no-op if absent).
2. `sbx/host-mcp/sidecar-down.sh <project>` — stops and removes the sidecar container. `${cgc_data_root}/<project>/` is intentionally preserved so a later `provision.sh` re-attaches to the same DB without reindexing.

This is the only supported lifecycle-coupling between VM and sidecar. `workgroup down` does not touch either.

### `sbx/postinstall.sh` (runs inside the VM, once at first boot + on demand)

Responsibilities:

1. Detect package manager (Alpine/Debian/Ubuntu likely). Install: `tmux`, `git`, `inotify-tools`, `yq`, `jq`, `flock`, `curl`, `ca-certificates`. **No docker inside the VM** — the MCP stack runs on the host.
2. Install Claude Code (follow the official install instructions for the VM's distro).
3. Copy `/opt/workgroup/bin/*` onto PATH (symlinks in `/usr/local/bin`): `workgroup`, `bridge-send`, `bridge-recv`, `bridge-peek`, `bridge-watch`, `bridge-init`.
4. Ensure `/work` and `/bridge` are present and writable.
5. Sanity-check sidecar reachability: `curl -sS http://127.0.0.1:8811/mcp -o /dev/null` must succeed (proves the `--publish <host-port>:8811` forwarding lands on the project's sidecar). Fail postinstall with a clear message if not.
6. Print a summary: package versions, mount listing, gateway reachability, `workgroup --help` output, and the one-time `claude mcp add` command the user should run next.

Idempotent: every step is guarded so re-running just reports "already installed" for done work.

### `sbx/README.md`

Short, host-facing: prerequisites, `./sbx/provision.sh` usage, how to tear down (`sbx delete <name>`), where logs live, and a pointer to `plans/00-overview.md` for conceptual context.

## Inputs

- Host has Docker `sbx` installed.
- Host has `~/.config/sbx-workgroup/machine.yaml` populated (Phase 02 contract).
- Host has the project source tree at `${projects_root}/<project>`.
- Phase 02's sidecar primitives are present: `sidecar-up.sh`, `sidecar-down.sh`, `build.sh`, and the `sbx-cgc-sidecar:local` image is buildable.

## Outputs / contracts published

- A VM reachable via `sbx attach <name>`, with `--publish <host-port>:8811` forwarding the project's sidecar into the guest.
- Inside the VM:
  - `/work`, `/bridge`, `/opt/workgroup` exist with correct permissions.
  - `workgroup`, `bridge-*` commands on PATH (Phase 01 installs the symlinks; the actual binaries come from Phases 03 and 04).
  - `http://127.0.0.1:8811/mcp` is reachable (proves host↔VM wiring lands on the sidecar).
- `sbx/teardown.sh` is the canonical VM+sidecar removal path.
- `sbx/README.md` documents the recreation path.

## Verification

1. `./sbx/provision.sh <project>` exits 0; `sbx ls` shows the new VM in running state; `docker ps` shows `cgc-sidecar-<project>` running.
2. `sbx run <name> -- sh -c 'ls -ld /work /bridge /opt/workgroup'` shows all three present.
3. `sbx run <name> -- sh -c 'curl -sS http://127.0.0.1:8811/mcp -o /dev/null && echo ok'` prints `ok`.
4. `sbx run <name> -- sh -c 'command -v workgroup && command -v bridge-send'` resolves both.
5. Re-running `./sbx/provision.sh <project>` exits 0 and prints "already provisioned".
6. `./sbx/teardown.sh <project>` removes the VM and stops the sidecar; `${cgc_data_root}/<project>/` is still intact on disk.
7. **Deferred from Phase 02, step 9 — end-to-end host↔VM↔sidecar reachability.** From inside a provisioned VM (`sbx attach <name>`): `curl -sS http://127.0.0.1:8811/mcp` succeeds against the project's sidecar, `claude mcp add --transport http cgc http://127.0.0.1:8811/mcp` followed by `claude mcp list` shows `cgc` connected, and a cgc tool call scoped to `/work` returns a real response. This closes the Phase 02 verification matrix — it could not run during Phase 02 because no VM existed yet.

## Open items

- Exact `sbx create --mount` and `--publish` syntax — will be resolved against `sbx --help` during implementation. The host port value comes from `sidecar-up.sh`'s stdout; guest port is always `8811`. If `--publish` is only available as a separate `sbx ports` subcommand after create, `provision.sh` applies it after create instead.
- Whether to pin the VM distro. Starting assumption: whatever Docker sbx's default is, as long as it has a supported Claude Code install path. If it doesn't, switch to Debian 12.
- Default VM resource profile. Starting: 4 vCPU, 8 GB RAM, 20 GB disk. Revisit after first real workload. RAM can likely drop now that cgc runs on the host instead of in the VM.
- Whether `postinstall.sh` should also run `claude mcp add --transport http cgc ...` on behalf of the user. Starting: no (per-user Claude config).
