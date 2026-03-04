#!/usr/bin/env bash
# Create and push a Git tag from the chart version in tracebloc/Chart.yaml.
# Usage: ./scripts/tag-from-chart.sh [--tracebloc-prefix] [--dry-run]
#   --tracebloc-prefix  use tag tracebloc-vX.Y.Z instead of vX.Y.Z
#   --dry-run           print tag and exit without creating/pushing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_YAML="${REPO_ROOT}/tracebloc/Chart.yaml"

TRACEBLOC_PREFIX=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --tracebloc-prefix) TRACEBLOC_PREFIX=true ;;
    --dry-run)          DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--tracebloc-prefix] [--dry-run]"
      echo "  --tracebloc-prefix  tag as tracebloc-vX.Y.Z"
      echo "  --dry-run           only print the tag, do not create or push"
      exit 0
      ;;
  esac
done

if [[ ! -f "$CHART_YAML" ]]; then
  echo "Error: Chart.yaml not found at $CHART_YAML" >&2
  exit 1
fi

VERSION=$(grep '^version:' "$CHART_YAML" | sed 's/^version:[[:space:]]*//' | tr -d '"' | tr -d "'")
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not read version from $CHART_YAML" >&2
  exit 1
fi

if [[ "$TRACEBLOC_PREFIX" == true ]]; then
  TAG="tracebloc-v${VERSION}"
else
  TAG="v${VERSION}"
fi

echo "Chart version: ${VERSION}"
echo "Tag: ${TAG}"

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: would create and push tag ${TAG}"
  exit 0
fi

if git rev-parse "$TAG" &>/dev/null; then
  echo "Error: Tag ${TAG} already exists." >&2
  exit 1
fi

cd "$REPO_ROOT"
git tag "$TAG"
echo "Created tag ${TAG}. Pushing..."
git push origin "$TAG"
echo "Done. Pushed tag ${TAG}."
