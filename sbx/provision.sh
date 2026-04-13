#!/usr/bin/env bash
# provision.sh <project> [--name <sandbox-name>] [--memory <SIZE>]
#
# Idempotent. Brings up the per-project sbx microVM sandbox and ensures its
# sidecar is running. Safe to re-run on an already-provisioned project.
#
# Guest-path contract (see plans/00-overview.md) is materialized as symlinks
# inside the sandbox by postinstall.sh, since `sbx` mounts host paths at the
# same path inside the guest:
#   /work          -> ${projects_root}/<project>
#   /bridge        -> ~/sbx-bridge
#   /opt/workgroup -> <repo>/workgroup  (source mount is read-only)
#
# Sidecar reachability: `sbx policy allow network localhost:<port>` opens the
# sandbox's HTTP proxy (gateway.docker.internal:3128) to the sidecar. In-sandbox
# endpoint is http://host.docker.internal:<port>/mcp; the port is exposed to
# the sandbox via $SIDECAR_PORT and /etc/workgroup/sidecar-port.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
config="${SBX_MACHINE_CONFIG:-$HOME/.config/sbx-workgroup/machine.yaml}"

log() { printf '[provision] %s\n' "$*" >&2; }
die() { printf '[provision] error: %s\n' "$*" >&2; exit 1; }

project=""
vm_name=""
memory="8g"

while [ $# -gt 0 ]; do
    case "$1" in
        --name)   vm_name="$2"; shift 2 ;;
        --memory) memory="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" >&2; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown flag: $1" ;;
        *)
            [ -z "$project" ] || die "unexpected arg: $1"
            project="$1"; shift ;;
    esac
done

[ -n "$project" ] || die "usage: provision.sh <project> [--name <sandbox-name>] [--memory <SIZE>]"
[[ "$project" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "invalid project name: $project"
[ -n "$vm_name" ] || vm_name="sbx-$project"

command -v sbx >/dev/null || die "sbx CLI not found in PATH; install Docker Sandboxes first"
command -v yq  >/dev/null || die "yq not found in PATH (needed to parse $config)"

[ -f "$config" ] || die "missing config: $config (see plans/00-overview.md)"

projects_root="$(yq -r '.projects_root // ""' "$config")"
[ -n "$projects_root" ] || die "projects_root not set in $config"

project_dir="$projects_root/$project"
[ -d "$project_dir" ] || die "project directory does not exist: $project_dir"

bridge_dir="$HOME/sbx-bridge"
mkdir -p "$bridge_dir"

workgroup_payload="$repo/workgroup"
[ -d "$workgroup_payload" ] || die "missing workgroup payload dir: $workgroup_payload"

# Step 5: ensure sidecar is up; capture its host port.
log "ensuring sidecar for '$project' is up"
port="$("$here/host-mcp/sidecar-up.sh" "$project")"
[[ "$port" =~ ^[0-9]+$ ]] || die "sidecar-up.sh returned unexpected port: $port"
log "sidecar bound to 127.0.0.1:$port"

run_postinstall() {
    sbx exec -u root \
        -e "WORK_SRC=$project_dir" \
        -e "BRIDGE_SRC=$bridge_dir" \
        -e "WORKGROUP_SRC=$workgroup_payload" \
        -e "SIDECAR_PORT=$port" \
        "$vm_name" "$workgroup_payload/etc/postinstall.sh"
}

ensure_policy() {
    # Idempotently allow the sandbox HTTP proxy to reach the sidecar.
    if sbx policy ls 2>/dev/null | grep -q "localhost:$port"; then
        log "policy allow network localhost:$port already present"
    else
        log "adding policy allow network localhost:$port"
        sbx policy allow network "localhost:$port" >&2
    fi
}

# Step 6: sandbox already present?
if sbx ls -q 2>/dev/null | grep -qx "$vm_name"; then
    log "sandbox '$vm_name' already exists; re-running postinstall (idempotent)"
    ensure_policy
    run_postinstall
    log "done. attach with: sbx run $vm_name"
    exit 0
fi

# Step 7: create the sandbox.
log "creating sandbox '$vm_name' (memory=$memory)"
sbx create shell \
    --name   "$vm_name" \
    --memory "$memory" \
    "$project_dir" \
    "$bridge_dir" \
    "$workgroup_payload:ro"

# Step 7a: allow the sandbox proxy to reach the sidecar.
ensure_policy

# Step 8: first-boot postinstall.
log "running postinstall inside sandbox"
run_postinstall

cat >&2 <<EOF

[provision] done.
  sandbox:     $vm_name
  sidecar:     http://host.docker.internal:$port (via HTTP proxy + policy allow)
  attach:      sbx run $vm_name
  one-time in each Claude session inside the sandbox:
               claude mcp add --transport http cgc "http://host.docker.internal:$port/mcp"
EOF
