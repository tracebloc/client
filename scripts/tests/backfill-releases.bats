#!/usr/bin/env bats
# scripts/backfill-releases.sh — the one-shot historical backfill of releases to
# the public mirror, and of the Helm index the mirror serves for them.
#
# Offline. `gh` is a recording FAKE on PATH that serves a source repository's
# releases, tags, assets and Pages index from a fixture directory and keeps the
# mirror's state (tags, releases, uploaded assets with their digests and bytes)
# in files it mutates on every write, so a second run sees what the first one
# created. Every call is logged; a WRITE is any `api -X POST|PATCH` or
# `release upload` line. gitleaks is a stub (the guard needs one on PATH; the
# real scanner is the workflow's business). The Pages branch is a REAL bare
# repository over file://, so the index push is publish-mirror's production
# `tree` path, not a shim of it. helm is the real one (the `Unit tests` job
# installs it): the index is built and read back by the tool a customer's
# `helm repo add` will trust.
#
# Pinned: dry-run writes nothing; --apply makes exactly the expected writes,
# oldest release first, newest stable last and marked latest; a second --apply
# writes nothing; every release carries every asset by default and BINARY_KEEP
# cuts tarballs when asked; a tarball whose bytes disagree with the source's
# digest, or with the source's Helm index, or that has no source digest at all,
# is refused by name and nothing of that release is written; an unset mirror or
# one equal to the source is refused by publish-mirror's rule; a read that fails
# is could-not-tell (exit 2) naming the call, never an empty list; the default
# notes are the workflow's fixed text and a refuse-tier needle in a source body
# refuses only under --notes source, naming the tier; an annotated source tag's
# message is carried onto the mirror's tag and goes through the same guard, so a
# refuse-tier needle there refuses the release in either notes mode; --pages builds the index
# from the MIRROR's stable releases with release-asset URLs, one entry per chart
# version under the oldest release carrying it, `created` = the original publish
# date, keeps every other file on gh-pages, and pushes nothing when the index is
# unchanged; a missing helm refuses --pages before any gh call.
#
# Mutations: `mutant NAME REPL` copies the script with the `# mutation-anchor:
# NAME` line replaced, PROVES the copy differs and parses, and the test then
# shows the bad outcome the real script refuses — so the assertion it pairs
# with is live, not vacuous. Every standalone assertion ends in `|| return 1`
# (bats-hygiene.bats).

SCRIPTS_DIR=""
REAL=""
SHIM=""
PAGES_BARE=""

# ── fixtures, built once per file ─────────────────────────────────────────────
# Six stable releases v1.0.0..v1.0.5 (a day apart) and one newer prerelease
# v1.0.6-rc.1. Each carries client-<ver>.tgz, ingestor-0.2.0.tgz (the same
# bytes every time), install.sh, install.ps1, manifest.sha256 and its .sig /
# .cert / .bundle. v1.0.1 ALSO carries client-1.0.0.tgz (older releases attached
# every chart published so far). v1.0.3's source tag is annotated. The fixture
# list is deliberately NOT in date order. The source's Pages index lists the six
# stable client versions and the ingestor with their real digests.
STABLE=(v1.0.0 v1.0.1 v1.0.2 v1.0.3 v1.0.4 v1.0.5)
PRE=v1.0.6-rc.1
HEAD_SHA=1111111111111111111111111111111111111111
ANNOT_TAG=v1.0.3; ANNOT_DATE=2025-12-31T10:00:00Z; ANNOT_MSG="tracebloc client v1.0.3 original annotation"

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# chart_tgz DIR NAME VERSION — a packaged chart at DIR/NAME-VERSION.tgz, built
# by `helm package` the way the release workflow builds the real ones (a hand
# tar on macOS carries AppleDouble `._` entries helm rejects). Built once per
# file, so a chart is the same bytes wherever the fixtures carry it.
chart_tgz() {
  local dir="$1" name="$2" ver="$3" src="$BATS_FILE_TMPDIR/chart-src-$name-$ver"
  mkdir -p "$src" "$dir"
  printf 'apiVersion: v2\nname: %s\nversion: %s\ndescription: fixture chart\n' "$name" "$ver" >"$src/Chart.yaml"
  helm package "$src" --destination "$dir" >/dev/null
  [ -f "$dir/$name-$ver.tgz" ] || { echo "helm package did not produce $dir/$name-$ver.tgz" >&2; return 1; }
}

