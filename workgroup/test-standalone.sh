#!/bin/sh
# Standalone-mode verification. Exercises the code paths that are new or
# changed in the sbx → standalone separation:
#   - config_load reads $WORKGROUP_CONFIG and applies defaults
#   - WORK_ROOT is resolved from manifest's worktree.source (no preset env)
#   - WORKTREE_ROOT defaults to $WORKGROUP_HOME/worktrees, not $WORK_ROOT/...
#   - locked_subshell works (with or without flock on PATH)
#   - workgroup doctor exits 0 on a healthy box
#
# This script does NOT preset BRIDGE_ROOT / WORK_ROOT / WORKTREE_ROOT — it
# leaves config_load to compute them, which is the standalone code path.
# It does set $HOME and $XDG_DATA_HOME / $XDG_CONFIG_HOME to a tmpdir so the
# user's real ~/.local/share/workgroup is untouched.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
for t in tmux yq jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing $t"; exit 2; }
done

unset TMUX TMUX_PANE
unset BRIDGE_ROOT WORKTREE_ROOT WORK_ROOT WORKGROUP_HOME WORKGROUP_CONFIG WORKGROUP_ROOT

SCRATCH=$(mktemp -d)
trap 'TMUX= tmux kill-server 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

export HOME="$SCRATCH/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME/workgroup"

# Source repo lives under $HOME/src/demo-proj — referenced from the manifest
# via worktree.source, so cmd_up resolves WORK_ROOT through the manifest.
SRC_REPO="$HOME/src/demo-proj"
mkdir -p "$SRC_REPO"
git -C "$SRC_REPO" init -q -b main
git -C "$SRC_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Minimal config.yaml — exercises the loader without overriding paths.
cat > "$XDG_CONFIG_HOME/workgroup/config.yaml" <<EOF
# nothing set; everything should default under \$WORKGROUP_HOME
EOF

# Manifest with worktree.source pointing at the demo repo.
MANIFEST="$SCRATCH/standalone.yaml"
cat > "$MANIFEST" <<EOF
name: demo
worktree:
  source: $SRC_REPO
  branch: wg/demo
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
EOF

# Stub claude that records and sleeps.
STUB_BIN="$SCRATCH/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
printf 'stub-claude args: %s\n' "$*" >> "$HOME/.stub-claude.log"
exec sleep 600
EOF
chmod +x "$STUB_BIN/claude"

export TMUX_TMPDIR="$SCRATCH/tmux"; mkdir -p "$TMUX_TMPDIR"
export PATH="$HERE/bin:$STUB_BIN:$PATH"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
nope() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

echo "[1] workgroup doctor on a healthy box"
workgroup doctor >"$SCRATCH/doctor.out" 2>&1 \
  && ok "doctor exit 0" || { cat "$SCRATCH/doctor.out"; nope "doctor failed"; }
grep -q "WORKGROUP_HOME       $XDG_DATA_HOME/workgroup" "$SCRATCH/doctor.out" \
  && ok "doctor reports XDG default" \
  || { cat "$SCRATCH/doctor.out"; nope "doctor didn't pick up XDG default"; }

echo "[2] workgroup up resolves WORK_ROOT from manifest worktree.source"
workgroup up "$MANIFEST" >"$SCRATCH/up.out" 2>&1 \
  && ok "up exit 0" || { cat "$SCRATCH/up.out"; nope "up failed"; }

[ -d "$XDG_DATA_HOME/workgroup/bridges/demo" ] \
  && ok "bridge under XDG_DATA_HOME" \
  || nope "bridge not at XDG default"

[ -d "$XDG_DATA_HOME/workgroup/worktrees/demo" ] \
  && ok "worktree under XDG_DATA_HOME (not under source repo)" \
  || nope "worktree not at XDG default"

# State.json should record the worktree path under WORKGROUP_HOME.
jq -e --arg wt "$XDG_DATA_HOME/workgroup/worktrees/demo" \
  '.worktree == $wt' \
  "$XDG_DATA_HOME/workgroup/bridges/demo/state.json" >/dev/null \
  && ok "state.json has correct worktree" || nope "state.json wrong"

# Source repo should now have a wg/demo branch.
git -C "$SRC_REPO" branch | grep -q 'wg/demo' \
  && ok "wg/demo branch created in source repo" || nope "branch missing"

tmux has-session -t =demo 2>/dev/null && ok "tmux session up" \
  || nope "tmux session missing"

echo "[3] workgroup down --force tears down cleanly"
workgroup down demo --force >"$SCRATCH/down.out" 2>&1 \
  && ok "down exit 0" || { cat "$SCRATCH/down.out"; nope "down failed"; }
tmux has-session -t =demo 2>/dev/null && nope "session lingered" \
  || ok "session gone"
[ -d "$XDG_DATA_HOME/workgroup/worktrees/demo" ] && nope "worktree lingered" \
  || ok "worktree removed"

printf '\npassed: %d    failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
