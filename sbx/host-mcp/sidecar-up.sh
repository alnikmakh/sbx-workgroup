#!/usr/bin/env bash
# sidecar-up.sh <project>
#
# Idempotent. Ensures the per-project sidecar container is running and prints
# the chosen host port on its own line on stdout (and nothing else on stdout).
# All diagnostics go to stderr.
#
# Contract (Phase 02): exit 0 on success, stdout = single line containing the
# host port that the sidecar is bound to at 127.0.0.1:<port>.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${SBX_SIDECAR_IMAGE:-sbx-cgc-sidecar:local}"
config="${SBX_MACHINE_CONFIG:-$HOME/.config/sbx-workgroup/machine.yaml}"

log() { printf '[sidecar-up] %s\n' "$*" >&2; }
die() { printf '[sidecar-up] error: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: sidecar-up.sh <project>"
project="$1"
[[ "$project" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid project name: $project"

command -v docker >/dev/null || die "docker not found in PATH"
command -v yq     >/dev/null || die "yq not found in PATH (needed to parse $config)"

[ -f "$config" ] || die "missing config: $config"

projects_root="$(yq -r '.projects_root // ""'  "$config")"
cgc_data_root="$(yq -r '.cgc_data_root // ""' "$config")"
[ -n "$projects_root" ] || die "projects_root not set in $config"
[ -n "$cgc_data_root" ] || die "cgc_data_root not set in $config"

project_dir="$projects_root/$project"
[ -d "$project_dir" ] || die "project directory does not exist: $project_dir"

data_dir="$cgc_data_root/$project"
mkdir -p "$data_dir"

# Port: override first, otherwise 8000 + (crc32(project) mod 1000).
override="$(yq -r ".port_overrides.\"$project\" // \"\"" "$config")"
if [ -n "$override" ]; then
    port="$override"
    log "using port override: $port"
else
    port="$(python3 -c 'import binascii,sys;print(8000+binascii.crc32(sys.argv[1].encode())%1000)' "$project")"
fi

container="cgc-sidecar-$project"
label="sbx.project=$project"

# Ensure the image exists. Build on first run if not.
if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "image $image missing; building"
    "$here/build.sh" >&2
fi

# Already running?
existing_state="$(docker ps -a --filter "label=$label" --format '{{.State}}' | head -n1 || true)"
if [ "$existing_state" = "running" ]; then
    bound="$(docker port "$container" 8811/tcp 2>/dev/null | awk -F: '{print $NF}' | head -n1 || true)"
    if [ -n "$bound" ]; then
        log "already running on 127.0.0.1:$bound"
        printf '%s\n' "$bound"
        exit 0
    fi
fi

# Stale container: remove.
if [ -n "$existing_state" ]; then
    log "removing stale container ($existing_state)"
    docker rm -f "$container" >/dev/null
fi

# Port-in-use check (something other than us).
if ss -lntH "sport = :$port" 2>/dev/null | grep -q .; then
    die "host port $port already in use; add \"port_overrides: { $project: <port> }\" to $config"
elif command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    die "host port $port already in use; add \"port_overrides: { $project: <port> }\" to $config"
fi

log "starting $container on 127.0.0.1:$port"
docker run -d --restart=unless-stopped \
    --name "$container" \
    --label "$label" \
    -p "127.0.0.1:$port:8811" \
    -v "$project_dir:/work:ro" \
    -v "$data_dir:/root/.cgc" \
    -e "MUX_PROJECT=$project" \
    "$image" >/dev/null

# Wait for /health (bounded).
deadline=$(( $(date +%s) + 15 ))
while :; do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "health probe timed out; recent container logs:"
        docker logs --tail 50 "$container" >&2 || true
        die "sidecar failed to come up"
    fi
    sleep 0.3
done

printf '%s\n' "$port"
