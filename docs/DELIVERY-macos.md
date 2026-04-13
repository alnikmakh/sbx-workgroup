# Moving sbx-workgroup to a new machine (macOS)

This is the bring-up recipe for taking a fresh Mac from zero to a running
`workgroup up`. The project itself is portable: nothing in the repo encodes
a Linux-only path, and all the host state lives in `~/.config/` and `~/sbx-*/`
directories you can back up and restore.

The same recipe works for a second Linux machine — skip the macOS-specific
notes in §1 and §6.

## 0. What moves, what doesn't

**Moves with you (back up these):**

- The repo itself (this checkout).
- `~/.config/sbx-workgroup/machine.yaml` — paths + optional port overrides.
- `~/sbx-cgc-data/` — per-project cgc graph databases. Large but
  regeneratable; copy if you want instant reindexing on the new machine,
  skip if you're happy to reindex from scratch on first query.
- `~/sbx-bridge/` — past workgroup message history (plans, reports, notes).
  Small; copy if you want the audit trail.
- `~/sbx-worktrees/` — in-progress workgroup worktrees. Only matters if you
  have uncommitted work in a live workgroup at move time. Prefer to
  `workgroup down --force` everything before moving.

**Rebuilds on the target:**

- The sidecar docker image (`sbx-cgc-sidecar:local`) — built by
  `provision.sh` on first run.
- The sbx microVMs — recreated by `provision.sh`. State inside the VM
  is disposable by design; everything important is on host mounts.

**Does not move:**

- `sbx` CLI installation itself.
- Docker Desktop / Docker Engine install.
- Your Claude Code OAuth login. You'll `claude /login` inside each new
  sandbox once.

## 1. Install the host toolchain (macOS)

```sh
# Homebrew prerequisites.
brew install yq jq python3 git bash

# Docker Desktop provides the engine + daemon.
brew install --cask docker
open -a Docker   # first launch, wait for the whale to settle

# Docker Sandboxes CLI. At time of writing this is the experimental sbx
# CLI shipped alongside Docker Desktop; see
# https://www.docker.com/products/docker-sandbox/ for the current install
# instructions (the exact install channel changes).
# Verify:
sbx --version   # must be 0.24 or newer
```

macOS-specific gotchas:

- **Filesystem case sensitivity.** Default macOS volumes are case-*insensitive*.
  The repo doesn't rely on case-sensitive paths, but if you have a project
  that does, keep it on a case-sensitive APFS volume.
- **VirtioFS vs osxfs.** Docker Desktop's file sharing defaults have
  changed between versions. Prefer VirtioFS (Settings → General →
  "Use Virtualization framework" + "VirtioFS"). The bind mounts
  `provision.sh` asks for are hot-path for cgc indexing and claude file
  reads; VirtioFS is ~10× faster than the legacy osxfs path.
- **`host.docker.internal` works the same as on Linux.** The gateway name
  is identical; the policy allow rules `provision.sh` installs work
  unmodified.
- **Bash version.** macOS ships bash 3.2 by default; `provision.sh` uses
  bash ≥ 4 features. `brew install bash` puts a modern bash at
  `/opt/homebrew/bin/bash`; the script's shebang is `#!/usr/bin/env bash`
  so PATH order is what matters. Make sure `brew --prefix`/bin is ahead
  of `/bin` in your shell's PATH.
- **inotify-tools** is not needed on the host — it runs inside the Linux
  sandbox, where postinstall installs it. The host is fine without.

## 2. Restore host config

On the **source** machine:

```sh
tar czf sbx-workgroup-backup.tar.gz \
    ~/.config/sbx-workgroup \
    ~/sbx-cgc-data \
    ~/sbx-bridge
# Skip ~/sbx-worktrees unless you have in-flight work.
```

On the **target** machine:

```sh
tar xzf sbx-workgroup-backup.tar.gz -C ~/
```

Then **edit `~/.config/sbx-workgroup/machine.yaml`** if the new machine's
`projects_root` or `cgc_data_root` is at a different absolute path:

```yaml
# Example for a Mac with projects under ~/src instead of ~/My_Projects.
projects_root: /Users/you/src
cgc_data_root: /Users/you/sbx-cgc-data
```

Paths must be absolute. The config file is the only place machine-specific
paths are allowed.

## 3. Clone the repo and the projects it manages

```sh
# The tool itself.
mkdir -p ~/src && cd ~/src
git clone <your-fork-or-origin>/sbx sbx-workgroup
cd sbx-workgroup

# Whichever projects you drive with it.
cd "$(yq -r .projects_root ~/.config/sbx-workgroup/machine.yaml)"
git clone <origin>/tg-digest tg-digest
# …etc for other projects.
```

The tool's checkout location doesn't matter — `provision.sh` resolves paths
relative to its own directory.

## 4. Provision each project

```sh
cd ~/src/sbx-workgroup
./sbx/provision.sh tg-digest
```

What happens on first run:

1. Builds the `sbx-cgc-sidecar:local` docker image. **This is the slow
   step on a new machine** — expect 2–5 minutes for the first build
   (FalkorDB + Python deps). Subsequent provisions are instant.
