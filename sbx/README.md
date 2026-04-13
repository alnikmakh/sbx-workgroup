# sbx/ — microVM provisioning

Host-side scripts that stand up a per-project sbx microVM and its matching
host sidecar. Conceptual context: `plans/00-overview.md`.
Detailed scope: `plans/01-vm-provisioning.md`.

## Prerequisites

- Docker `sbx` CLI installed and on PATH.
- `docker` (for the host-side cgc sidecar).
- `yq`, `curl`, `python3` on the host.
- `~/.config/sbx-workgroup/machine.yaml`:

  ```yaml
  projects_root: /path/to/projects
  cgc_data_root: /path/to/cgc-data
  # port_overrides:
  #   my-project: 8850
  ```

- Project source tree at `${projects_root}/<project>`.

## Bring a project up

```sh
./sbx/provision.sh <project>            # default VM name: sbx-<project>
./sbx/provision.sh <project> --name foo # custom VM name
```

What it does:

1. Ensures the project's host sidecar is running (`host-mcp/sidecar-up.sh`)
   and captures its hashed host port.
2. `sbx create` with mounts `/work`, `/bridge`, `/opt/workgroup` and
   `--publish <host-port>:8811`.
3. `sbx run <name> -- /opt/workgroup/etc/postinstall.sh` to install tmux, git,
   jq, yq, flock, inotify-tools and Claude Code inside the guest.
4. Prints the `sbx attach <name>` and one-time `claude mcp add` lines.

Re-running on an existing VM is safe: it re-runs `postinstall.sh` and exits 0.

## Tear down

```sh
./sbx/teardown.sh <project>
```

Removes the VM and stops the sidecar. `${cgc_data_root}/<project>/` is
preserved so a later `provision.sh` re-attaches to the same index.

## Logs

- Sidecar: `docker logs cgc-sidecar-<project>`.
- VM:      `sbx logs <name>` (or attach and inspect `/var/log`).

## Layout

```
sbx/
├── provision.sh          # host: create VM + sidecar
├── teardown.sh           # host: remove VM + sidecar
├── host-mcp/             # Phase 02: sidecar image + lifecycle
│   ├── Dockerfile.sidecar
│   ├── build.sh
│   ├── mcp_mux.py
│   ├── sidecar-up.sh
│   └── sidecar-down.sh
└── README.md
workgroup/
├── bin/                  # Phases 03/04 populate this (workgroup, bridge-*)
└── etc/postinstall.sh    # runs inside the VM on first boot
```
