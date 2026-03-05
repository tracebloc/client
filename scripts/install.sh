#!/usr/bin/env bash
# =============================================================================
#  Bootstrap installer — downloads scripts from GitHub and runs install-k8s.sh
#
#  Usage (macOS / Linux):
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
#    curl -fsSL ... | BRANCH=develop bash
#    curl -fsSL ... | BRANCH=develop CLIENT_ENV=dev bash
#
#  Windows (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
# =============================================================================
set -euo pipefail

# ── Platform gate ────────────────────────────────────────────────────────────
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "[ERROR] Windows detected. Use PowerShell instead:"
    echo "  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex"
    exit 1 ;;
esac

BRANCH="${BRANCH:-main}"
[[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo "[ERROR] Invalid BRANCH name: $BRANCH"; exit 1; }
REPO_RAW="https://raw.githubusercontent.com/tracebloc/client/${BRANCH}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading Tracebloc client installer (branch: $BRANCH)..."

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
  "scripts/lib/install-client-helm.sh"
  "scripts/lib/summary.sh"
)

download_with_retry() {
  local url="$1" dest="$2"
  local attempt max_attempts=3 delay=5
  for attempt in 1 2 3; do
    if curl -fsSL --tlsv1.2 "$url" -o "$dest"; then return 0; fi
    if [[ $attempt -ge $max_attempts ]]; then
      echo "[ERROR] Failed to download $url after $max_attempts attempts."
      exit 1
    fi
    echo "[WARN]  Download failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
    sleep "$delay"
  done
}

for f in "${FILES[@]}"; do
  dest="$TMPDIR/${f#scripts/}"
  download_with_retry "$REPO_RAW/$f" "$dest"
done

chmod +x "$TMPDIR/install-k8s.sh"

echo "Running Tracebloc environment setup..."
bash "$TMPDIR/install-k8s.sh" "$@"