# build_fixtures DIR — the source repository acme/src as the fake gh serves it.
build_fixtures() {
  local fix="$1" i tag pre body created f
  mkdir -p "$fix/assets"
  printf 'acme/src' >"$fix/src-repo"; printf 'acme/mirror' >"$fix/mirror-repo"; printf '%s' "$HEAD_SHA" >"$fix/mirror-head"
  : >"$fix/releases.ndjson"; : >"$fix/tags.ndjson"; printf '[]' >"$fix/src-tagobjs.json"
  chart_tgz "$fix/charts" ingestor 0.2.0
  i=0
  for tag in "${STABLE[@]}" "$PRE"; do
    i=$((i + 1)); mkdir -p "$fix/assets/$tag"
    chart_tgz "$fix/charts" client "${tag#v}"
    cp "$fix/charts/client-${tag#v}.tgz" "$fix/charts/ingestor-0.2.0.tgz" "$fix/assets/$tag/"
    [ "$tag" != v1.0.1 ] || cp "$fix/charts/client-1.0.0.tgz" "$fix/assets/$tag/"
    printf '#!/bin/sh\necho install %s\n' "$tag" >"$fix/assets/$tag/install.sh"
    printf 'Write-Host install %s\n' "$tag" >"$fix/assets/$tag/install.ps1"
    printf '%s  scripts/install-k8s.sh\n' "$(printf 'k8s %s' "$tag" | sha256_of /dev/stdin)" >"$fix/assets/$tag/manifest.sha256"
    printf 'MEUCIQ%s\n' "$tag" >"$fix/assets/$tag/manifest.sha256.sig"
    printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "$tag" >"$fix/assets/$tag/manifest.sha256.cert"
    printf '{"mediaType":"application/vnd.dev.sigstore.bundle+json;version=0.1","tag":"%s"}\n' "$tag" >"$fix/assets/$tag/manifest.sha256.bundle"
    pre=false; [ "$tag" = "$PRE" ] && pre=true
    created="$(printf '2026-01-%02dT12:00:00Z' "$i")"
    body="## What's Changed\n* fix: something in $tag by @dev in https://github.com/acme/src/pull/$i"
    ( cd "$fix/assets/$tag" && for f in *; do printf '%s\t%s\t%s\n' "$f" "sha256:$(sha256_of "$f")" "$(wc -c <"$f" | tr -d ' ')"; done ) \
      | jq -R -s -c --arg tag "$tag" --arg pre "$pre" --arg created "$created" --arg body "$(printf "$body")" '
          split("\n") | map(select(length > 0) | split("\t") | {name: .[0], digest: .[1], size: (.[2]|tonumber)}) as $assets
          | {tag_name: $tag, name: $tag, body: $body, draft: false, prerelease: ($pre == "true"), created_at: $created, published_at: $created, target_commitish: "develop", assets: $assets}' >>"$fix/releases.ndjson"
    if [ "$tag" = "$ANNOT_TAG" ]; then
      jq -n -c --arg t "$tag" '{ref: ("refs/tags/" + $t), object: {sha: "3333333333333333333333333333333333333333", type: "tag"}}' >>"$fix/tags.ndjson"
      jq -n --arg m "$ANNOT_MSG" --arg d "$ANNOT_DATE" '[{sha: "3333333333333333333333333333333333333333", message: $m, tagger: {name: "dev", date: $d}, object: {sha: "cccccccccccccccccccccccccccccccccccccccc", type: "commit"}}]' >"$fix/src-tagobjs.json"
    else
      jq -n -c --arg t "$tag" --argjson i "$i" '{ref: ("refs/tags/" + $t), object: {sha: ("c" * 39 + ($i|tostring)|.[0:40]), type: "commit"}}' >>"$fix/tags.ndjson"
    fi
  done
  # Shuffle the release order (newest in the middle) so sorting is the script's, not the fixture's.
  jq -s '[.[6], .[2], .[0], .[5], .[3], .[1], .[4]]' "$fix/releases.ndjson" >"$fix/src-releases.json"
  jq -s '.' "$fix/tags.ndjson" >"$fix/src-tags.json"
  # The source's Pages index, helm's shape, newest first, real digests.
  {
    printf 'apiVersion: v1\nentries:\n  client:\n'
    for tag in v1.0.5 v1.0.4 v1.0.3 v1.0.2 v1.0.1 v1.0.0; do
      printf '  - apiVersion: v2\n    created: "2026-01-01T00:00:00Z"\n    digest: %s\n    name: client\n    urls:\n    - https://acme.github.io/src/client-%s.tgz\n    version: %s\n' "$(sha256_of "$fix/charts/client-${tag#v}.tgz")" "${tag#v}" "${tag#v}"
    done
    printf '  ingestor:\n  - apiVersion: v2\n    created: "2026-01-01T00:00:00Z"\n    digest: %s\n    name: ingestor\n    urls:\n    - https://acme.github.io/src/ingestor-0.2.0.tgz\n    version: 0.2.0\n' "$(sha256_of "$fix/charts/ingestor-0.2.0.tgz")"
    printf 'generated: "2026-01-07T12:00:00Z"\n'
  } >"$fix/src-index.yaml"
}

# variant NAME JQ_FILTER — a copy of the base fixture with its release list
# rewritten by JQ_FILTER (variants that only touch metadata).
variant() {
  local dir="$BATS_FILE_TMPDIR/fix-$1"
  cp -R "$BATS_FILE_TMPDIR/fix" "$dir"
  jq "$2" "$dir/src-releases.json" >"$dir/t.json" && mv "$dir/t.json" "$dir/src-releases.json"
}

setup_file() {
  command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm is required: the index is built and read back by the real tool" >&2; return 1; }
  export FIX="$BATS_FILE_TMPDIR/fix"
  build_fixtures "$FIX"
  # v1.0.5's own chart tarball is listed with a digest that is not its bytes.
  variant corrupt '(.[] | select(.tag_name == "v1.0.5") | .assets[] | select(.name == "client-1.0.5.tgz") | .digest) = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
  # v1.0.2's body carries a refuse-tier needle.
  variant badbody '(.[] | select(.tag_name == "v1.0.2") | .body) |= . + "\n* ops: moved to role arn:aws:iam::000000000000:role/planted"'
  # v1.0.1's chart tarball has no digest on the source at all.
  variant nodigest '(.[] | select(.tag_name == "v1.0.1") | .assets[] | select(.name == "client-1.0.1.tgz") | .digest) = null'
  # The annotated source tag's (v1.0.3) message carries a refuse-tier needle; the release body is clean.
  variant badtag '.'
  jq '(.[] | select(.sha == "3333333333333333333333333333333333333333") | .message) |= . + "\nrole arn:aws:iam::000000000000:role/planted"' \
    "$BATS_FILE_TMPDIR/fix-badtag/src-tagobjs.json" >"$BATS_FILE_TMPDIR/fix-badtag/t.json" && mv "$BATS_FILE_TMPDIR/fix-badtag/t.json" "$BATS_FILE_TMPDIR/fix-badtag/src-tagobjs.json"
  grep -q 'role/planted' "$BATS_FILE_TMPDIR/fix-badtag/src-tagobjs.json" || { echo "badtag fixture did not apply" >&2; return 1; }
  # The source's Pages index lists client 1.0.4 with a digest that is not the tarball's.
  variant idxbad '.'
  awk -v d="$(sha256_of "$FIX/charts/client-1.0.4.tgz")" '$0 == "    digest: " d { print "    digest: 1111111111111111111111111111111111111111111111111111111111111111"; next } { print }' \
    "$FIX/src-index.yaml" >"$BATS_FILE_TMPDIR/fix-idxbad/src-index.yaml"
  grep -q '1111111111111111111111111111111111111111111111111111111111111111' "$BATS_FILE_TMPDIR/fix-idxbad/src-index.yaml" || { echo "idxbad fixture did not apply" >&2; return 1; }
  export FIX_CORRUPT="$BATS_FILE_TMPDIR/fix-corrupt" FIX_BADBODY="$BATS_FILE_TMPDIR/fix-badbody" FIX_NODIGEST="$BATS_FILE_TMPDIR/fix-nodigest" FIX_IDXBAD="$BATS_FILE_TMPDIR/fix-idxbad" FIX_BADTAG="$BATS_FILE_TMPDIR/fix-badtag"
}

# ── per test: the fake gh, the gitleaks stub, an empty mirror ──────────────────
setup() {
  SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  REAL="$SCRIPTS_DIR/backfill-releases.sh"
  SHIM="$BATS_TEST_TMPDIR/shim"; mkdir -p "$SHIM"
  cat >"$SHIM/gitleaks" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && { echo "gitleaks-stub"; exit 0; }
exit 0
EOF
  cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
# Recording fake gh. FIX: fixtures (read-only). STATE: the mirror, mutated by writes.
set -uo pipefail
FIX="${FAKE_GH_FIX:?}"; STATE="${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [ -n "${FAKE_GH_FAIL_RE:-}" ] && [[ "$*" =~ $FAKE_GH_FAIL_RE ]]; then echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; fi
# A call that "succeeds" with a body that is not JSON — the answer jq must refuse.
if [ -n "${FAKE_GH_GARBLE_RE:-}" ] && [[ "$*" =~ $FAKE_GH_GARBLE_RE ]]; then echo '<html>not json'; exit 0; fi
SRC="$(cat "$FIX/src-repo")"; MIRROR="$(cat "$FIX/mirror-repo")"; HEAD_SHA="$(cat "$FIX/mirror-head")"
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
fake_sha() { printf '%s' "$1" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -c1-40; }
notfound() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
fieldval() { # KEY from -f/-F pairs; @file is read
  local k="$1" f v
  for f in "${FIELDS[@]+"${FIELDS[@]}"}"; do
    case "$f" in "$k="*) v="${f#*=}"; case "$v" in @*) cat "${v#@}" ;; *) printf '%s' "$v" ;; esac; return 0 ;; esac
  done
  return 1
}
# make_latest is a STRING enum in the releases API; a typed boolean is a 422.
make_latest_typed() { local t; for t in "${TYPED[@]+"${TYPED[@]}"}"; do [ "$t" = make_latest ] && return 0; done; return 1; }
reject_typed_make_latest() { ! make_latest_typed || { echo "gh: HTTP 422: Invalid request. For 'properties/make_latest', true is not a string." >&2; exit 1; }; }
cmd="${1:-}"; shift || true
case "$cmd" in
  repo)
    printf '{"nameWithOwner":"%s"}\n' "$SRC" ;;
  api)
    METHOD=GET; PATHP=""; FIELDS=(); TYPED=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --paginate) shift ;;
        -f) FIELDS+=("$2"); shift 2 ;;
        -F) FIELDS+=("$2"); TYPED+=("${2%%=*}"); shift 2 ;;
        *) PATHP="$1"; shift ;;
      esac
    done
    case "$METHOD $PATHP" in
      "GET repos/$SRC/releases")
        jq -c '.[0:4]' "$FIX/src-releases.json"; jq -c '.[4:]' "$FIX/src-releases.json" ;;
      "GET repos/$SRC/contents/index.yaml?ref=gh-pages")
        [ -z "${FAKE_GH_NO_SRC_INDEX:-}" ] || notfound
        jq -n --arg c "$(base64 <"$FIX/src-index.yaml" | tr -d '\n')" '{name: "index.yaml", encoding: "base64", content: $c}' ;;
      "GET repos/$SRC/git/ref/tags/"*)
        t="${PATHP##*/}"; jq -e --arg r "refs/tags/$t" '.[] | select(.ref == $r)' "$FIX/src-tags.json" >/dev/null || notfound
        jq --arg r "refs/tags/$t" '.[] | select(.ref == $r)' "$FIX/src-tags.json" ;;
      "GET repos/$SRC/git/tags/"*)
        s="${PATHP##*/}"; jq -e --arg s "$s" '.[] | select(.sha == $s)' "$FIX/src-tagobjs.json" >/dev/null || notfound
        jq --arg s "$s" '.[] | select(.sha == $s)' "$FIX/src-tagobjs.json" ;;
      "GET repos/$MIRROR")
        printf '{"full_name":"%s","default_branch":"main","visibility":"public"}\n' "$MIRROR" ;;
      "GET repos/$MIRROR/commits/main")
        [ -z "${FAKE_GH_EMPTY_MIRROR:-}" ] || { echo "gh: Git Repository is empty. (HTTP 409)" >&2; exit 1; }
        printf '{"sha":"%s"}\n' "$HEAD_SHA" ;;
      "GET repos/$MIRROR/releases")
        cat "$STATE/mirror-releases.json" ;;
      "GET repos/$MIRROR/git/matching-refs/tags/")
        cat "$STATE/mirror-tags.json" ;;
      "GET repos/$MIRROR/git/commits/"*)
        s="${PATHP##*/}"; [ "$s" = "$HEAD_SHA" ] || notfound; printf '{"sha":"%s"}\n' "$s" ;;
      "GET repos/$MIRROR/git/tags/"*)
        s="${PATHP##*/}"; jq -e --arg s "$s" '.[] | select(.sha == $s)' "$STATE/mirror-tagobjs.json" >/dev/null || notfound
        jq --arg s "$s" '.[] | select(.sha == $s)' "$STATE/mirror-tagobjs.json" ;;
      "POST repos/$MIRROR/git/tags")
        tag="$(fieldval tag)"; msg="$(fieldval message)"; obj="$(fieldval object)"; date="$(fieldval 'tagger[date]')"
        s="$(fake_sha "tagobj:$tag")"
        jq --arg s "$s" --arg tag "$tag" --arg msg "$msg" --arg obj "$obj" --arg date "$date" \
          '. + [{sha: $s, tag: $tag, message: $msg, tagger: {date: $date}, object: {sha: $obj, type: "commit"}}]' "$STATE/mirror-tagobjs.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-tagobjs.json"
        printf '{"sha":"%s"}\n' "$s" ;;
      "POST repos/$MIRROR/git/refs")
        ref="$(fieldval ref)"; s="$(fieldval sha)"
        jq -e --arg r "$ref" '.[] | select(.ref == $r)' "$STATE/mirror-tags.json" >/dev/null && { echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; }
        jq --arg r "$ref" --arg s "$s" '. + [{ref: $r, object: {sha: $s, type: "tag"}}]' "$STATE/mirror-tags.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-tags.json"
        printf '{"ref":"%s"}\n' "$ref" ;;
      "POST repos/$MIRROR/releases")
        reject_typed_make_latest
        tag="$(fieldval tag_name)"; name="$(fieldval name)"; body="$(fieldval body)"; pre="$(fieldval prerelease)"; latest="$(fieldval make_latest)"
        jq -e --arg r "refs/tags/$tag" '.[] | select(.ref == $r)' "$STATE/mirror-tags.json" >/dev/null || { echo "gh: fake: release for '$tag' before its tag (HTTP 422)" >&2; exit 1; }
        id="$(jq 'length + 1' "$STATE/mirror-releases.json")"
        jq --argjson id "$id" --arg tag "$tag" --arg name "$name" --arg body "$body" --arg pre "$pre" --arg latest "$latest" \
          '. + [{id: $id, tag_name: $tag, name: $name, body: $body, prerelease: ($pre == "true"), make_latest: $latest, draft: false, created_at: "2026-09-01T00:00:00Z", assets: []}]' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
        printf '{"id":%s,"tag_name":"%s"}\n' "$id" "$tag" ;;
      "PATCH repos/$MIRROR/releases/"*)
        reject_typed_make_latest
        id="${PATHP##*/}"; latest="$(fieldval make_latest)"
        [[ "$id" =~ ^[0-9]+$ ]] || notfound
        jq -e --argjson id "$id" '.[] | select(.id == $id)' "$STATE/mirror-releases.json" >/dev/null || notfound
        jq --argjson id "$id" --arg latest "$latest" 'map(if .id == $id then .make_latest = $latest else . end)' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
        printf '{"id":%s}\n' "$id" ;;
      *) echo "gh: fake: unhandled $METHOD $PATHP" >&2; exit 1 ;;
    esac ;;
  release)
    sub="${1:-}"; shift || true
    case "$sub" in
      download)
        tag="$1"; shift; repo=""; dir=""; pats=()
        while [ "$#" -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; --dir) dir="$2"; shift 2 ;; --pattern) pats+=("$2"); shift 2 ;; *) echo "gh: fake: unknown download arg $1" >&2; exit 1 ;; esac; done
        if [ "$repo" = "$SRC" ]; then from="$FIX/assets/$tag"
        elif [ "$repo" = "$MIRROR" ]; then
          jq -e --arg t "$tag" '.[] | select(.tag_name == $t)' "$STATE/mirror-releases.json" >/dev/null || { echo "gh: release not found" >&2; exit 1; }
          from="$STATE/assets/$tag"
        else echo "gh: fake: download from '$repo' is neither source nor mirror" >&2; exit 1; fi
        mkdir -p "$dir"
        for p in "${pats[@]}"; do
          [ -f "$from/$p" ] || { echo "gh: no assets match the file pattern ($p)" >&2; exit 1; }
          [ ! -e "$dir/$p" ] || { echo "gh: fake: $dir/$p already exists (gh refuses without --clobber)" >&2; exit 1; }
          cp "$from/$p" "$dir/$p"
        done ;;
      upload)
        tag="$1"; shift; repo=""; files=()
        while [ "$#" -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) files+=("$1"); shift ;; esac; done
        [ "$repo" = "$MIRROR" ] || { echo "gh: fake: upload to '$repo' is not the mirror" >&2; exit 1; }
        jq -e --arg t "$tag" '.[] | select(.tag_name == $t)' "$STATE/mirror-releases.json" >/dev/null || { echo "gh: release not found" >&2; exit 1; }
        mkdir -p "$STATE/assets/$tag"
        for f in "${files[@]}"; do
          [ -f "$f" ] || { echo "gh: fake: $f is not a file" >&2; exit 1; }
          n="$(basename "$f")"; d="$(sha "$f")"
          jq -e --arg t "$tag" --arg n "$n" '.[] | select(.tag_name == $t) | .assets[] | select(.name == $n)' "$STATE/mirror-releases.json" >/dev/null && { echo "gh: fake: asset '$n' already on '$tag' (HTTP 422)" >&2; exit 1; }
          cp "$f" "$STATE/assets/$tag/$n"
          jq --arg t "$tag" --arg n "$n" --arg d "sha256:$d" 'map(if .tag_name == $t then .assets += [{name: $n, digest: $d}] else . end)' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
        done ;;
      *) echo "gh: fake: unhandled release $sub" >&2; exit 1 ;;
    esac ;;
  *) echo "gh: fake: unhandled command $cmd" >&2; exit 1 ;;
