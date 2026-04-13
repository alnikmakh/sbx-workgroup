#!/bin/sh
# Phase 04 verification. Runs what can run outside a real sandbox:
#   - manifest parse + validate happy path
#   - each bad-*.yaml rejected with a precise error
#   - worktree resolver against a scratch git repo
#   - dry-run `workgroup up` using a stub `claude` and a scratch /work, /bridge,
#     /opt/workgroup
#   - `workgroup status` / `logs` / `down` against that session
# Load-bearing in-sandbox checks (role injection survives /clear, real sidecar
# reachability) remain deferred to Phase 04 bring-up inside sbx.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

# tmux + yq must exist locally; jq is already required by Phase 03.
for t in tmux yq jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing $t"; exit 2; }
done

SCRATCH=$(mktemp -d)
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

# Scratch layout mirroring the in-sandbox one.
export WORK_ROOT="$SCRATCH/work"
export BRIDGE_ROOT="$SCRATCH/bridge"
export WORKGROUP_ROOT="$HERE"      # points at this repo's workgroup/
mkdir -p "$WORK_ROOT" "$BRIDGE_ROOT"

# Seed a git repo at $WORK_ROOT with an initial commit on 'main'.
git -C "$WORK_ROOT" init -q -b main
git -C "$WORK_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Isolated tmux server so we don't touch the user's.
export TMUX_TMPDIR="$SCRATCH/tmux"; mkdir -p "$TMUX_TMPDIR"

# Stub `claude`: records args, sleeps so the pane stays alive.
STUB_BIN="$SCRATCH/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
printf 'stub-claude args: %s\n' "$*" >> "$HOME/.stub-claude.log"
exec sleep 600
EOF
chmod +x "$STUB_BIN/claude"
export HOME="$SCRATCH"
export PATH="$HERE/bin:$STUB_BIN:$PATH"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
nope() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '  SKIP %s\n' "$1"; }

# --- Manifest library tests ----------------------------------------------------

. "$HERE/lib/manifest.sh"

echo "[1] manifest_parse + validate on examples/feature-x.yaml"
if manifest_parse "$HERE/examples/feature-x.yaml" \
   && manifest_validate "$HERE/examples/feature-x.yaml" "$HERE/templates"; then
  ok "feature-x parses"
  [ "$WG_NAME" = feature-x ]                 && ok "name"      || nope "name=$WG_NAME"
  [ "$WG_BRANCH" = wg/feature-x ]            && ok "branch"    || nope "branch=$WG_BRANCH"
  [ "$WG_LAYOUT" = tiled ]                   && ok "layout"    || nope "layout=$WG_LAYOUT"
  [ "$WG_AGENTS" = planner,reviewer,executor ] && ok "agents" || nope "agents=$WG_AGENTS"
  [ "$WG_EDGES" = "planner->reviewer,reviewer->planner,reviewer->executor,executor->reviewer" ] \
    && ok "edges" || nope "edges=$WG_EDGES"
  [ "$(manifest_peers_out reviewer)" = planner,executor ] && ok "peers_out" \
    || nope "peers_out=$(manifest_peers_out reviewer)"
  [ "$(manifest_peers_in reviewer)" = planner,executor ] && ok "peers_in" \
    || nope "peers_in=$(manifest_peers_in reviewer)"
else
  nope "feature-x parse/validate failed"
fi

echo "[2] each bad-*.yaml is rejected"
for f in "$HERE"/examples/bad-*.yaml; do
  _name=$(basename "$f")
  (
    manifest_parse "$f" >/dev/null 2>&1 || exit 0  # parse may succeed; validate should fail
    manifest_validate "$f" "$HERE/templates" >/dev/null 2>&1
  ) && nope "$_name was accepted" || ok "$_name rejected"
done

# --- Worktree resolver ---------------------------------------------------------

echo "[3] worktree_resolve default mode"
. "$HERE/lib/worktree.sh"
WT=$(worktree_resolve demo default wg/demo '' '')
[ -d "$WT" ] && [ "$WT" = "$WORK_ROOT/worktrees/demo" ] \
  && ok "created $WT" || nope "worktree not at expected path: $WT"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = wg/demo ] \
  && ok "on branch wg/demo" || nope "wrong branch"

echo "[4] worktree_resolve explicit mode asserts validity"
worktree_resolve x explicit '' '' "$SCRATCH/nope" 2>/dev/null \
  && nope "nonexistent path accepted" || ok "nonexistent path rejected"

