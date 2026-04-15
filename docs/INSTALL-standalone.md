# Standalone install (Linux + macOS)

Run a `workgroup` of Claude Code agents on any Linux or macOS host with no
microVM, no Docker, and no sidecar. The bridge is plain files; the agents
are just `claude` processes inside tmux panes.

## 1. Prerequisites

```sh
# macOS
brew install tmux git jq yq
# (claude-code: install per Anthropic instructions)

# Linux (Debian/Ubuntu)
sudo apt install -y tmux git jq
# yq: install Mike Farah's go-yq, NOT the python yq
sudo wget -O /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

Optional:

- `inotify-tools` (Linux) — needed for the `bridge-watch` pane. macOS users
  can skip; the watch window simply won't run.
- `flock` — auto-detected. Standard on Linux; absent on macOS, where the CLI
  falls back to an `mkdir`-based lock with the same semantics.

## 2. Clone and run

```sh
git clone <this-repo> ~/src/workgroup
cd ~/src/workgroup
./workgroup/bin/workgroup doctor
```

`doctor` prints the resolved paths and dependency status. Add
`workgroup/bin` to your `$PATH` (or symlink `bin/workgroup` into
`/usr/local/bin`) so you can call `workgroup` directly.

## 3. Optional config

Defaults are good; override only if you want non-XDG paths or want every
workgroup to register an MCP server.

```sh
mkdir -p ~/.config/workgroup
cat > ~/.config/workgroup/config.yaml <<'EOF'
# All keys optional. Defaults shown.
# workgroup_home: ~/.local/share/workgroup
# bridge_root:    ~/.local/share/workgroup/bridges
# worktree_root:  ~/.local/share/workgroup/worktrees
# projects_root:  ~/src

# Optional: register MCP servers per workgroup at `up` time.
# Failures here are warnings, not fatal.
# mcp:
#   - name: cgc
#     transport: http
#     url: http://127.0.0.1:8765/mcp
EOF
```

## 4. First workgroup

Write a manifest. The simplest form points at an existing checkout:

```yaml
# ~/projects/my-app/wg-feature.yaml
name: feature-x
worktree:
  source: ~/projects/my-app   # absolute or ~-prefixed path to the source repo
  branch: wg/feature-x
  base: main
agents:
  - id: planner
    role: planner
  - id: reviewer
    role: reviewer
  - id: executor
    role: executor
edges:
  - planner -> reviewer
  - reviewer -> planner
  - reviewer -> executor
  - executor -> reviewer
layout: tiled
```

`worktree.source` resolution order (first hit wins):

1. `--source PATH` flag on `workgroup up`
2. `worktree.source:` in the manifest
3. `$WORK_ROOT` env var
4. Manifest dir, if it's inside a git repo
5. Current dir, if it's inside a git repo
6. `$WORKGROUP_PROJECTS_ROOT/<name>` (from config or env)

Then:

```sh
workgroup up ~/projects/my-app/wg-feature.yaml
workgroup attach feature-x
```

The worktree lands under `~/.local/share/workgroup/worktrees/feature-x/`
(outside your source repo so cgc-style indexers don't see a duplicate).
Bridge state lives under `~/.local/share/workgroup/bridges/feature-x/`.

To stop:

```sh
workgroup down feature-x          # archives bridge, keeps worktree
workgroup down feature-x --force  # also removes worktree if clean
```

## 5. Tests

```sh
./workgroup/test-bridge.sh        # bridge protocol
./workgroup/test-workgroup.sh     # legacy end-to-end (still uses preset env)
./workgroup/test-standalone.sh    # standalone code path (XDG, manifest source)
```

All three pass on host without any sandbox.

## What's different from sbx mode

- No `/work`, `/bridge`, `/opt/workgroup`, `/etc/workgroup/*` paths.
  Everything resolves under `$WORKGROUP_HOME` (default
  `$XDG_DATA_HOME/workgroup`).
- No sidecar reachability check. MCP servers are optional and registered
  from `config.yaml`'s `mcp:` block; failures warn instead of aborting.
- `workgroup doctor` is the smoke-test entry point on a fresh box.
- The sbx flow still works — it sets the same env vars and the dispatcher
  honors them.
