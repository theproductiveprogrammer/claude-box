#!/usr/bin/env bash
# image.sh — move the built claude-box image between machines of the same
# architecture, skipping a rebuild (and its npm/registry auth) on the
# receiving end.
#
#   image.sh save [file]   save the image to a gzipped tarball (default: claude-box.tar.gz)
#   image.sh load [file]   load that tarball into the local runtime
#
# Typical flow: build on the Mac, `image.sh save`, copy the tarball to the
# work machine (AirDrop, USB, scp, ...), then `image.sh load` there.
# Understand: this only works between machines of the same CPU architecture
# (arm64 <-> arm64, or amd64 <-> amd64) — a tarball built on one won't run on
# the other.
set -euo pipefail

IMAGE="${CLAUDE_BOX_IMAGE:-claude-box}"
# Same preference as the claude-box launcher: podman on work machines, docker
# (via OrbStack) on the Mac.
RUNTIME="${CLAUDE_BOX_RUNTIME:-$(command -v podman || command -v docker || true)}"
if [ -z "${RUNTIME}" ]; then
  echo "image.sh: neither podman nor docker found on PATH" >&2
  exit 1
fi

cmd="${1:-}"
file="${2:-claude-box.tar.gz}"

case "$cmd" in
  save)
    "${RUNTIME}" save "${IMAGE}" | gzip > "${file}"
    echo "Saved ${IMAGE} -> ${file} ($(du -h "${file}" | cut -f1))"
    ;;
  load)
    [ -f "${file}" ] || { echo "image.sh: ${file} not found" >&2; exit 1; }
    gunzip -c "${file}" | "${RUNTIME}" load
    ;;
  *)
    echo "usage: image.sh save|load [file]" >&2
    exit 1
    ;;
esac