esac
EOF
  chmod +x "$SHIM/gh" "$SHIM/gitleaks"
  STATE="$BATS_TEST_TMPDIR/state"; fresh_state "$STATE"
  PAGES_BARE="$BATS_TEST_TMPDIR/pages.git"; git init -q --bare "$PAGES_BARE"
}

fresh_state() { mkdir -p "$1"; printf '[]' >"$1/mirror-releases.json"; printf '[]' >"$1/mirror-tags.json"; printf '[]' >"$1/mirror-tagobjs.json"; }

# backfill [FIX_DIR] ARGS... — the script (or BACKFILL_UNDER_TEST) with the fake
# gh against $STATE. A first argument that is a directory is the fixture set.
backfill() {
  local fix="$FIX"
  if [ "$#" -gt 0 ] && [ -d "$1" ]; then fix="$1"; shift; fi
  GH_LOG="$BATS_TEST_TMPDIR/gh-$RANDOM$RANDOM.log"; : >"$GH_LOG"
  run env PATH="$SHIM:$PATH" GH_LOG="$GH_LOG" FAKE_GH_FIX="$fix" FAKE_GH_STATE="$STATE" PUBLISH_GUARD_GITLEAKS="$SHIM/gitleaks" \
    BACKFILL_SCRIPTS_DIR="$SCRIPTS_DIR" BACKFILL_PAGES_REMOTE="file://$PAGES_BARE" \
    SOURCE_REPO="${SOURCE_REPO-acme/src}" MIRROR_REPO="${MIRROR_REPO-mirror}" BINARY_KEEP="${BINARY_KEEP-all}" \
    bash "${BACKFILL_UNDER_TEST:-$REAL}" "$@"
}
writes()   { grep -cE '^(api -X (POST|PATCH)|release upload) ' "$GH_LOG" || true; }
posts()    { grep -c "^api -X POST repos/acme/mirror/$1 " "$GH_LOG" || true; }
verdicts() { printf '%s\n' "$output" | awk -v v="$1" '$NF == v && $1 ~ /^v[0-9]/ { n++ } END { print n + 0 }'; }
mirror_assets() { jq -r --arg t "$1" '.[] | select(.tag_name == $t) | [.assets[].name] | sort | join(" ")' "$STATE/mirror-releases.json"; }
pages_file() { git -C "$PAGES_BARE" show "gh-pages:$1"; }
pages_commits() { git -C "$PAGES_BARE" rev-list --count gh-pages; }
# The `created` of a version in a helm index on stdin (see publish-helm-index.bats).
created_for() { awk -v want="$1" '/^  - / { if (v != "") c[v] = cr; v = ""; cr = "" } /^    version:/ { v = $2 } /^    created:/ { cr = $2 } END { if (v != "") c[v] = cr; print c[want] }'; }
url_for() { awk -v want="$1" '/^  - / { if (v != "") c[v] = u; v = ""; u = "" } /^    version:/ { v = $2 } /^    - https/ { u = $2 } END { if (v != "") c[v] = u; print c[want] }'; }

