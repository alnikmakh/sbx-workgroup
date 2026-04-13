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
: "${WORKTREE_SRC:?WORKTREE_SRC not set (pass via sbx exec -e)}"
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

# WORKTREE_SRC is mounted at its real host path inside the sandbox (sbx mounts
# host paths at the same path). No symlink — git worktree metadata records the
# worktree's absolute path in .git/worktrees/<name>/gitdir, and that path must
# be valid both inside the sandbox and on the host. Using the real host path
# for both sides makes git worktree listings consistent across the boundary.
[ -d "$WORKTREE_SRC" ] || die "WORKTREE_SRC missing: $WORKTREE_SRC"
[ -w "$WORKTREE_SRC" ] || die "WORKTREE_SRC not writable: $WORKTREE_SRC"

# Persist the sidecar port so phase 04 can construct the claude mcp add URL.
printf '%s\n' "$SIDECAR_PORT" > /etc/workgroup/sidecar-port
# Persist the worktree root so workgroup/lib/worktree.sh can read it.
printf '%s\n' "$WORKTREE_SRC" > /etc/workgroup/worktree-root

# -- 1. Packages --------------------------------------------------------------
pkgs_common="tmux git inotify-tools jq curl ca-certificates locales"
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
    # alpine's musl ships C.UTF-8 without a separate package; drop `locales`.
    apk add --no-cache tmux git inotify-tools jq curl ca-certificates util-linux yq
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

# -- 1a. Locale ---------------------------------------------------------------
# Without UTF-8 in the env, tmux replaces non-ASCII glyphs with `_`, claude's
# status output becomes garbled, and python/node complain on stderr. C.UTF-8
# is in glibc and musl without needing locale-gen, so it works on every sane
# distro. Write both /etc/environment (read by PAM on login) and a
# profile.d script (read by every POSIX shell) so `sbx run` sessions and
# non-login shells both see it.
if ! grep -q '^LANG=C.UTF-8' /etc/environment 2>/dev/null; then
    # Strip any prior LANG/LC_ALL lines, then append ours.
    if [ -f /etc/environment ]; then
        sed -i '/^LANG=/d;/^LC_ALL=/d' /etc/environment
    fi
    {
        printf 'LANG=C.UTF-8\n'
        printf 'LC_ALL=C.UTF-8\n'
    } >> /etc/environment
    log "set LANG=C.UTF-8 in /etc/environment"
fi
cat > /etc/profile.d/locale.sh <<'EOF'
# Written by workgroup postinstall.sh. Forces UTF-8 for all shells so tmux
# renders Unicode and claude's output isn't mangled.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
EOF
chmod 0644 /etc/profile.d/locale.sh
# Interactive non-login bash (what `sbx run` typically drops into) doesn't
# read profile.d, so also wire it through bash.bashrc.
if [ -f /etc/bash.bashrc ] && ! grep -q 'workgroup-locale' /etc/bash.bashrc; then
    cat >> /etc/bash.bashrc <<'EOF'

# workgroup-locale: ensure UTF-8 in interactive non-login shells.
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
EOF
fi

# -- 1b. System tmux config ---------------------------------------------------
# Symlink so edits in the repo show up without reprovisioning.
if [ -f /opt/workgroup/etc/tmux.conf ]; then
    if [ ! -L /etc/tmux.conf ] || \
       [ "$(readlink /etc/tmux.conf)" != /opt/workgroup/etc/tmux.conf ]; then
        ln -sfn /opt/workgroup/etc/tmux.conf /etc/tmux.conf
        log "linked /etc/tmux.conf -> /opt/workgroup/etc/tmux.conf"
    fi
fi

# -- 2. Claude Code -----------------------------------------------------------
# Soft install: Balanced network policy blocks claude.ai by default. Rather
# than hard-failing, we attempt and warn. Users who want claude in-sandbox
# need: `sbx policy allow network claude.ai:443` on the host, then re-run
# provision.sh.
#
# Runs as the sandbox runtime user (agent, uid 1000), not root: the installer
# drops the binary in $HOME/.local/bin, and $HOME must be the agent's home or
# `sbx run` sessions won't find it. The installer shebang is /bin/bash and
# uses `[[ ... ]]`, so we must invoke it via bash, not sh (which is dash on
# ubuntu and errors out at line 9).
sbx_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
: "${sbx_user:=agent}"
sbx_user_home="$(getent passwd "$sbx_user" 2>/dev/null | cut -d: -f6)"
: "${sbx_user_home:=/home/$sbx_user}"
as_sbx_user() {
    # runuser ships in util-linux (already installed above).
    runuser -u "$sbx_user" -- env HOME="$sbx_user_home" PATH="$sbx_user_home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

if as_sbx_user sh -c 'command -v claude >/dev/null 2>&1'; then
    log "claude already installed for $sbx_user: $(as_sbx_user claude --version 2>/dev/null || echo '?')"
else
    log "attempting claude install for $sbx_user (may fail under Balanced policy)"
    installer="$(mktemp)"
    chmod 0644 "$installer"
    if curl -fsSL https://claude.ai/install.sh -o "$installer" 2>/dev/null; then
        if as_sbx_user bash "$installer"; then
            log "claude installed for $sbx_user"
        else
            log "warning: claude install script failed"
        fi
    else
        log "warning: could not fetch claude installer (claude.ai not in allowlist)"
        log "    to enable, on the host run: sbx policy allow network claude.ai:443"
    fi
    rm -f "$installer"
fi

# -- 2a. Register cgc MCP server at user scope (as the sandbox runtime user) --
# Every `workgroup up` worktree (/work/worktrees/<name>) is a distinct claude
# project, so per-project registration doesn't reach role-injected panes.
# Registering at --scope user makes cgc available in every project directory
# without a per-pane `claude mcp add` step. Writes to $sbx_user_home/.claude.json
# via the as_sbx_user helper defined in step 2.
if as_sbx_user sh -c 'command -v claude >/dev/null 2>&1'; then
    as_sbx_user claude mcp remove cgc --scope user >/dev/null 2>&1 || true
    if as_sbx_user claude mcp add --transport http --scope user cgc \
            "http://host.docker.internal:${SIDECAR_PORT}/mcp" >/dev/null 2>&1; then
        log "registered cgc MCP server at user scope for $sbx_user"
        cgc_status="registered at user scope -> http://host.docker.internal:${SIDECAR_PORT}/mcp"
    else
        log "warning: failed to register cgc MCP server as $sbx_user"
        cgc_status="FAILED to register (see warning above)"
    fi
else
    log "skipping cgc MCP registration (claude not installed for $sbx_user)"
    cgc_status="SKIPPED (claude not installed for $sbx_user)"
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
  claude:  $(as_sbx_user claude --version 2>/dev/null || echo '?')
  mounts:  $(ls -ld /work /bridge /opt/workgroup | awk '{print $NF}' | tr '\n' ' ')
  wtroot:  ${WORKTREE_SRC}
  cgc mcp: ${cgc_status}
EOF
