#!/usr/bin/env bash
# Build the sidecar image. Idempotent — docker handles layer caching.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${SBX_SIDECAR_IMAGE:-sbx-cgc-sidecar:local}"

docker build -t "$image" -f "$here/Dockerfile.sidecar" "$here"
echo "built: $image"