# mutant NAME REPLACEMENT — a copy of the real script with the line carrying
# `# mutation-anchor: NAME` replaced by REPLACEMENT; prints its path. Refuses
# (return 1) unless the anchor was found exactly once, the copy differs and
# still parses — an inert mutation and real coverage look identical in a log.
mutant() {
  local name="$1" repl="$2" copy="$BATS_TEST_TMPDIR/mutant-$name.sh" n
  n="$(grep -c -- "# mutation-anchor: $name\$" "$REAL")"
  [ "$n" -eq 1 ] || { echo "anchor $name found $n time(s), need exactly 1"; return 1; }
  awk -v a="# mutation-anchor: $name" -v r="$repl" 'index($0, a) && substr($0, length($0) - length(a) + 1) == a { print r; next } { print }' "$REAL" >"$copy"
  cmp -s "$REAL" "$copy" && { echo "mutation $name did not change the script"; return 1; }
  bash -n "$copy" || { echo "mutant $name does not parse"; return 1; }
  printf '%s\n' "$copy"
}

# ── dry-run ───────────────────────────────────────────────────────────────────

@test "dry-run (default): every read runs, text assets are fetched for the guard, no tarball is, zero writes, 7 rows planned" {
  backfill
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
  [ "$(verdicts planned)" -eq 7 ] || { echo "$output"; return 1; }
  [[ "$output" == *"7 release(s) match the filter (stable and prerelease), 7 in this run; tarballs for every release; notes=fixed; pages=0; mode=dry-run"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"v1.0.0 [stable] would: tag: create | release: create | text: 6 up/0 skip | tarballs: 2 up/0 skip |"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"v1.0.1 [stable] would: tag: create | release: create | text: 6 up/0 skip | tarballs: 3 up/0 skip |"* ]] || return 1
  [[ "$output" == *"v1.0.6-rc.1 [prerelease] would: tag: create | release: create | text: 6 up/0 skip | tarballs: 2 up/0 skip |"* ]] || return 1
  grep -q '^release download v1.0.5 --repo acme/src --dir .*/text --pattern .*--pattern install.sh' "$GH_LOG" || { grep 'release download' "$GH_LOG"; return 1; }
  ! grep -q -- '--pattern client-' "$GH_LOG" || return 1
  ! grep -q -- '--pattern ingestor-' "$GH_LOG" || return 1
  # The source's Helm index is read (the chart manifest), never guessed.
  grep -q '^api repos/acme/src/contents/index.yaml?ref=gh-pages$' "$GH_LOG" || return 1
  [ "$(jq length "$STATE/mirror-releases.json")" -eq 0 ] || return 1
  [ "$(jq length "$STATE/mirror-tags.json")" -eq 0 ] || return 1
}

@test "dry-run: the byte total is derived from the source's asset sizes" {
  backfill
  [ "$status" -eq 0 ] || return 1
  local expect
  expect="$(jq '[.[] | .assets[].size] | add' "$FIX/src-releases.json")"
  [[ "$output" == *"7 planned, 0 already complete, 0 refused; $expect bytes of assets planned"* ]] || { echo "$output"; return 1; }
}

# ── apply ─────────────────────────────────────────────────────────────────────

