# Phase 01 checkpoint — sbx microVM provisioning

Status: **implemented and verified end-to-end** on Arch Linux, `sbx` v0.24.2, against the local `sbx` project itself (repo acting as its own workspace).

Date: 2026-04-12.

## What was built

| File | Role |
|---|---|
| `sbx/provision.sh` | Host-side: ensures sidecar, `sbx create shell`, `sbx policy allow`, `sbx exec` postinstall. Idempotent. |
| `sbx/teardown.sh` | Host-side: `sbx stop` + `sbx rm`, then `sidecar-down.sh`. Preserves `${cgc_data_root}/<project>/`. |
| `sbx/README.md` | Host-facing usage doc. |
| `workgroup/etc/postinstall.sh` | In-sandbox: materializes guest-path contract as symlinks, installs packages, probes sidecar, persists port. |
| `workgroup/bin/.gitkeep` | Placeholder; Phase 03/04 will populate this. |

Plan docs updated to match reality: `plans/00-overview.md`, `plans/01-vm-provisioning.md`.

## What the actual `sbx` CLI forced us to change

The original Phase 01 plan assumed a Docker-like CLI surface. `sbx` v0.24.2 diverges in several load-bearing ways. Every divergence below was either accommodated in code, reflected in the Phase 00 contract, or flagged as deferred.

### 1. Mounts are host-path-shaped, not guest-path-shaped

`sbx create shell PATH [PATH...]` mounts each PATH **at the same path inside the sandbox** — no way to pick the guest path, only `:ro` suffix.

**Consequence:** the Phase 00 `/work` `/bridge` `/opt/workgroup` contract cannot be a mount-time invariant.

**Fix:** `postinstall.sh` materializes the contract as symlinks on first boot. `provision.sh` passes the real host paths through via `sbx exec -e WORK_SRC=... -e BRIDGE_SRC=... -e WORKGROUP_SRC=...`. Downstream phases see the stable `/work /bridge /opt/workgroup` namespace as before.

Chicken-and-egg note: on first run `/opt/workgroup` does not yet exist, so `provision.sh` invokes `postinstall.sh` by its real host path (`<repo>/workgroup/etc/postinstall.sh`), not via `/opt/workgroup/etc/...`.

### 2. `sbx ports --publish` is inbound — unusable for our case

`sbx ports --publish HOST:SANDBOX` is Docker-like inbound publishing (host → sandbox). We need the opposite: the sandbox reaching the sidecar on the host.

**Discovery:** the sandbox has `HTTP_PROXY=http://gateway.docker.internal:3128` with `NO_PROXY=localhost,127.0.0.1,::1`. All outbound HTTP is routed through a host-side proxy that enforces `sbx policy` rules. `host.docker.internal` resolves inside the sandbox (fe80::1) but the proxy canonicalizes it to `localhost:<port>` for policy matching.

**Fix:** drop `sbx ports` entirely; `provision.sh` runs `sbx policy allow network localhost:<port>` instead (idempotent — checks `sbx policy ls` first). In-sandbox endpoint becomes `http://host.docker.internal:<hashed-port>/mcp` — **not** `127.0.0.1:8811`. The hashed port is passed in as `$SIDECAR_PORT` and persisted at `/etc/workgroup/sidecar-port` so Phase 04 can build the `claude mcp add` URL.

### 3. Flag surface is narrower than assumed

`sbx create` exposes `--memory`, `--name`, `--template`, `--branch`. No `--cpus`, no `--disk`. Dropped from `provision.sh`; `plans/01-vm-provisioning.md` open items updated.

### 4. Command naming

- `sbx rm` not `sbx delete` (teardown fixed).
- No `sbx attach` — attach via `sbx run <sandbox>` (which also creates if missing; we use it only for attach, and use `sbx exec` for scripted commands).
- `sbx version` subcommand, not `--version`.
- `sbx ls -q` exists — used for existence check.

### 5. Agent choice

`sbx create` always takes an *agent* (claude, codex, copilot, shell, …). We use `shell` because Phase 04 will run tmux + multiple claude panes managed by our own CLI; letting `sbx` auto-launch `claude` would collide with that.

### 6. Boot-time apt race

The `sbx shell-docker` template runs its own apt on first boot. Our `postinstall.sh` hit `E: Could not get lock /var/lib/apt/lists/lock`. Added `wait_for_apt_lock()` (uses `fuser` with a 180s deadline).

### 7. Balanced network policy is restrictive

User-selected Balanced policy blocks by default. Our `provision.sh` needs one allow rule (`localhost:<sidecar-port>`) for sidecar reachability. apt-sources (`archive.ubuntu.com`, `security.ubuntu.com`) and some GitHub subdomains needed allow rules too — added manually during verification, **not yet codified in `provision.sh`** (see "Remaining work" below).

## Guest-path contract — final shape

Inside the sandbox after postinstall:

```
/work          -> /home/<user>/My_Projects/<project>           (symlink, rw)
/bridge        -> /home/<user>/sbx-bridge                      (symlink, rw)
/opt/workgroup -> /home/<user>/My_Projects/sbx/workgroup       (symlink, ro mount)
/etc/workgroup/sidecar-port                                    (plain file: "8560\n")
```