2. Starts the sidecar container, binds it to a hashed loopback port.
3. `sbx create shell` the microVM with mounts for project source, bridge
   directory, worktree root, and the repo's `workgroup/` payload.
4. Runs `sbx policy allow network …` for the sidecar port, archive mirrors,
   and the Anthropic/Claude OAuth endpoints.
5. Runs `workgroup/etc/postinstall.sh` inside the VM. This installs tmux,
   git, jq, yq, flock, inotify-tools, claude-code, sets `LANG=C.UTF-8`,
   and registers the cgc MCP server at user scope.

On success you'll see a summary ending with `claude mcp: registered at
user scope`. If cgc shows `FAILED`, see **§6 Troubleshooting**.

Re-running `provision.sh` on an existing VM is safe: it re-runs postinstall
(idempotent) and exits 0.

## 5. First attach + log Claude in

```sh
sbx run sbx-tg-digest
# You're inside the sandbox now.

# One-time OAuth login for Claude Code. This opens a device-code URL;
# paste it into your host browser. The allow rules provision.sh installed
# cover claude.ai, auth.anthropic.com, console.anthropic.com, etc.
claude /login

# Smoke test: spin up a workgroup.
workgroup up /opt/workgroup/examples/tg-digest-main.yaml
workgroup attach tg-digest-main
```

If you copied `~/sbx-cgc-data/` from the source machine, the first cgc
query should answer instantly — no reindex. Otherwise claude will reindex
`/work` on first query (takes seconds to minutes depending on repo size).

## 6. Troubleshooting the move

### `provision.sh` dies at `sidecar failed to come up`

Sidecar health check timed out. Usual causes:

- Docker Desktop not running — `open -a Docker` and wait.
- First-time image build didn't finish — run
  `./sbx/host-mcp/build.sh` manually to see the build log.
- Port collision — another service is on the hashed port. Add to
  `machine.yaml`:

  ```yaml
  port_overrides:
    tg-digest: 8850
  ```

### `postinstall` dies at `WORKTREE_SRC missing`

The sandbox was created on an older version of the tool, before the
worktree mount was added, and `provision.sh` is now trying to re-run
postinstall against a stale VM. Fix:

```sh
./sbx/teardown.sh tg-digest && ./sbx/provision.sh tg-digest
```

Teardown preserves cgc data, so reindex isn't triggered.

### `claude mcp list` shows cgc as `✗ Failed to connect`

Reachability check from inside the sandbox:

```sh
sbx run sbx-tg-digest
curl -fsS "http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/health"
```

Failure modes:

- `connection refused` → sidecar container is down; on the host
  `docker ps | grep cgc-sidecar` and `docker logs cgc-sidecar-<project>`.
- `403`/proxy error → `sbx policy allow network localhost:<port>` rule
  missing or wrong port. Re-run `./sbx/provision.sh <project>` to refresh
  policies.
- Times out → VirtioFS path is slow, or Docker Desktop networking is in
  a bad state. Restart Docker Desktop.

### cgc index is empty even though I copied `~/sbx-cgc-data/`

Two common causes:

- The copy landed under a different `cgc_data_root` than `machine.yaml`
  points at. They must match.
- The agent is telling cgc to index a path the sidecar can't see. The
  sidecar mounts `$projects_root/<project>` at `/work` — tell claude to
  index **`/work`**, not the host path. Worktrees are deliberately not
  mounted into the sidecar.

### tmux shows `_` instead of Unicode glyphs

Locale missing in the VM. This should be impossible on a fresh provision
(postinstall writes `LANG=C.UTF-8` to `/etc/environment`,
`/etc/profile.d/locale.sh`, and `/etc/bash.bashrc`) but if it happens:

```sh
./sbx/teardown.sh tg-digest && ./sbx/provision.sh tg-digest
```

### Docker Desktop eats the world

`sbx` microVMs and the sidecar container all run under Docker Desktop's
Linux VM. On a 16 GB Mac the default Docker Desktop memory allocation
(usually 4 GB) is tight for two microVMs + sidecars. Bump it to 8 GB in
Docker Desktop → Settings → Resources.

## 7. Optional: per-machine shell aliases

Not part of the tool, but useful on both Linux and macOS. Drop into
`~/.zshrc` or `~/.bashrc`:

```sh
# Enter a sandbox + jump straight to /work.
sbxx() {
    sbx run "sbx-$1"
}

# Provision + attach.
sbxup() {
    (cd ~/src/sbx-workgroup && ./sbx/provision.sh "$1") && sbx run "sbx-$1"
}
```

## 8. What's intentionally not in this doc

- **CI / remote build farms.** The sandbox is meant for one developer on
  one laptop. Multi-host deployment is out of scope for v1.
- **Windows.** `sbx` does not support Windows hosts at the time of
  writing. WSL2 probably works but is untested — if you try it, the
  Linux path above applies inside WSL.
- **Rosetta quirks on Apple Silicon.** The sidecar image is built for
  `linux/arm64` natively on M-series Macs; no Rosetta involved. If you
  pull a pre-built `amd64` image from a registry later, you'll pay the
  Rosetta translation cost on every cgc query.
