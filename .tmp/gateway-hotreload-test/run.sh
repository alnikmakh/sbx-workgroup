#!/usr/bin/env bash
# Reproducible test: does `docker/mcp-gateway:latest --watch` hot-reload
# the --catalog YAML file when it is edited on the host?
#
# Result on this host (Docker 29.2.1, Linux 6.18): NO. The local --catalog
# file is read once at startup and never re-read. `--watch` prints
# "- Watching for configuration updates..." but only the Docker Desktop
# KV-store metadata path (~/.docker/mcp/catalog.json) is actually
# registered with fsnotify. Neither in-place edits, `touch`, atomic `mv`,
# nor edits from *inside* the container trigger any reload log line or
# fsnotify event.
#
# See run-v2.sh for the follow-up investigation. Summary of v2 findings:
#   - HTTP-served --catalog is also NOT watched: fetched exactly once at
#     startup, no poll interval, no event-driven refetch. (Observed: 1 GET
#     across 12+ minutes of uptime with the served file being edited.)
#   - SIGHUP terminates the gateway (no handler). SIGUSR1/SIGUSR2 ignored.
#   - --additional-catalog local file: same fsnotify miss.
#   - --mcp-registry: different data model (single-server JSON), not a
#     catalog transport.
# Conclusion: no built-in mechanism hot-reloads a user-supplied catalog.
# apply.sh must recreate the gateway container on every change.
#
# Re-run from this directory. Requires: docker, docker daemon reachable.

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=hr-gw
PORT=8811
IMAGE=docker/mcp-gateway:latest

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup

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

echo "[*] host inode:"; stat -c '%i %s' catalog.yaml

# NOTE: Do NOT pass --servers with a real server name unless that server
# actually speaks MCP over stdio -- otherwise startup hangs on the
# failing initialize handshake and never reaches the watch loop.
docker run -d --rm --name "$CONTAINER" \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/catalog.yaml:/cat.yaml" \
  -e MCP_GATEWAY_AUTH_TOKEN=test \
  -e FSNOTIFY_DEBUG=1 \
  "$IMAGE" \
  --catalog /cat.yaml \
  --transport streaming --port "$PORT" \
  --watch --verbose

# Wait for startup banner.
for _ in $(seq 1 30); do
  if docker logs "$CONTAINER" 2>&1 | grep -q "Start streaming server"; then break; fi
  sleep 0.5
done

echo "[*] initial logs:"
docker logs "$CONTAINER" 2>&1 | tail -20
echo "[*] container inode:"; docker exec "$CONTAINER" stat -c '%i %s' /cat.yaml

probe() {
  local label="$1"; shift
  echo
  echo "[*] probe: $label"
  "$@"
  sleep 1
  local new
  new=$(docker logs "$CONTAINER" 2>&1 | grep -iE "reload|watch.*(chang|updat)|reconfigur|fsnotify" | grep -v "Watching for configuration updates" || true)
  if [ -n "$new" ]; then
    echo "  RELOAD SIGNAL: $new"
  else
    echo "  no reload log lines"
  fi
  echo "  container sees: $(docker exec "$CONTAINER" stat -c 'inode=%i size=%s' /cat.yaml)"
}

append_srv() {
  local name="$1"
  tee -a catalog.yaml >/dev/null <<EOF
  ${name}:
    description: dummy ${name}
    title: ${name}
    type: server
    image: alpine:latest
    ref: ""
    tools:
      - name: ${name}_tool
    prompts: 0
    resources: {}
    metadata:
      category: test
      tags: [test]
EOF
}

probe "in-place append srv2" append_srv srv2
probe "in-place append srv3" append_srv srv3
probe "touch catalog.yaml"    touch catalog.yaml
probe "edit from inside container" docker exec "$CONTAINER" sh -c 'echo "# inside" >> /cat.yaml'

# atomic mv changes the host inode; the bind mount will pin the ORIGINAL
# inode inside the container, so the container stops seeing further
# changes. This demonstrates the separate "wrong edit style" failure mode.
probe "atomic mv replace (should NOT propagate past this point)" \
  bash -c 'cp catalog.yaml catalog.yaml.new && echo "# mv" >> catalog.yaml.new && mv catalog.yaml.new catalog.yaml'
probe "in-place append after mv (should be invisible in container)" append_srv srv4

echo
echo "[*] final full logs:"
docker logs "$CONTAINER" 2>&1

echo
echo "[*] conclusion: if 'RELOAD SIGNAL' never appeared above, --watch does NOT"
echo "    reload --catalog files on this host. apply.sh must recreate the container."
