#!/usr/bin/env bash
# =============================================================================
#  Bootstrap installer — downloads scripts from GitHub and runs install-k8s.sh
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
#    curl -fsSL ... | BRANCH=develop bash
# =============================================================================
set -euo pipefail

BRANCH="${BRANCH:-main}"
REPO_RAW="https://raw.githubusercontent.com/tracebloc/client/${BRANCH}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "⬇  Downloading tracebloc installer (branch: $BRANCH)..."

mkdir -p "$TMPDIR/lib"

FILES=(
  "scripts/install-k8s.sh"
  "scripts/lib/common.sh"
  "scripts/lib/detect-gpu.sh"
  "scripts/lib/gpu-nvidia.sh"
  "scripts/lib/gpu-amd.sh"
  "scripts/lib/setup-macos.sh"
  "scripts/lib/setup-linux.sh"
  "scripts/lib/cluster.sh"
  "scripts/lib/gpu-plugins.sh"
  "scripts/lib/summary.sh"
)

for f in "${FILES[@]}"; do
  dest="$TMPDIR/${f#scripts/}"
  curl -fsSL "$REPO_RAW/$f" -o "$dest"
done

chmod +x "$TMPDIR/install-k8s.sh"

echo "🚀  Running installer..."
bash "$TMPDIR/install-k8s.sh" "$@"