Sidecar endpoint: `http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/mcp`.

## Verification results

Run against project `sbx` with host config `~/.config/sbx-workgroup/machine.yaml`:

```
projects_root: /home/aleksandr/My_Projects
cgc_data_root: /home/aleksandr/sbx-cgc-data
```

Sidecar port for this project: `8560` (`8000 + crc32("sbx") mod 1000`).

| Check (from `plans/01-vm-provisioning.md`) | Result |
|---|---|
| 1. `sbx ls` shows sandbox running + `docker ps` shows `cgc-sidecar-sbx` | ✅ |
| 2. `sbx exec sbx-sbx ls -ld /work /bridge /opt/workgroup` shows 3 symlinks | ✅ |
| 3. `curl http://host.docker.internal:$SIDECAR_PORT/health` from inside → `{"ok":true,"project":"sbx","sessions":0}` | ✅ |
| 4. `command -v workgroup && command -v bridge-send` | ⏸ deferred — `workgroup/bin/` empty until Phase 03/04 |
| 5. Re-run `provision.sh` — detects existing sandbox, re-runs postinstall, exits 0 | ✅ (runs 2 and 3 of the session) |
| 6. `teardown.sh` — `sbx rm` + `sidecar-down.sh`; `${cgc_data_root}/sbx/` preserved | ✅ |
| 7. End-to-end `claude mcp add` → `claude mcp list` → cgc tool call | ⏸ deferred — claude install blocked by Balanced policy (see below) |

Cold-start run (sandbox and sidecar both absent) also verified.

Logs captured: `.tmp/provision-run1.log` (first attempt, failed on `sbx ports`), `.tmp/provision-run2.log` (idempotent re-run after fix), `.tmp/provision-run3.log` (post-allowlist), `.tmp/provision-cold.log` (apt-lock race), `.tmp/provision-cold2.log` (final clean cold-start).

## Remaining work (not blocking Phase 01 handoff)

1. ~~**Codify the full allow-list in `provision.sh`.**~~ Done 2026-04-13
   during Phase 06 setup. `sbx/provision.sh:ensure_policy` now idempotently
   adds all required rules via an `ensure_policy_host` helper. The list
   includes the original apt/GitHub rules (`archive.ubuntu.com:80`,
   `security.ubuntu.com:80`, `objects.githubusercontent.com:443`,
   `release-assets.githubusercontent.com:443`) plus the claude installer
   + OAuth hosts that surfaced during Phase 04 bring-up (`claude.ai:443`,
   `downloads.claude.ai:443`, `console.anthropic.com:443`,
   `login.anthropic.com:443`, `auth.anthropic.com:443`, `claude.com:443`).
   Covered by `default-*` bundles: `ports.ubuntu.com`, `github.com`,
   `api.anthropic.com`, `statsig.anthropic.com`, `platform.claude.com`.

2. **Claude install under Balanced policy.** `curl https://claude.ai/install.sh | sh` returns 403 because `claude.ai` is not in the default allowlist. `postinstall.sh` now logs a soft warning with the exact remediation: `sbx policy allow network claude.ai:443`. It may also need transitive hosts (CDN / release assets) — untested. Check 7 of the verification matrix depends on this.

3. **Global vs per-project policies.** `sbx policy` rules apply to all sandboxes on the host. For our use case (one project = one sandbox, and different projects have different sidecar ports), this is fine — each project's provision adds its own `localhost:<port>` rule. Teardown currently **does not** remove the rule; re-provision finds it idempotent. If rule accumulation becomes a concern, add `sbx policy rm` to `teardown.sh`.

4. **`workgroup/bin/` population.** Owned by Phases 03/04. `postinstall.sh` handles an empty directory gracefully (symlink loop is a no-op).

5. **Memory default.** Currently `--memory 8g`. Revisit after first real workload; the cgc process runs on the host now, so the sandbox itself needs less.

## Files touched this checkpoint

Modified:
- `plans/00-overview.md` — contract updated for sidecar reachability and MCP endpoint.
- `plans/01-vm-provisioning.md` — all three subsection headers rewritten against real CLI.

Created:
- `sbx/provision.sh`
- `sbx/teardown.sh`
- `sbx/README.md`
- `workgroup/etc/postinstall.sh`
- `workgroup/bin/.gitkeep`
- `plans/checkpoints/phase-01.md` (this file)

Environment changes on host:
- `~/.docker/sbx/` — Docker Sandboxes v0.24.2 user-local install (via `DockerSandboxes-linux.tar.gz` + its bundled `install.sh`).
- `~/.zshrc` — appended `export PATH="$HOME/.docker/sbx/bin:$PATH"`.
- `kvm` group membership added to `$USER` (via `sudo usermod -aG kvm`); current shell uses `newgrp kvm`.
- `sbx login` — interactive, performed by user. Default network policy: **Balanced**.
- `sbx policy` rules added during verification (persist until manually removed; see "Remaining work" item 1).