@test "apply: 7 releases → exactly 28 writes (tag object, ref, release, one upload call each), every asset carried, all 7 done" {
  backfill --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 28 ] || { echo "writes=$(writes)"; cat "$GH_LOG"; return 1; }
  [ "$(posts git/tags)" -eq 7 ] || return 1
  [ "$(posts git/refs)" -eq 7 ] || return 1
  [ "$(posts releases)" -eq 7 ] || return 1
  [ "$(grep -c '^release upload ' "$GH_LOG")" -eq 7 ] || return 1
  [ "$(verdicts "done")" -eq 7 ] || return 1
  [[ "$output" == *"7 release(s) in this run — 7 written, 0 already complete, 0 refused"* ]] || return 1
  [ "$(mirror_assets v1.0.0)" = "client-1.0.0.tgz ingestor-0.2.0.tgz install.ps1 install.sh manifest.sha256 manifest.sha256.bundle manifest.sha256.cert manifest.sha256.sig" ] || { mirror_assets v1.0.0; return 1; }
  [ "$(mirror_assets v1.0.1)" = "client-1.0.0.tgz client-1.0.1.tgz ingestor-0.2.0.tgz install.ps1 install.sh manifest.sha256 manifest.sha256.bundle manifest.sha256.cert manifest.sha256.sig" ] || return 1
  [ "$(mirror_assets v1.0.6-rc.1)" = "client-1.0.6-rc.1.tgz ingestor-0.2.0.tgz install.ps1 install.sh manifest.sha256 manifest.sha256.bundle manifest.sha256.cert manifest.sha256.sig" ] || return 1
  # The bytes on the mirror are the source's bytes.
  cmp -s "$FIX/assets/v1.0.5/client-1.0.5.tgz" "$STATE/assets/v1.0.5/client-1.0.5.tgz" || return 1
  [[ "$output" == *"v1.0.5 [stable]: tag: create | release: create | text: 6 up/0 skip | tarballs: 2 up/0 skip |"*"(2 tarball(s) also matched the source's Helm index)"* ]] || { echo "$output"; return 1; }
  # The rc's own chart is not in the source's index (prereleases never are); the ingestor it carries is.
  [[ "$output" == *"v1.0.6-rc.1 [prerelease]: "*"(1 tarball(s) also matched the source's Helm index)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"v1.0.1 [stable]: "*"tarballs: 3 up/0 skip |"*"(3 tarball(s) also matched the source's Helm index)"* ]] || return 1
}

@test "apply: oldest first, newest STABLE last and the only make_latest=true; the prerelease is created as one and never latest; tag before release before upload" {
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  local first last rc
  first="$(grep '^api -X POST repos/acme/mirror/releases ' "$GH_LOG" | head -1)"
  last="$(grep '^api -X POST repos/acme/mirror/releases ' "$GH_LOG" | tail -1)"
  rc="$(grep -- '-f tag_name=v1.0.6-rc.1 ' "$GH_LOG")"
  [[ "$first" == *"-f tag_name=v1.0.0 "*"-f make_latest=false"* ]] || { echo "$first"; return 1; }
  [[ "$last" == *"-f tag_name=v1.0.6-rc.1 "*"-F prerelease=true"*"-f make_latest=false"* ]] || { echo "$last"; return 1; }
  [[ "$(grep -- '-f tag_name=v1.0.5 ' "$GH_LOG")" == *"-f make_latest=true"* ]] || return 1
  [ "$(grep -c -- '-f make_latest=true' "$GH_LOG")" -eq 1 ] || return 1
  [ "$(grep -c -- '-F prerelease=true' "$GH_LOG")" -eq 1 ] || return 1
  [ -n "$rc" ] || return 1
  [ "$(grep -nE '^(api -X POST repos/acme/mirror/(git/tags|git/refs|releases)|release upload) ' "$GH_LOG" | head -4 | sed -E 's/^[0-9]+://; s/ .*//' | paste -sd' ' -)" = "api api api release" ] || { head -8 "$GH_LOG"; return 1; }
  [ "$(jq -r '.[] | .tag_name' "$STATE/mirror-releases.json" | paste -sd' ' -)" = "${STABLE[*]} $PRE" ] || return 1
}

@test "tags: every mirror tag is an annotated marker on the mirror head with the original date; an annotated source tag's message is carried" {
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  local tag0 tag3
  tag0="$(jq -c '.[] | select(.tag == "v1.0.0")' "$STATE/mirror-tagobjs.json")"; tag3="$(jq -c '.[] | select(.tag == "v1.0.3")' "$STATE/mirror-tagobjs.json")"
  [ "$(printf '%s' "$tag0" | jq -r .object.sha)" = "$HEAD_SHA" ] || return 1
  [ "$(printf '%s' "$tag0" | jq -r .tagger.date)" = "2026-01-01T12:00:00Z" ] || return 1
  [[ "$(printf '%s' "$tag0" | jq -r .message)" == *"Mirror release marker for v1.0.0"*"not at the sources"* ]] || return 1
  [ "$(printf '%s' "$tag3" | jq -r .tagger.date)" = "$ANNOT_DATE" ] || return 1
  [[ "$(printf '%s' "$tag3" | jq -r .message)" == *"--- original tag message ---"*"$ANNOT_MSG"* ]] || return 1
  [ "$(jq -r '[.[] | .object.sha] | unique | length' "$STATE/mirror-tagobjs.json")" -eq 1 ] || return 1
}

@test "notes (default): the workflow's fixed client text plus an original-date footer, no trace of the source body" {
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  local body0
  body0="$(jq -r '.[] | select(.tag_name == "v1.0.0") | .body' "$STATE/mirror-releases.json")"
  [[ "$body0" == "tracebloc client v1.0.0."*"cosign-signed installer manifest"*"docs/SUPPLY_CHAIN.md"*"originally published 2026-01-01T12:00:00Z"* ]] || { echo "$body0"; return 1; }
  [[ "$body0" != *"What's Changed"* ]] || return 1
  [[ "$body0" != *"acme/src/pull/"* ]] || return 1
  [[ "$body0" != *"Chart tarballs are carried only"* ]] || return 1
  [[ "$output" == *"notes=fixed"* ]] || return 1
}

@test "--notes source carries the source body with the same footer, only when asked; anything else is could-not-tell" {
  backfill --apply --notes source
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local body0
  body0="$(jq -r '.[] | select(.tag_name == "v1.0.0") | .body' "$STATE/mirror-releases.json")"
  [[ "$body0" == "## What's Changed"*"acme/src/pull/1"*"originally published 2026-01-01T12:00:00Z"* ]] || { echo "$body0"; return 1; }
  [[ "$body0" != *"tracebloc client v1.0.0."* ]] || return 1
  backfill --notes generated
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--notes must be 'fixed' or 'source', not 'generated'"* ]] || return 1
  [ ! -s "$GH_LOG" ] || return 1
}

@test "idempotent: a second --apply over the same mirror makes zero writes, downloads nothing it can compare by digest, reports 7 already complete" {
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  local before after
  before="$(cat "$STATE/mirror-releases.json" "$STATE/mirror-tags.json" | sha256_of /dev/stdin)"
  backfill --apply
  after="$(cat "$STATE/mirror-releases.json" "$STATE/mirror-tags.json" | sha256_of /dev/stdin)"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
  [ "$(verdicts skipped)" -eq 7 ] || return 1
  [[ "$output" == *"7 release(s) in this run — 0 written, 7 already complete, 0 refused"* ]] || return 1
  [ "$before" = "$after" ] || return 1
  ! grep -q '^release download ' "$GH_LOG" || return 1
}

@test "mutation: with the equal-digest skip removed, the second --apply refuses every release as 'already on the mirror' — the idempotency test catches it" {
  local m
  m="$(mutant idempotent-skip ':')" || { echo "$m"; return 1; }
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  BACKFILL_UNDER_TEST="$m" backfill --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(verdicts refused)" -eq 7 ] || return 1
  [[ "$output" == *"a published asset is never replaced"* ]] || return 1
}

# ── which releases, which assets ──────────────────────────────────────────────

@test "--stable-only leaves the prerelease out; the default carries it" {
  backfill --stable-only
  [ "$status" -eq 0 ] || return 1
  [ "$(verdicts planned)" -eq 6 ] || return 1
  [[ "$output" == *"6 release(s) match the filter (stable only)"* ]] || return 1
  [[ "$output" != *"v1.0.6-rc.1"* ]] || return 1
  backfill --stable-only --apply
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'v1.0.6-rc.1' "$GH_LOG" || return 1
}

@test "BINARY_KEEP defaults to all; a number cuts tarballs to the newest N of the FULL list and says so in the notes; anything else is could-not-tell" {
  BINARY_KEEP=1 backfill
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"tarballs for the newest 1;"* ]] || return 1
  [[ "$output" == *"v1.0.6-rc.1 [prerelease] would: "*"tarballs: 2 up/0 skip"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"v1.0.5 [stable] would: "*"tarballs: none (older than the newest 1)"* ]] || return 1
  BINARY_KEEP=1 backfill --apply --only-tag v1.0.5
  [ "$status" -eq 0 ] || return 1
  [ "$(mirror_assets v1.0.5)" = "install.ps1 install.sh manifest.sha256 manifest.sha256.bundle manifest.sha256.cert manifest.sha256.sig" ] || return 1
  [[ "$(jq -r '.[] | select(.tag_name == "v1.0.5") | .body' "$STATE/mirror-releases.json")" == *"Chart tarballs are carried only for the newest 1 releases"* ]] || return 1
  BINARY_KEEP=ten backfill
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"BINARY_KEEP 'ten' is neither 'all' nor a non-negative integer"* ]] || return 1
}

# ── tarball verification ──────────────────────────────────────────────────────

@test "sha mismatch: a tarball whose bytes disagree with the source's digest is refused BY NAME, nothing of that release is written, the other 6 go ahead, exit 1" {
  backfill "$FIX_CORRUPT" --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.5 — tarball 'client-1.0.5.tgz' hashes to "*" but the source release's digest is 0000000000000000000000000000000000000000000000000000000000000000 — not uploaded"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts refused)" -eq 1 ] || return 1
  [ "$(verdicts "done")" -eq 6 ] || return 1
  ! grep -E '^(api -X POST|release upload) ' "$GH_LOG" | grep -q 'v1.0.5' || return 1
  [ "$(jq -r '[.[] | select(.tag_name == "v1.0.5")] | length' "$STATE/mirror-releases.json")" -eq 0 ] || return 1
  [[ "$output" == *"1 item(s) were refused"* ]] || return 1
}

@test "sha mismatch on the newest stable: the newest stable release the run did write is marked latest by exactly one PATCH" {
  backfill "$FIX_CORRUPT" --apply
  [ "$status" -eq 1 ] || return 1
  [ "$(grep -c '^api -X PATCH repos/acme/mirror/releases/' "$GH_LOG")" -eq 1 ] || return 1
  [[ "$output" == *"latest: v1.0.5 was refused — marking v1.0.4, the newest stable release written in this run, as latest until v1.0.5 is re-run"* ]] || return 1
  [ "$(jq -r '.[] | select(.tag_name == "v1.0.4") | .make_latest' "$STATE/mirror-releases.json")" = true ] || return 1
  [ "$(jq -r '[.[] | select(.make_latest == "true")] | length' "$STATE/mirror-releases.json")" -eq 1 ] || return 1
  backfill "$FIX_CORRUPT"
  [ "$status" -eq 0 ] || return 1
  [ "$(verdicts planned)" -eq 1 ] || return 1
  [ "$(verdicts skipped)" -eq 6 ] || return 1
}

@test "mutation: with the digest check removed, the corrupt tarball is uploaded and v1.0.5 is 'done' — the sha-mismatch test catches it" {
  local m
  m="$(mutant sha-check ':')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill "$FIX_CORRUPT" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts "done")" -eq 7 ] || return 1
  [[ "$(mirror_assets v1.0.5)" == *"client-1.0.5.tgz"* ]] || return 1
}

@test "index cross-check: a tarball the source's Helm index lists with a different digest is refused naming the asset and the chart version" {
  backfill "$FIX_IDXBAD" --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.4 — tarball 'client-1.0.4.tgz' hashes to "*" but the source's Helm index lists client 1.0.4 as 1111111111111111111111111111111111111111111111111111111111111111 — not uploaded"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts refused)" -eq 1 ] || return 1
  [ "$(verdicts "done")" -eq 6 ] || return 1
  [ "$(jq -r '[.[] | select(.tag_name == "v1.0.4")] | length' "$STATE/mirror-releases.json")" -eq 0 ] || return 1
}

