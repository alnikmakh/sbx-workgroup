#!/bin/sh
# Phase 03 verification. Runs everything from plans/03-bridge-protocol.md
# "Verification" section plus a concurrency burst. No Claude, no tmux.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/bin:$PATH"
. "$HERE/lib/bridge.sh"

BRIDGE_ROOT=$(mktemp -d)
export BRIDGE_ROOT
trap 'rm -rf "$BRIDGE_ROOT"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
nope() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '  SKIP %s\n' "$1"; }

WG=test-wg
BD="$BRIDGE_ROOT/$WG"

echo "[1] bridge-init lays out tree + state.json"
bridge-init "$WG" --agents a,b --edges "a->b"
for d in inbox/a inbox/b outbox/a outbox/b plans reports notes archive roles .counters; do
  [ -d "$BD/$d" ] && ok "dir $d" || nope "missing $d"
done
[ -f "$BD/state.json" ] && ok "state.json exists" || nope "state.json missing"
jq -e '.agents | length == 2' "$BD/state.json" >/dev/null \
  && ok "state.json has 2 agents" || nope "wrong agent count"

echo "[2] bridge-init is idempotent for same agents"
bridge-init "$WG" --agents a,b --edges "a->b" && ok "re-init ok" || nope "re-init failed"

echo "[3] bridge-init refuses differing agent set"
if bridge-init "$WG" --agents a,c --edges "a->c" 2>/dev/null; then
  nope "mismatched re-init was accepted"
else
  ok "mismatched re-init rejected"
fi

echo "[4] bridge-send happy path + layout + schema"
echo "hi from a" > "$BRIDGE_ROOT/msg.md"
export BRIDGE_DIR="$BD" AGENT_ID=a
ID=$(bridge-send --to b --kind note --file "$BRIDGE_ROOT/msg.md" --subject "ping")
[ -n "$ID" ] && ok "send returned id: $ID" || nope "empty id"
[ -f "$BD/inbox/b/$ID.json" ]  && ok "signal in inbox/b"  || nope "inbox missing"
[ -f "$BD/outbox/a/$ID.json" ] && ok "audit in outbox/a"  || nope "outbox missing"
[ -f "$BD/notes/$ID.md" ]      && ok "payload in notes/"  || nope "payload missing"
jq -e --arg id "$ID" '.id==$id and .from=="a" and .to=="b" and .kind=="note"' \
  "$BD/inbox/b/$ID.json" >/dev/null \
  && ok "signal JSON schema" || nope "schema mismatch"

echo "[5] bridge-recv lists the signal"
out=$(BRIDGE_DIR="$BD" AGENT_ID=b bridge-recv)
printf '%s' "$out" | grep -q "$ID" && ok "recv lists id" || nope "recv missed id"
printf '%s' "$out" | grep -q "ping" && ok "recv shows subject" || nope "no subject"

echo "[6] bridge-recv --pop prints payload and archives signal"
got=$(BRIDGE_DIR="$BD" AGENT_ID=b bridge-recv --pop "$ID")
[ "$got" = "hi from a" ] && ok "pop printed payload" || nope "payload mismatch: $got"
[ ! -f "$BD/inbox/b/$ID.json" ] && ok "signal gone from inbox" || nope "inbox not drained"
[ -f "$BD/archive/$ID.json" ]   && ok "signal in archive"     || nope "archive missing"
[ -f "$BD/notes/$ID.md" ]       && ok "payload retained in notes/" || nope "payload gone"

echo "[7] bridge-send rejects undeclared edge"
if BRIDGE_DIR="$BD" AGENT_ID=b bridge-send --to a --kind note \
     --file "$BRIDGE_ROOT/msg.md" 2>/dev/null; then
  nope "b->a accepted"
else
  ok "b->a rejected (no such edge)"
fi

echo "[8] bridge-watch sees a new signal within 2s"
if ! command -v inotifywait >/dev/null 2>&1; then
  skip "inotifywait not installed (provided by inotify-tools inside sandbox)"
