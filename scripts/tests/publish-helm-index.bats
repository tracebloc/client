#!/usr/bin/env bats
# Tests for scripts/publish-helm-index.sh — "a release preserves every existing
# version's real `created`".
#
# THE PROPERTY UNDER TEST (backend#3281). The edge-chart-staleness monitor reads
# each published version's `created` off the helm index to decide how long a fix
# has been available. The old release step ran `helm repo index .` over a
# gh-pages checkout holding every historical .tgz, which re-stamped EVERY entry's
# `created` to the release instant — so every version looked freshly published
# and no edge ever looked stale during normal release cadence. The publisher
# fixes that by indexing only the new charts and merging; these tests pin that a
# prior version's `created` survives a later publish.
#
# Needs helm (v3.15.4 in CI; the `Unit tests` job installs it). Every standalone
# bracket assertion ends in `|| return 1` — see bats-hygiene.bats.

PUB=""
REPO_URL=""

setup() {
  PUB="${BATS_TEST_DIRNAME}/../publish-helm-index.sh"
  cd "$BATS_TEST_TMPDIR" || return 1
  REPO_URL="https://example.test/client"
}

# Package chart $2 at version $3 into directory $1 (dir created if absent).
package_into() { # $1 = dest dir, $2 = chart name, $3 = version
  local dest="$1" name="$2" ver="$3"
  local src="${BATS_TEST_TMPDIR}/src-${name}-${ver}"
  rm -rf "$src"
  mkdir -p "$src" "$dest"
  cat >"${src}/Chart.yaml" <<YAML
apiVersion: v2
name: ${name}
version: ${ver}
appVersion: "${ver}"
YAML
  helm package "$src" --destination "$dest" >/dev/null
}

# The `created` scalar for a given version in ./index.yaml (empty if absent).
# Walks the entry list, flushing each item's version→created on the next `- `
# and at end, so field order within an entry does not matter.
created_for() { # $1 = version
  awk -v want="$1" '
    /^  - /   { if (v != "") c_by[v] = c; v = ""; c = "" }
    /^    version:/ { v = $2 }
    /^    created:/ { c = $2 }
    END       { if (v != "") c_by[v] = c; print c_by[want] }
  ' index.yaml
}

@test "a first publish (no merge) writes an index with the new chart, root-relative URLs" {
  package_into _new client 1.0.0
  NEW_CHARTS_DIR=_new REPO_URL="$REPO_URL" OUT_INDEX=index.yaml MERGE_INDEX= bash "$PUB"
  [ -f index.yaml ] || return 1
  grep -q 'version: 1.0.0' index.yaml || return 1
  # URL points at the gh-pages root, NOT the _new/ dir it was indexed from.
  grep -q 'https://example.test/client/client-1.0.0.tgz' index.yaml || return 1
}

@test "a later publish PRESERVES an existing version's created (backend#3281)" {
  package_into _new client 1.0.0
  NEW_CHARTS_DIR=_new REPO_URL="$REPO_URL" OUT_INDEX=index.yaml MERGE_INDEX= bash "$PUB"
  local first
  first="$(created_for 1.0.0)"
  [ -n "$first" ] || return 1

  # A distinct wall-clock second, so a re-stamp to "now" would be visible.
  sleep 2
  rm -rf _new
  package_into _new client 1.0.1
  NEW_CHARTS_DIR=_new REPO_URL="$REPO_URL" OUT_INDEX=index.yaml MERGE_INDEX=index.yaml bash "$PUB"

  grep -q 'version: 1.0.1' index.yaml || return 1   # the new version is added
  grep -q 'version: 1.0.0' index.yaml || return 1   # the old one is still there
  local kept
  kept="$(created_for 1.0.0)"
  # ...and its created did NOT move — the whole point of the fix.
  [ "$kept" = "$first" ] || return 1
}

@test "both charts built in one release are indexed" {
  # The release packages client AND ingestor together; both must land in the
  # shared index (the reason the old step indexed the whole dir).
  package_into _new client 1.0.0
  package_into _new ingestor 0.3.0
  NEW_CHARTS_DIR=_new REPO_URL="$REPO_URL" OUT_INDEX=index.yaml MERGE_INDEX= bash "$PUB"
  grep -q 'version: 1.0.0' index.yaml || return 1
  grep -q 'version: 0.3.0' index.yaml || return 1
}

@test "an empty new-charts dir fails closed" {
  # A release that reached the index step with nothing to publish is an upstream
  # bug; refuse rather than rewrite the index from an empty directory.
  mkdir -p _empty
  run env NEW_CHARTS_DIR=_empty REPO_URL="$REPO_URL" OUT_INDEX=index.yaml MERGE_INDEX= bash "$PUB"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"nothing to publish"* ]] || return 1
}