@test "mutation: with the index cross-check removed, the mis-listed tarball goes through — the cross-check test catches it" {
  local m
  m="$(mutant index-cross-check ':')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill "$FIX_IDXBAD" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts "done")" -eq 7 ] || return 1
}

@test "a tarball with no digest on the source cannot be verified and is refused by name; nothing of that release is written" {
  backfill "$FIX_NODIGEST" --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.1 — tarball 'client-1.0.1.tgz' has no digest on the source release — it cannot be verified, so it is not carried"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts refused)" -eq 1 ] || return 1
  [ "$(jq -r '[.[] | select(.tag_name == "v1.0.1")] | length' "$STATE/mirror-releases.json")" -eq 0 ] || return 1
}

@test "mutation: with the no-digest refusal removed, v1.0.1 is written WITHOUT the unverifiable tarball, silently — the test above catches it" {
  local m
  m="$(mutant tarball-digest-required ':')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill "$FIX_NODIGEST" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(mirror_assets v1.0.1)" != *"client-1.0.1.tgz"* ]] || return 1
  [[ "$(mirror_assets v1.0.1)" == *"client-1.0.0.tgz"* ]] || return 1
}

# ── the mirror target ─────────────────────────────────────────────────────────

@test "mirror unset, or equal to the source (any case), is refused by publish-mirror's own rule before any gh call" {
  MIRROR_REPO='' backfill --apply
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"publish-mirror: REFUSED — no mirror repository is configured (MIRROR_REPO is unset)"* ]] || return 1
  [[ "$output" == *"backfill-releases: REFUSED — the mirror target was refused above"* ]] || return 1
  [ ! -s "$GH_LOG" ] || return 1
  MIRROR_REPO=src backfill --apply
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"publish-mirror: REFUSED — mirror 'acme/src' is this repository"* ]] || return 1
  [ ! -s "$GH_LOG" ] || return 1
  MIRROR_REPO=SRC backfill
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"is this repository"* ]] || return 1
}

@test "SOURCE_REPO unset: the source is what gh repo view reports; the script hardcodes no repository name" {
  SOURCE_REPO='' backfill
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"source acme/src → mirror acme/mirror"* ]] || return 1
  [ "$(head -1 "$GH_LOG")" = "repo view --json nameWithOwner" ] || return 1
  ! grep -qE 'tracebloc/client|github\.com/tracebloc' "$REAL" || return 1
}

@test "an empty mirror is refused with instructions — tags are never anchored to an invented commit" {
  FAKE_GH_EMPTY_MIRROR=1 backfill --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — mirror 'acme/mirror' has no commit on 'main' to anchor tags to; publish the deliverable tree first"* ]] || return 1
  [ "$(writes)" -eq 0 ] || return 1
}

# ── reads that fail ───────────────────────────────────────────────────────────

@test "a failing read (source list, mirror list, the source's Helm index, an asset download) is exit 2 naming the call — never 'no releases', never a write" {
  FAKE_GH_FAIL_RE='^api --paginate repos/acme/src/releases$' backfill --apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — gh api --paginate repos/acme/src/releases failed: gh: Internal Server Error (HTTP 500)"* ]] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
  FAKE_GH_FAIL_RE='^api --paginate repos/acme/mirror/releases$' backfill --apply
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — gh api --paginate repos/acme/mirror/releases failed"* ]] || return 1
  [ "$(writes)" -eq 0 ] || return 1
  FAKE_GH_NO_SRC_INDEX=1 backfill --apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — gh api repos/acme/src/contents/index.yaml?ref=gh-pages failed"* ]] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
  FAKE_GH_FAIL_RE='^release download v1.0.2 ' backfill --apply
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — gh release download v1.0.2 --repo acme/src"*"failed"* ]] || return 1
  # The run stopped at v1.0.2: v1.0.0 and v1.0.1 are on the mirror, nothing newer.
  [ "$(jq -r '[.[].tag_name] | join(" ")' "$STATE/mirror-releases.json")" = "v1.0.0 v1.0.1" ] || return 1
  backfill --apply
  [ "$status" -eq 0 ] || return 1
  [ "$(verdicts skipped)" -eq 2 ] || return 1
  [ "$(verdicts "done")" -eq 5 ] || return 1
}

@test "mutation: with the source list read failing open, the failure no longer names the call — the test above catches it" {
  local m
  m="$(mutant releases-read-fail-closed 'gh api --paginate "repos/$SRC/releases" >"$TMP/src-pages.json" 2>/dev/null || printf "[]" >"$TMP/src-pages.json"')" || { echo "$m"; return 1; }
  FAKE_GH_FAIL_RE='^api --paginate repos/acme/src/releases$' BACKFILL_UNDER_TEST="$m" backfill --apply
  [[ "$output" != *"gh api --paginate repos/acme/src/releases failed"* ]] || { echo "$output"; return 1; }
}

@test "a read that returns non-JSON, parsed inside a \$(...) substitution, is exit 2 naming the file and filter — the reason reaches the operator" {
  FAKE_GH_GARBLE_RE='^api repos/acme/mirror$' backfill --apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — could not parse "*"/mirror.json with '.full_name':"* ]] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
}

@test "mutation: with die2 writing to stdout, the reason is swallowed by the substitution — the test above catches it" {
  local m
  m="$(mutant die2-stderr 'die2() { echo "::error::backfill-releases: COULD NOT TELL — $1 (nothing more is written)"; exit 2; }')" || { echo "$m"; return 1; }
  FAKE_GH_GARBLE_RE='^api repos/acme/mirror$' BACKFILL_UNDER_TEST="$m" backfill --apply
  [ "$status" -eq 2 ] || return 1
  [[ "$output" != *"could not parse"* ]] || { echo "$output"; return 1; }
}

# ── the guard ─────────────────────────────────────────────────────────────────

@test "--notes source, refuse-tier needle in a body: refused naming the tier and the notes file, text not echoed, nothing written; the default notes never quote it" {
  backfill "$FIX_BADBODY" --apply --notes source
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.2 — the guard refused the notes, the tag message or a text asset: [forbidden-strings] REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"assets/RELEASE_NOTES.md:"* ]] || return 1
  [[ "$output" != *"role/planted"* ]] || return 1
  [ "$(verdicts refused)" -eq 1 ] || return 1
  [ "$(verdicts "done")" -eq 6 ] || return 1
  [ "$(jq -r '[.[] | select(.tag_name == "v1.0.2")] | length' "$STATE/mirror-releases.json")" -eq 0 ] || return 1
  backfill "$FIX_BADBODY" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts "done")" -eq 1 ] || return 1
  ! grep -q 'role/planted' "$STATE/mirror-releases.json" || return 1
}

@test "mutation: with the guard's refusal ignored, the planted body reaches the mirror — the test above catches it" {
  local m
  m="$(mutant guard-refusal '      1) ;;')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill "$FIX_BADBODY" --apply --notes source
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'role/planted' "$STATE/mirror-releases.json" || return 1
}

@test "an annotated source tag whose message carries a refuse-tier needle is refused naming the tier and TAG_MESSAGE.txt, in BOTH notes modes; no tag, no release of it is written, the other 6 go ahead" {
  local mode
  for mode in fixed source; do
    fresh_state "$STATE"
    backfill "$FIX_BADTAG" --apply --notes "$mode"
    [ "$status" -eq 1 ] || { echo "[$mode]"; echo "$output"; return 1; }
    [[ "$output" == *"REFUSED v1.0.3 — the guard refused the notes, the tag message or a text asset: [forbidden-strings] REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s)"* ]] || { echo "[$mode]"; echo "$output"; return 1; }
    [[ "$output" == *"assets/TAG_MESSAGE.txt:"* ]] || { echo "[$mode]"; echo "$output"; return 1; }
    [[ "$output" != *"role/planted"* ]] || return 1
    [ "$(verdicts refused)" -eq 1 ] || return 1
    [ "$(verdicts "done")" -eq 6 ] || return 1
    [ "$(jq -r '[.[] | select(.tag == "v1.0.3")] | length' "$STATE/mirror-tagobjs.json")" -eq 0 ] || return 1
    [ "$(jq -r '[.[] | select(.tag_name == "v1.0.3")] | length' "$STATE/mirror-releases.json")" -eq 0 ] || return 1
    ! grep -q 'role/planted' "$STATE/mirror-tagobjs.json" || return 1
  done
}

