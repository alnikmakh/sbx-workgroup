#!/usr/bin/env bash
# teardown.sh <project> [--name <vm-name>]
#
# Removes the project's sbx VM and stops its sidecar. Intentionally preserves
# ${cgc_data_root}/<project>/ so a later provision.sh re-attaches to the same
# index without reindexing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[teardown] %s\n' "$*" >&2; }
die() { printf '[teardown] error: %s\n' "$*" >&2; exit 1; }

project=""
vm_name=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name) vm_name="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0" >&2; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)
            [ -z "$project" ] || die "unexpected arg: $1"
            project="$1"; shift ;;
    esac
done

[ -n "$project" ] || die "usage: teardown.sh <project> [--name <vm-name>]"
[[ "$project" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid project name: $project"
[ -n "$vm_name" ] || vm_name="sbx-$project"

command -v sbx >/dev/null || die "sbx CLI not found in PATH"

if sbx ls -q 2>/dev/null | grep -qx "$vm_name"; then
    log "removing sandbox '$vm_name'"
    sbx stop "$vm_name" >/dev/null 2>&1 || true
    sbx rm "$vm_name" || log "sbx rm returned non-zero; continuing"
else
    log "sandbox '$vm_name' not present; skipping"
fi

log "stopping sidecar for '$project'"
"$here/host-mcp/sidecar-down.sh" "$project"

log "done. cgc data preserved on host."
