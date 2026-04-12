#!/usr/bin/env bash
# Follow-up test (v2) for docker/mcp-gateway:latest hot-reload behavior.
#
# Tests three more vectors beyond the v1 --catalog-local-file test:
#
#   Q1. HTTP-served catalog: does `--catalog http://...` fetch periodically
#       or react to changes in the served file?
#   Q2. Signals: does SIGHUP / SIGUSR1 / SIGUSR2 trigger a reload?
#   Q3. Alternative flags: --additional-catalog (local file) and
#       --mcp-registry (http URL).
#
# Empirical result on Docker 29.2.1 / Linux 6.18:
#   Q1: NO.   The gateway fetches the HTTP catalog EXACTLY ONCE at startup
#             and never again. No poll interval, no event-driven refetch.
#             (Verified: single GET in access log across multi-minute runs,
#             edits to the served file ignored.)
#   Q2: NO.   SIGHUP  -> container terminates (default Go handler).
#             SIGUSR1 -> ignored, no reload.
#             SIGUSR2 -> ignored, no reload.
#   Q3: NO for --additional-catalog (local file) - same fsnotify miss as v1.
#       N/A  for --mcp-registry         - expects a single MCP server JSON
#             definition, not a catalog.yaml, and is a different data model.
#             Not viable as a catalog transport.
#
# Binary strings confirm watchRemoteConfig / WatchRemoteConfigOnChannel
# exist, but they are wired to the Docker Desktop KV store
# (~/.docker/mcp/catalog.json metadata), not arbitrary --catalog URLs.
# There is no interval/ticker for catalog refetch and no SIGHUP handler.
#
# Conclusion for apply.sh: NONE of the built-in mechanisms hot-reload a
# user-supplied catalog. The container MUST be recreated on every change.

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=hr-gw
HTTP_PORT=8899
GW_PORT=8811
IMAGE=docker/mcp-gateway:latest

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [ -n "${HTTP_PID:-}" ]; then kill "$HTTP_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
cleanup

# Fresh minimal catalog.
cat > catalog.yaml <<'YAML'
version: 2
name: hr-test
displayName: Hot Reload Test
registry:
  srv1:
    description: dummy server 1
    title: Srv1
    type: server
    image: alpine:latest
    ref: ""
    tools:
      - name: srv1_tool
    prompts: 0
    resources: {}
    metadata:
      category: test
      tags: [test]
YAML

# ---- Q1: HTTP-served catalog ----
echo "=== Q1: HTTP catalog ==="
: > /tmp/hr-http.log
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/tmp/hr-http.log 2>&1 &
HTTP_PID=$!
sleep 1

# --network=host lets the gateway reach 127.0.0.1:$HTTP_PORT.
docker run -d --rm --name "$CONTAINER" \
  --network=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e MCP_GATEWAY_AUTH_TOKEN=test \
  "$IMAGE" \
  --catalog "http://127.0.0.1:${HTTP_PORT}/catalog.yaml" \
  --transport streaming --port "$GW_PORT" \
  --watch --verbose >/dev/null

for _ in $(seq 1 30); do
  if docker logs "$CONTAINER" 2>&1 | grep -q "Start streaming server"; then break; fi
  sleep 0.5
done
echo "[*] startup fetches (expect exactly 1):"
grep -c "GET /catalog.yaml" /tmp/hr-http.log || true

# Modify served file and wait for any potential poll.
cat >> catalog.yaml <<'EOF'
  srv-probe:
    description: probe
    title: SrvProbe
    type: server
    image: alpine:latest
    ref: ""
    tools:
      - name: srv_probe_tool
    prompts: 0
    resources: {}
    metadata:
      category: test
      tags: [test]
EOF

echo "[*] waiting 240s for any refetch..."
sleep 240
echo "[*] fetches after 240s (still expect 1):"
grep -c "GET /catalog.yaml" /tmp/hr-http.log || true
echo "[*] gw reload signals:"
docker logs "$CONTAINER" 2>&1 | grep -iE "reload|reconfigur|chang" | grep -v "Watching for" || echo "  (none)"

# ---- Q2: signals ----
echo
echo "=== Q2: signals ==="
# SIGHUP -> terminates the container. Recreate after.
docker kill --signal=SIGHUP "$CONTAINER" || true
sleep 1
if docker ps --filter name="$CONTAINER" --format '{{.Names}}' | grep -q .; then
  echo "  SIGHUP: survived (unexpected)"
else
  echo "  SIGHUP: container EXITED (no reload handler -> default terminate)"
fi

# Restart for USR1/USR2 tests.
docker run -d --rm --name "$CONTAINER" \
  --network=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e MCP_GATEWAY_AUTH_TOKEN=test \
  "$IMAGE" \
  --catalog "http://127.0.0.1:${HTTP_PORT}/catalog.yaml" \
  --transport streaming --port "$GW_PORT" \
  --watch --verbose >/dev/null
sleep 3

for sig in USR1 USR2; do
  before=$(docker logs "$CONTAINER" 2>&1 | wc -l)
  docker kill --signal="SIG$sig" "$CONTAINER" || true
  sleep 1
  after=$(docker logs "$CONTAINER" 2>&1 | wc -l)
  if docker ps --filter name="$CONTAINER" --format '{{.Names}}' | grep -q .; then
    if [ "$after" -gt "$before" ]; then
      echo "  SIG$sig: survived, new log lines (possible reload):"
      docker logs "$CONTAINER" 2>&1 | tail -$((after - before))
    else
      echo "  SIG$sig: survived, ignored (no new log lines, no reload)"
    fi
  else
    echo "  SIG$sig: container EXITED"
    break
  fi
done

# ---- Q3: alternative flags ----
echo
echo "=== Q3a: --additional-catalog (local file) ==="
docker rm -f hr-gw2 >/dev/null 2>&1 || true
docker run -d --rm --name hr-gw2 \
  -p "127.0.0.1:8812:8812" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/catalog.yaml:/cat.yaml" \
  -e MCP_GATEWAY_AUTH_TOKEN=test \
  "$IMAGE" \
  --additional-catalog /cat.yaml \
  --transport streaming --port 8812 \
  --watch --verbose >/dev/null
sleep 3
echo "extra server to additional-catalog" >> catalog.yaml  # malformed but just to trigger fsnotify
cat >> catalog.yaml <<'EOF'
  srv-addcat:
    description: addcat
    title: SrvAddCat
    type: server
    image: alpine:latest
    ref: ""
    tools:
      - name: srv_addcat_tool
    prompts: 0
    resources: {}
    metadata:
      category: test
      tags: [test]
EOF
sleep 3
docker logs hr-gw2 2>&1 | grep -iE "reload|reconfigur|chang" | grep -v "Watching for" \
  || echo "  --additional-catalog: NO reload"
docker rm -f hr-gw2 >/dev/null 2>&1 || true

echo
echo "=== Q3b: --mcp-registry (http URL) ==="
echo "  Note: --mcp-registry expects a single MCP server JSON (name/version/packages),"
echo "  NOT a catalog.yaml. Different data model - not a viable catalog transport."

echo
echo "=== DONE ==="
