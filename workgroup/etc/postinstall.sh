#!/usr/bin/env sh
# postinstall.sh — runs inside the sbx VM, first boot and on demand.
# Idempotent: every step reports "already installed" when re-run.
set -eu

log()  { printf '[postinstall] %s\n' "$*" >&2; }
die()  { printf '[postinstall] error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

# -- 0. Materialize guest-path contract --------------------------------------
# sbx mounts host paths at the same path inside the sandbox, so we expose the
# stable contract (/work, /bridge, /opt/workgroup) as symlinks. The real
# sources are passed in by provision.sh via `sbx exec -e`.
: "${WORK_SRC:?WORK_SRC not set (pass via sbx exec -e)}"
: "${BRIDGE_SRC:?BRIDGE_SRC not set (pass via sbx exec -e)}"
: "${WORKGROUP_SRC:?WORKGROUP_SRC not set (pass via sbx exec -e)}"
: "${SIDECAR_PORT:?SIDECAR_PORT not set (pass via sbx exec -e)}"

link_contract() {
    link="$1"; target="$2"
    [ -d "$target" ] || die "contract source missing: $target"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        return 0
    fi
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link exists and is not a symlink; refusing to clobber"
    fi
    ln -sfn "$target" "$link"
    log "linked $link -> $target"
}
mkdir -p /opt /etc/workgroup
link_contract /work          "$WORK_SRC"
link_contract /bridge        "$BRIDGE_SRC"
link_contract /opt/workgroup "$WORKGROUP_SRC"

# Persist the sidecar port so phase 04 can construct the claude mcp add URL.
printf '%s\n' "$SIDECAR_PORT" > /etc/workgroup/sidecar-port

# -- 1. Packages --------------------------------------------------------------
pkgs_common="tmux git inotify-tools jq curl ca-certificates"
# flock ships in util-linux on debian/alpine; yq is a separate binary.

wait_for_apt_lock() {
    # The sbx shell template runs its own apt on first boot. Wait for it.
    deadline=$(( $(date +%s) + 180 ))
    while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            die "timed out waiting for apt/dpkg lock"
        fi
        log "waiting for apt lock..."
        sleep 2
    done
}

install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    wait_for_apt_lock
    apt-get update -y
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $pkgs_common util-linux
    if ! need yq; then
        log "installing yq (binary from github release)"
        arch="$(uname -m)"
        case "$arch" in
            x86_64)  yq_arch=amd64 ;;
            aarch64) yq_arch=arm64 ;;
            *) die "unsupported arch for yq: $arch" ;;
        esac
        curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" \
            -o /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
    fi
}

install_alpine() {
    apk update
    # shellcheck disable=SC2086
    apk add --no-cache $pkgs_common util-linux yq
}

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        *alpine*) install_alpine ;;
        *debian*|*ubuntu*|debian:*|ubuntu:*) install_debian ;;
        *) die "unsupported distro: ${ID:-unknown}" ;;
    esac
else
    die "cannot detect distro (no /etc/os-release)"
fi

for b in tmux git jq yq flock curl inotifywait; do
    need "$b" || die "missing after install: $b"
done
log "packages ok"

# -- 2. Claude Code -----------------------------------------------------------
# Soft install: Balanced network policy blocks claude.ai by default. Rather
# than hard-failing, we attempt and warn. Users who want claude in-sandbox
# need: `sbx policy allow network claude.ai:443` on the host, then re-run
# provision.sh.
if need claude; then
    log "claude already installed: $(claude --version 2>/dev/null || echo '?')"
else
    log "attempting claude install (may fail under Balanced policy)"
    installer="$(mktemp)"
    if curl -fsSL https://claude.ai/install.sh -o "$installer" 2>/dev/null; then
        sh "$installer" || log "warning: claude install script failed"
    else
        log "warning: could not fetch claude installer (claude.ai not in allowlist)"
        log "    to enable, on the host run: sbx policy allow network claude.ai:443"
    fi
    rm -f "$installer"
fi

# -- 3. Symlink workgroup/bridge binaries onto PATH ---------------------------
if [ -d /opt/workgroup/bin ]; then
    for src in /opt/workgroup/bin/*; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        link="/usr/local/bin/$name"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
            continue
        fi
        ln -sf "$src" "$link"
        log "linked $name -> $src"
    done
else
    log "note: /opt/workgroup/bin not present yet (phases 03/04 populate it)"
fi

# -- 4. Mount sanity ----------------------------------------------------------
for d in /work /bridge /opt/workgroup; do
    [ -d "$d" ] || die "missing mount: $d"
done
[ -w /work ]   || die "/work is not writable"
[ -w /bridge ] || die "/bridge is not writable"
log "mounts ok"

# -- 5. Sidecar reachability --------------------------------------------------
sidecar_url="http://host.docker.internal:${SIDECAR_PORT}"
if curl -fsS "$sidecar_url/health" -o /dev/null; then
    log "sidecar reachable at $sidecar_url/health"
elif curl -fsS "$sidecar_url/mcp" -o /dev/null; then
    log "sidecar reachable at $sidecar_url/mcp"
else
    die "sidecar not reachable at $sidecar_url (check 'sbx policy ls' for localhost:$SIDECAR_PORT)"
fi

# -- 6. Summary ---------------------------------------------------------------
cat >&2 <<EOF

[postinstall] summary
  tmux:    $(tmux -V 2>/dev/null || echo '?')
  git:     $(git --version 2>/dev/null || echo '?')
  jq:      $(jq --version 2>/dev/null || echo '?')
  yq:      $(yq --version 2>/dev/null || echo '?')
  claude:  $(claude --version 2>/dev/null || echo '?')
  mounts:  $(ls -ld /work /bridge /opt/workgroup | awk '{print $NF}' | tr '\n' ' ')

next step (once per Claude session, inside this sandbox):
  claude mcp add --transport http cgc "http://host.docker.internal:${SIDECAR_PORT}/mcp"
EOF