@test "mutation: with the tag message left out of the guard, the planted annotation reaches the mirror's tag object — the test above catches it" {
  local m
  m="$(mutant tag-message-guarded '  :')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill "$FIX_BADTAG" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'role/planted' "$STATE/mirror-tagobjs.json" || return 1
}

@test "mutation: with the notes default flipped to source, a plain --apply writes the pull-request list — the default-notes test catches it" {
  local m
  m="$(mutant notes-default-fixed 'APPLY=0; FROM_TAG=""; ONLY_TAG=""; STABLE_ONLY=0; NOTES_MODE=source; STRICT=0; PAGES=0')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill --apply
  [ "$status" -eq 0 ] || return 1
  [[ "$(jq -r '.[] | select(.tag_name == "v1.0.0") | .body' "$STATE/mirror-releases.json")" == "## What's Changed"* ]] || return 1
}

@test "--strict is passed to the guard: a report-tier needle in a source body refuses only under --notes source --strict, tier named" {
  local fix="$BATS_TEST_TMPDIR/fix-report"
  cp -R "$FIX" "$fix"
  jq '(.[] | select(.tag_name == "v1.0.3") | .body) |= . + "\n* tested against https://dev-api.tracebloc.io"' "$fix/src-releases.json" >"$fix/t.json" && mv "$fix/t.json" "$fix/src-releases.json"
  backfill "$fix" --notes source
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  backfill "$fix" --notes source --strict
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.3 — the guard refused"*"[strings-report (strict)] needle 'dev-api\.tracebloc\.io' found in 1 staged line(s)"* ]] || { echo "$output"; return 1; }
  backfill "$fix" --strict
  [ "$status" -eq 0 ] || return 1
  [ "$(verdicts planned)" -eq 7 ] || return 1
}

@test "a global commit.gpgsign=true with a failing signer does not end the run — the guard's scratch commit is made unsigned" {
  printf '#!/usr/bin/env bash\necho "gpg: signing failed: No secret key" >&2; exit 2\n' >"$BATS_TEST_TMPDIR/gpg-fail"; chmod +x "$BATS_TEST_TMPDIR/gpg-fail"
  printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = %s\n' "$BATS_TEST_TMPDIR/gpg-fail" >"$BATS_TEST_TMPDIR/gitconfig-gpgsign"
  GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig-gpgsign" backfill
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts planned)" -eq 7 ] || return 1
}

# ── present-but-different, dangling tags, narrowing flags ─────────────────────

@test "present-with-a-different-digest and a dangling mirror tag are each refused by name; nothing of those releases is written, the other 5 go ahead" {
  jq -n '[{id: 1, tag_name: "v1.0.4", name: "v1.0.4", body: "x", prerelease: false, draft: false, assets: [{name: "install.sh", digest: "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]}]' >"$STATE/mirror-releases.json"
  jq -n --arg h "$HEAD_SHA" '[{ref: "refs/tags/v1.0.4", object: {sha: $h, type: "commit"}}, {ref: "refs/tags/v1.0.2", object: {sha: "9999999999999999999999999999999999999999", type: "commit"}}]' >"$STATE/mirror-tags.json"
  backfill --apply
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED v1.0.4 — asset 'install.sh' is on the mirror with SHA256 deadbeef"*"a published asset is never replaced"* ]] || return 1
  [[ "$output" == *"REFUSED v1.0.2 — tag 'v1.0.2' exists on the mirror but points at commit 9999999999999999999999999999999999999999, which the mirror does not have — a dangling tag is not repointed"* ]] || return 1
  [ "$(verdicts refused)" -eq 2 ] || return 1
  [ "$(verdicts "done")" -eq 5 ] || return 1
  ! grep -E '^(api -X POST|release upload) ' "$GH_LOG" | grep -qE 'v1.0.(2|4)' || return 1
}

@test "--only-tag / --from-tag narrow the run; an unknown tag, a filtered-out prerelease, or both flags are could-not-tell" {
  backfill --apply --only-tag v1.0.1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 4 ] || return 1
  [[ "$output" == *"7 release(s) match the filter (stable and prerelease), 1 in this run"* ]] || return 1
  backfill --apply --from-tag v1.0.5
  [ "$status" -eq 0 ] || return 1
  [ "$(writes)" -eq 8 ] || return 1
  [ "$(jq -r '[.[].tag_name] | join(" ")' "$STATE/mirror-releases.json")" = "v1.0.1 v1.0.5 v1.0.6-rc.1" ] || return 1
  backfill --only-tag v9.9.9
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--only-tag 'v9.9.9' is not a release of 'acme/src' matching the filter"* ]] || return 1
  backfill --stable-only --only-tag v1.0.6-rc.1
  [ "$status" -eq 2 ] || return 1
  backfill --from-tag v1.0.1 --only-tag v1.0.2
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--from-tag and --only-tag exclude each other"* ]] || return 1
}

# ── --pages: the Helm index the mirror serves ─────────────────────────────────

@test "--pages needs helm: a missing helm is could-not-tell naming it, before any gh call" {
  BACKFILL_HELM="$BATS_TEST_TMPDIR/no-such-helm" backfill --pages
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — '"*"no-such-helm' is not on PATH — --pages rebuilds the Helm index with it"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GH_LOG" ] || return 1
  # Without --pages helm is not needed at all.
  BACKFILL_HELM="$BATS_TEST_TMPDIR/no-such-helm" backfill
  [ "$status" -eq 0 ] || return 1
}

@test "mutation: with the helm check removed, a --pages dry-run on an empty mirror ends 0 having never needed helm — the test above catches it" {
  local m
  m="$(mutant helm-required ':')" || { echo "$m"; return 1; }
  BACKFILL_HELM="$BATS_TEST_TMPDIR/no-such-helm" BACKFILL_UNDER_TEST="$m" backfill --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--pages dry-run on a mirror with no releases: nothing to index yet, nothing pushed, exit 0" {
  backfill --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--pages: the mirror carries no chart tarball on any stable release yet — nothing to index in this dry-run; run --apply first"* ]] || return 1
  [[ "$output" == *"Helm index (gh-pages): nothing to index yet"* ]] || return 1
  ! git -C "$PAGES_BARE" rev-parse --verify -q gh-pages >/dev/null || return 1
}

@test "--apply --pages: the index lists every stable chart version once, under the OLDEST release carrying it, at its release-asset URL on the mirror, with the original publish date; the prerelease chart is absent" {
  backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--pages: pushed "*"(7 chart(s), index changed)"* ]] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 1 ] || return 1
  local idx
  idx="$(pages_file index.yaml)"
  [ "$(printf '%s\n' "$idx" | grep -c '^    version:')" -eq 7 ] || { echo "$idx"; return 1; }
  [ "$(printf '%s\n' "$idx" | url_for 1.0.0)" = "https://github.com/acme/mirror/releases/download/v1.0.0/client-1.0.0.tgz" ] || { echo "$idx"; return 1; }
  [ "$(printf '%s\n' "$idx" | url_for 1.0.5)" = "https://github.com/acme/mirror/releases/download/v1.0.5/client-1.0.5.tgz" ] || return 1
  [ "$(printf '%s\n' "$idx" | url_for 0.2.0)" = "https://github.com/acme/mirror/releases/download/v1.0.0/ingestor-0.2.0.tgz" ] || return 1
  [ "$(printf '%s\n' "$idx" | created_for 1.0.0)" = '"2026-01-01T12:00:00Z"' ] || { echo "$idx"; return 1; }
  [ "$(printf '%s\n' "$idx" | created_for 1.0.5)" = '"2026-01-06T12:00:00Z"' ] || return 1
  [ "$(printf '%s\n' "$idx" | created_for 0.2.0)" = '"2026-01-01T12:00:00Z"' ] || return 1
  [[ "$idx" != *"1.0.6-rc.1"* ]] || return 1
  [[ "$idx" != *"acme.github.io"* ]] || return 1
  # The digests are the tarballs': helm read the bytes the mirror serves.
  [[ "$idx" == *"digest: $(sha256_of "$FIX/charts/client-1.0.5.tgz")"* ]] || return 1
  # Seven tarballs came down from the MIRROR, one per chart version, none twice, none from the source.
  [ "$(grep -c '^release download v[0-9.]* --repo acme/mirror --dir .*/charts/' "$GH_LOG")" -eq 7 ] || { grep 'release download' "$GH_LOG"; return 1; }
  ! grep -q '^release download v1.0.1 --repo acme/mirror .*--pattern client-1.0.0.tgz' "$GH_LOG" || return 1
  # helm reads the index back: the URLs are what a customer's helm will fetch.
  helm show chart "$STATE/assets/v1.0.0/client-1.0.0.tgz" | grep -q '^version: 1.0.0$' || return 1
}