echo "[5] worktree_resolve no-worktree mode"
[ "$(worktree_resolve x none '' '' '' 2>/dev/null)" = "$WORK_ROOT" ] \
  && ok "none returns WORK_ROOT" || nope "none wrong"

# --- End-to-end workgroup up / status / logs / down ---------------------------

echo "[6] workgroup up examples/feature-x.yaml"
if workgroup up "$HERE/examples/feature-x.yaml" >"$SCRATCH/up.out" 2>&1; then
  ok "up exit 0"
else
  cat "$SCRATCH/up.out"
  nope "up failed"
fi

tmux -L "$(basename "$TMUX_TMPDIR")" ls >/dev/null 2>&1 || true
tmux has-session -t =feature-x 2>/dev/null && ok "tmux session exists" \
  || nope "tmux session missing"

_panes=$(tmux list-panes -t =feature-x:agents -F '#{pane_title}' | sort | tr '\n' , | sed 's/,$//')
[ "$_panes" = executor,planner,reviewer ] && ok "3 agent panes titled" \
  || nope "panes: $_panes"

if command -v inotifywait >/dev/null 2>&1; then
  tmux list-windows -t =feature-x -F '#{window_name}' | grep -q '^watch$' \
    && ok "watch window present" || nope "watch window missing"
else
  skip "watch window (inotifywait not installed — runs in sandbox)"
fi

[ -f "$BRIDGE_ROOT/feature-x/state.json" ] && ok "bridge state.json" \
  || nope "no state.json"

jq -e '.worktree != null and .branch == "wg/feature-x"' \
  "$BRIDGE_ROOT/feature-x/state.json" >/dev/null \
  && ok "state.json has worktree+branch" || nope "state.json incomplete"

for a in planner reviewer executor; do
  [ -f "$BRIDGE_ROOT/feature-x/roles/$a.md" ] && ok "role copied: $a" \
    || nope "role missing: $a"
done

echo "[7] re-running up on an existing session errors out"
workgroup up "$HERE/examples/feature-x.yaml" 2>/dev/null \
  && nope "duplicate up accepted" || ok "duplicate up rejected"

echo "[8] workgroup status feature-x"
workgroup status feature-x >"$SCRATCH/status.out" 2>&1 \
  && ok "status exit 0" || nope "status failed"
grep -q '^planner' "$SCRATCH/status.out" && ok "status lists planner" \
  || nope "status output: $(cat "$SCRATCH/status.out")"

echo "[9] workgroup logs feature-x planner"
# Give the stub a moment so the tmux buffer has something.
sleep 1
workgroup logs feature-x planner >"$SCRATCH/logs.out" 2>&1 \
  && ok "logs exit 0" || nope "logs failed"

echo "[10] workgroup ls"
workgroup ls >"$SCRATCH/ls.out" 2>&1 \
  && grep -q '^feature-x' "$SCRATCH/ls.out" \
  && ok "ls shows feature-x" || { cat "$SCRATCH/ls.out"; nope "ls missing"; }

echo "[11] workgroup down (no --force) archives bridge, keeps worktree"
workgroup down feature-x >"$SCRATCH/down.out" 2>&1 \
  && ok "down exit 0" || nope "down failed"
tmux has-session -t =feature-x 2>/dev/null && nope "session still present" \
  || ok "session gone"
[ -d "$BRIDGE_ROOT/feature-x" ] && nope "bridge dir not moved" \
  || ok "bridge dir moved"
ls "$BRIDGE_ROOT/_archive/" 2>/dev/null | grep -q '^feature-x-' \
  && ok "bridge archived under _archive" || nope "no archive entry"
[ -d "$WORK_ROOT/worktrees/feature-x" ] && ok "worktree preserved" \
  || nope "worktree gone without --force"

echo "[12] workgroup down --force removes clean worktree"
# Bring it up again, then force-down.
workgroup up "$HERE/examples/feature-x.yaml" >/dev/null 2>&1 \
  && ok "re-up after archive" || nope "re-up failed"
workgroup down feature-x --force >"$SCRATCH/down2.out" 2>&1 \
  && ok "force-down exit 0" || { cat "$SCRATCH/down2.out"; nope "force-down failed"; }
[ -d "$WORK_ROOT/worktrees/feature-x" ] && nope "worktree still present" \
  || ok "worktree removed"

skip "real sidecar reachability — runs in-sandbox during Phase 04 bring-up"
skip "role injection survives /clear — manual check with real claude"

printf '\npassed: %d    failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
