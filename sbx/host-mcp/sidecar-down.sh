#!/usr/bin/env bash
# sidecar-down.sh <project>
#
# Stops and removes the per-project sidecar container. Does NOT touch
# ${cgc_data_root}/<project>/. Exit 0 even if the container is already gone.
set -euo pipefail

log() { printf '[sidecar-down] %s\n' "$*" >&2; }
die() { printf '[sidecar-down] error: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: sidecar-down.sh <project>"
project="$1"
[[ "$project" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid project name: $project"

command -v docker >/dev/null || die "docker not found in PATH"

container="cgc-sidecar-$project"

if ! docker container inspect "$container" >/dev/null 2>&1; then
    log "$container not present; nothing to do"
    exit 0
fi

log "stopping $container"
docker rm -f "$container" >/dev/null
log "removed $container"