@test "--apply --pages twice: the second run finds the index unchanged and pushes nothing (one commit on gh-pages, zero gh writes)" {
  backfill --apply --pages
  [ "$status" -eq 0 ] || return 1
  backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(writes)" -eq 0 ] || return 1
  [[ "$output" == *"--pages: unchanged "*"(7 chart(s), index unchanged)"* ]] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 1 ] || return 1
  backfill --pages
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"--pages would: index 7 chart(s) from 6 stable release(s) at https://github.com/acme/mirror/releases/download/<tag>/; index.yaml unchanged against the mirror's gh-pages (present); not pushed"* ]] || { echo "$output"; return 1; }
}

@test "--apply --pages: a publisher that exits 0 without its 'pushed/unchanged <sha>' line is could-not-tell (exit 2) naming the missing contract line" {
  local m
  m="$(mutant pages-publisher ': >"$P/tree.out"')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill --apply --pages
  [ "$status" -eq 2 ] || { echo "status=$status"; echo "$output"; return 1; }
  [[ "$output" == *"--pages: the publisher exited 0 but reported no 'pushed <sha>' / 'unchanged <sha>' line"* ]] || { echo "$output"; return 1; }
}

@test "mutation: with the result grep back under pipefail, the same publisher miss dies at exit 1 with NO reason — the test above catches it" {
  local m1 m2 a
  m1="$(mutant pages-publisher ': >"$P/tree.out"')" || { echo "$m1"; return 1; }
  # Second mutation applied on the first mutant's copy (mutant() reads $REAL, so it
  # is applied here by hand with the same anchor-applied proof: exactly one anchor,
  # copy differs, copy parses).
  m2="$BATS_TEST_TMPDIR/mutant-pages-result-grep.sh"; a="# mutation-anchor: pages-result-grep"
  [ "$(grep -c -- "$a\$" "$m1")" -eq 1 ] || { echo "anchor pages-result-grep not exactly once"; return 1; }
  awk -v a="$a" 'index($0, a) && substr($0, length($0) - length(a) + 1) == a { print "        TREE_RESULT=\"$(grep -E '"'"'^(pushed|unchanged) [0-9a-f]{40}$'"'"' \"$P/tree.out\" | tail -1)\""; next } { print }' "$m1" >"$m2"
  cmp -s "$m1" "$m2" && { echo "mutation pages-result-grep did not change the script"; return 1; }
  bash -n "$m2" || { echo "mutant does not parse"; return 1; }
  BACKFILL_UNDER_TEST="$m2" backfill --apply --pages
  [ "$status" -eq 1 ] || { echo "status=$status"; echo "$output"; return 1; }
  [[ "$output" != *"the publisher exited 0 but reported no"* ]] || { echo "$output"; return 1; }
}

@test "mutation: with the unchanged-index comparison removed, the second --pages pushes a new commit for a generated: timestamp alone — the test above catches it" {
  local m
  m="$(mutant index-unchanged-not-pushed ':')" || { echo "$m"; return 1; }
  backfill --apply --pages
  [ "$status" -eq 0 ] || return 1
  BACKFILL_UNDER_TEST="$m" backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 2 ] || return 1
  [[ "$output" == *"--pages: pushed "* ]] || return 1
}

@test "mutation: with created left as helm stamped it, the index carries the backfill instant, not the publish date — the index test catches it" {
  local m
  m="$(mutant index-created-from-source 'cp "$P/charts/index.yaml" "$P/index.yaml"')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pages_file index.yaml | created_for 1.0.0)" != '"2026-01-01T12:00:00Z"' ] || return 1
}

@test "mutation: with the stable-only filter dropped from the index, the prerelease chart is listed — the index test catches it" {
  local m
  m="$(mutant index-stable-only 'jq -r '"'"'.[] | select(.draft == false) | .tag_name'"'"' "$TMP/mirror-releases.json" >"$P/stable-tags.txt"')" || { echo "$m"; return 1; }
  BACKFILL_UNDER_TEST="$m" backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(pages_file index.yaml)" == *"1.0.6-rc.1"* ]] || return 1
}

@test "--pages keeps every other file on the mirror's gh-pages and appends to its history; only index.yaml is replaced" {
  local seed="$BATS_TEST_TMPDIR/seed"
  git clone -q "file://$PAGES_BARE" "$seed" 2>/dev/null
  git -C "$seed" checkout -q --orphan gh-pages
  printf 'not really gzip\n' >"$seed/client-0.9.0.tgz"; printf 'apiVersion: v1\nentries: {}\n' >"$seed/index.yaml"
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
  git -C "$seed" push -q origin gh-pages
  backfill --apply --pages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 2 ] || return 1
  [ "$(git -C "$PAGES_BARE" ls-tree -r --name-only gh-pages | sort | paste -sd' ' -)" = "client-0.9.0.tgz index.yaml" ] || return 1
  [ "$(pages_file client-0.9.0.tgz)" = "not really gzip" ] || return 1
  [[ "$(pages_file index.yaml)" == *"releases/download/v1.0.5/client-1.0.5.tgz"* ]] || return 1
  # The stray file went through the guard with the index (it is staged again).
  [[ "$output" == *"--pages: pushed "* ]] || return 1
}

@test "--pages: a refuse-tier needle in a file already on gh-pages refuses the index push, naming the guard's finding" {
  local seed="$BATS_TEST_TMPDIR/seed"
  git clone -q "file://$PAGES_BARE" "$seed" 2>/dev/null
  git -C "$seed" checkout -q --orphan gh-pages
  printf 'bucket arn:aws:s3:::planted\n' >"$seed/notes.txt"
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
  git -C "$seed" push -q origin gh-pages
  backfill --apply --pages
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — --pages: the guard refused the index or the Pages branch: [forbidden-strings] REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"assets/notes.txt:1"* ]] || return 1
  [ "$(pages_commits)" -eq 1 ] || return 1
  [[ "$output" == *"Helm index (gh-pages): refused by the guard"* ]] || return 1
  # The releases themselves went ahead: the refusal is the index's alone.
  [ "$(verdicts "done")" -eq 7 ] || return 1
}

@test "--pages: a mirror tarball that is not the chart its name says, or a mirror release the source never had, is could-not-tell" {
  backfill --apply --stable-only --only-tag v1.0.0
  [ "$status" -eq 0 ] || return 1
  # Swap v1.0.0's client tarball on the mirror for the ingestor's bytes, digest matching those bytes.
  cp "$FIX/charts/ingestor-0.2.0.tgz" "$STATE/assets/v1.0.0/client-1.0.0.tgz"
  jq --arg d "sha256:$(sha256_of "$FIX/charts/ingestor-0.2.0.tgz")" '(.[] | select(.tag_name == "v1.0.0") | .assets[] | select(.name == "client-1.0.0.tgz") | .digest) = $d' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
  backfill --pages --only-tag v1.0.0
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — --pages: 'client-1.0.0.tgz' contains chart 'ingestor' version '0.2.0', not what its name says"* ]] || { echo "$output"; return 1; }
  ! git -C "$PAGES_BARE" rev-parse --verify -q gh-pages >/dev/null || return 1
  # A mirror release with no counterpart on the source cannot be placed in time.
  jq '. + [{id: 99, tag_name: "v9.9.9", name: "v9.9.9", body: "", prerelease: false, draft: false, assets: []}]' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
  backfill --pages --only-tag v1.0.0
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — --pages: mirror release 'v9.9.9' has no counterpart on 'acme/src'"* ]] || { echo "$output"; return 1; }
}

@test "--pages: a mirror download whose bytes are not the mirror's digest is could-not-tell, never indexed" {
  backfill --apply --stable-only --only-tag v1.0.0
  [ "$status" -eq 0 ] || return 1
  printf 'tampered\n' >>"$STATE/assets/v1.0.0/client-1.0.0.tgz"
  backfill --pages --only-tag v1.0.0
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — --pages: 'client-1.0.0.tgz' from 'acme/mirror' release 'v1.0.0' hashes to "*"the download is not the asset"* ]] || { echo "$output"; return 1; }
}