else
BRIDGE_ROOT="$BRIDGE_ROOT" bridge-watch "$WG" > "$BRIDGE_ROOT/watch.log" 2>&1 &
WPID=$!
sleep 1
BRIDGE_DIR="$BD" AGENT_ID=a bridge-send --to b --kind plan \
  --file "$BRIDGE_ROOT/msg.md" --subject "watched" >/dev/null
sleep 1
kill "$WPID" 2>/dev/null || true
wait "$WPID" 2>/dev/null || true
grep -q 'NEW b <- a: plan "watched"' "$BRIDGE_ROOT/watch.log" \
  && ok "watch captured event" || { nope "watch missed event"; cat "$BRIDGE_ROOT/watch.log"; }
fi

echo "[8b] bridge-watch SIGTERM path (fake inotifywait, no real kernel events)"
# Reproduces the Phase-03 in-sandbox hang: kill the shell, verify the whole
# process group actually dies within a short deadline and a line was emitted.
SHIM_DIR="$BRIDGE_ROOT/shim"
mkdir -p "$SHIM_DIR"
# Fake inotifywait: emit one event matching real --format '%w %f', then sleep
# forever. If bridge-watch's trap/cleanup is wrong, this sleep outlives the
# parent and we detect the leak.
cat > "$SHIM_DIR/inotifywait" <<EOF
#!/bin/sh
printf '$BD/inbox/b/ fake.json\n'
exec sleep 3600
EOF
chmod +x "$SHIM_DIR/inotifywait"
# Give bridge-watch something to jq on so the line-emit path runs.
echo '{"from":"a","kind":"note","subject":"shim"}' > "$BD/inbox/b/fake.json"
( PATH="$SHIM_DIR:$PATH" bridge-watch "$WG" > "$BRIDGE_ROOT/watch2.log" 2>&1 ) &
WPID=$!
sleep 1
kill -TERM "$WPID" 2>/dev/null || true
# Bounded wait: if cleanup is broken we'd hang here.
deadline=$(( $(date +%s) + 3 ))
while kill -0 "$WPID" 2>/dev/null; do
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.1 2>/dev/null || sleep 1
done
if kill -0 "$WPID" 2>/dev/null; then
  nope "bridge-watch did not exit within 3s of SIGTERM"
  kill -KILL "$WPID" 2>/dev/null || true
else
  ok "bridge-watch exited cleanly on SIGTERM"
fi
# And the fake inotifywait must not be left orphaned.
if pgrep -f "$SHIM_DIR/inotifywait" >/dev/null 2>&1; then
  nope "fake inotifywait leaked after parent exit"
  pkill -KILL -f "$SHIM_DIR/inotifywait" 2>/dev/null || true
else
  ok "child inotifywait reaped"
fi
grep -q 'NEW b <- a: note "shim"' "$BRIDGE_ROOT/watch2.log" \
  && ok "shim line emitted before teardown" \
  || { nope "shim line missing"; cat "$BRIDGE_ROOT/watch2.log"; }
rm -f "$BD/inbox/b/fake.json"

echo "[9] concurrent stress: 10 parallel sends, distinct ids, no tmp leftovers"
N=10
i=0
while [ $i -lt $N ]; do
  BRIDGE_DIR="$BD" AGENT_ID=a bridge-send --to b --kind note \
    --file "$BRIDGE_ROOT/msg.md" --subject "burst $i" >"$BRIDGE_ROOT/ids.$i" 2>&1 &
  i=$((i+1))
done
wait
got=$(cat "$BRIDGE_ROOT"/ids.* | sort -u | wc -l)
[ "$got" = "$N" ] && ok "$N distinct ids" || nope "expected $N, got $got"
tmp=$(find "$BD/inbox" -name '.*.tmp*' | wc -l)
[ "$tmp" = 0 ] && ok "no .tmp leftovers" || nope "$tmp leftover .tmp files"
all=1
for f in "$BD/inbox/b"/*.json; do jq -e . "$f" >/dev/null 2>&1 || { all=0; break; }; done
[ "$all" = 1 ] && ok "all delivered signals valid JSON" || nope "partial write leaked"

echo
echo "passed: $pass    failed: $fail"
[ "$fail" = 0 ]
