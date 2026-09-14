#!/usr/bin/env bats
# scripts/publish-mirror.sh `index` — the Helm repository index the public mirror
# serves, derived from the MIRROR's own releases. One implementation, run by
# .github/workflows/mirror-publish.yaml on every stable publish and by
# scripts/backfill-releases.sh --pages; this file pins the command itself, the
# two callers' suites pin what each does with its verdict.
#
# Offline. `gh` is a recording FAKE on PATH that serves ONE repository — the
# mirror — from a state directory (its release list, its assets with their
# digests and bytes); it answers nothing about any other repository, so a read
# of the source's gh-pages index, the defect this command replaced, would be a
# logged error, not a silent success. gitleaks is a stub. The mirror's gh-pages
# is a REAL bare repository over file://, pushed to through publish-mirror's
# production `tree` path. helm is the real one (the `Unit tests` job installs
# it): the index is built and read back by the tool a customer's `helm repo
# add` will trust.
#
# Pinned: a mirror that already carries a backfilled index keeps every entry's
# URL on the mirror host and gains the new version; an index copied from the
# source (Pages URLs) is replaced, not kept; nothing of the source repository is
# read; a second derivation over the same mirror is `changed=false` and the
# publisher pushes nothing; a missing helm is could-not-tell naming it before
# any gh call; a refuse-tier needle in the index itself or in a file already on
# the branch refuses (exit 1) and writes no result; a tarball whose bytes are not
# the mirror's digest, or not the chart its name says, a mirror release the
# source list has no date for, an unreadable mirror and an unanswering remote
# are could-not-tell; a mirror with no chart tarball is refused unless
# --allow-empty; each chart version sits once, under the oldest stable release
# carrying it, with the original publish date; prereleases are left out; the
# index.yaml and *.tgz files on gh-pages are kept, anything else there — a
# stray file, a directory, a symlink — is dropped, named, and the drop alone
# makes the index `changed` so the push prunes it (review on #1060: a stray
# would otherwise sit there for good, and a directory or symlink would stop the
# guard on every later publish); --mirror-releases reuses the caller's read of
# the release list instead of paginating it again.
#
# Mutations: `mutant NAME REPL` copies the script with the `# mutation-anchor:
# NAME` line replaced, PROVES the copy differs and parses, and the test then
# shows the bad outcome the real script refuses — so the assertion it pairs
# with is live, not vacuous. Every standalone assertion ends in `|| return 1`
# (bats-hygiene.bats).

PUB=""
REPO_ROOT=""
SHIM=""
STATE=""
BARE=""
OUT=""
RESULT=""
MIRROR_BASE="https://github.com/acme/mirror/releases/download"

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# chart_tgz DIR NAME VERSION — a packaged chart, built by `helm package` the way
# the release workflow builds the real ones. Built once per file.
chart_tgz() {
  local dir="$1" name="$2" ver="$3" desc="${4:-fixture chart}" src="$BATS_FILE_TMPDIR/chart-src-$name-$ver"
  mkdir -p "$src" "$dir"
  printf 'apiVersion: v2\nname: %s\nversion: %s\ndescription: %s\n' "$name" "$ver" "$desc" >"$src/Chart.yaml"
  helm package "$src" --destination "$dir" >/dev/null
  [ -f "$dir/$name-$ver.tgz" ] || { echo "helm package did not produce $dir/$name-$ver.tgz" >&2; return 1; }
}

setup_file() {
  command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm is required: the index is built and read back by the real tool" >&2; return 1; }
  export CHARTS="$BATS_FILE_TMPDIR/charts"
  local v
  for v in 1.0.0 1.0.1 1.0.2 1.0.3 1.0.4-rc.1; do chart_tgz "$CHARTS" client "$v"; done
  chart_tgz "$CHARTS" ingestor 0.2.0
  # The SOURCE's release list as `gh api --paginate` prints it: two JSON arrays
  # back to back, not in date order, a day apart. The command joins the pages.
  export SRC_RELEASES="$BATS_FILE_TMPDIR/src-releases.json"
  {
    jq -n -c '[{tag_name: "v1.0.2", published_at: "2026-01-03T12:00:00Z", created_at: "2026-01-03T11:00:00Z", prerelease: false},
               {tag_name: "v1.0.0", published_at: "2026-01-01T12:00:00Z", created_at: "2026-01-01T11:00:00Z", prerelease: false}]'
    jq -n -c '[{tag_name: "v1.0.4-rc.1", published_at: "2026-01-05T12:00:00Z", created_at: "2026-01-05T11:00:00Z", prerelease: true},
               {tag_name: "v1.0.1", published_at: "2026-01-02T12:00:00Z", created_at: "2026-01-02T11:00:00Z", prerelease: false},
               {tag_name: "v1.0.3", published_at: null, created_at: "2026-01-04T12:00:00Z", prerelease: false}]'
  } >"$SRC_RELEASES"
}

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PUB="$REPO_ROOT/scripts/publish-mirror.sh"
  SHIM="$BATS_TEST_TMPDIR/shim"; mkdir -p "$SHIM"
  cat >"$SHIM/gitleaks" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && { echo "gitleaks-stub"; exit 0; }
exit 0
EOF
  cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
# Recording fake gh that knows ONE repository, the mirror acme/mirror, from STATE.
set -uo pipefail
STATE="${FAKE_GH_STATE:?}"; MIRROR=acme/mirror
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [ -n "${FAKE_GH_FAIL_RE:-}" ] && [[ "$*" =~ $FAKE_GH_FAIL_RE ]]; then echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; fi
cmd="${1:-}"; shift || true
case "$cmd" in
  api)
    PATHP=""
    while [ "$#" -gt 0 ]; do case "$1" in --paginate) shift ;; *) PATHP="$1"; shift ;; esac; done
    case "$PATHP" in
      "repos/$MIRROR/releases") cat "$STATE/mirror-releases.json" ;;
      *) echo "gh: fake: unhandled api $PATHP (only the mirror's releases are served)" >&2; exit 1 ;;
    esac ;;
  release)
    [ "${1:-}" = download ] || { echo "gh: fake: unhandled release ${1:-}" >&2; exit 1; }
    shift; tag="$1"; shift; repo=""; dir=""; pats=()
    while [ "$#" -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; --dir) dir="$2"; shift 2 ;; --pattern) pats+=("$2"); shift 2 ;; *) echo "gh: fake: unknown download arg $1" >&2; exit 1 ;; esac; done
    [ "$repo" = "$MIRROR" ] || { echo "gh: fake: download from '$repo' — only the mirror is served" >&2; exit 1; }
    jq -e --arg t "$tag" '.[] | select(.tag_name == $t)' "$STATE/mirror-releases.json" >/dev/null || { echo "gh: release not found" >&2; exit 1; }
    mkdir -p "$dir"
    for p in "${pats[@]}"; do
      [ -f "$STATE/assets/$tag/$p" ] || { echo "gh: no assets match the file pattern ($p)" >&2; exit 1; }
      cp "$STATE/assets/$tag/$p" "$dir/$p"
    done ;;
  *) echo "gh: fake: unhandled command $cmd" >&2; exit 1 ;;
esac
EOF
  chmod +x "$SHIM/gh" "$SHIM/gitleaks"
  STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$STATE"; printf '[]' >"$STATE/mirror-releases.json"
  BARE="$BATS_TEST_TMPDIR/pages.git"; git init -q --bare "$BARE"
  OUT="$BATS_TEST_TMPDIR/out"
  RESULT="$BATS_TEST_TMPDIR/result.txt"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
}

# add_release TAG PRERELEASE FILE... — a release on the mirror carrying FILEs
# from $CHARTS (or any path), each with the digest of its bytes.
add_release() {
  local tag="$1" pre="$2" f n; shift 2
  mkdir -p "$STATE/assets/$tag"
  jq --arg t "$tag" --argjson p "$pre" '. + [{tag_name: $t, name: $t, draft: false, prerelease: $p, created_at: "2026-09-01T00:00:00Z", assets: []}]' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
  for f in "$@"; do
    n="$(basename "$f")"; cp "$f" "$STATE/assets/$tag/$n"
    jq --arg t "$tag" --arg n "$n" --arg d "sha256:$(sha256_of "$f")" 'map(if .tag_name == $t then .assets += [{name: $n, digest: $d}] else . end)' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
  done
}
# The three stable releases a backfill would have carried, plus the prerelease.
seed_mirror() {
  add_release v1.0.0 false "$CHARTS/client-1.0.0.tgz" "$CHARTS/ingestor-0.2.0.tgz"
  add_release v1.0.1 false "$CHARTS/client-1.0.1.tgz" "$CHARTS/client-1.0.0.tgz" "$CHARTS/ingestor-0.2.0.tgz"
  add_release v1.0.2 false "$CHARTS/client-1.0.2.tgz" "$CHARTS/ingestor-0.2.0.tgz"
  add_release v1.0.4-rc.1 true "$CHARTS/client-1.0.4-rc.1.tgz" "$CHARTS/ingestor-0.2.0.tgz"
}

# idx ARGS... — `publish-mirror.sh index` (or PUB_UNDER_TEST) against the fake
# gh, the state mirror and the bare gh-pages, into a fresh $OUT.
idx() {
  rm -rf "$OUT" "$RESULT"; : >"$GH_LOG"
  run env PATH="$SHIM:$PATH" GH_LOG="$GH_LOG" FAKE_GH_STATE="$STATE" PUBLISH_GUARD_GITLEAKS="$SHIM/gitleaks" \
    bash "${PUB_UNDER_TEST:-$PUB}" index --repo acme/mirror --source-releases "$SRC_RELEASES" --out "$OUT" --remote "file://$BARE" \
    --forbidden "$REPO_ROOT/.publish-forbidden" --output "$RESULT" "$@"
}
res() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$RESULT"; }
# push_stage — the caller's half: publish-mirror's `tree` over what `index` staged.
push_stage() { run bash "$PUB" tree --stage "$OUT/stage" --repo acme/mirror --branch gh-pages --message "Chart index" --remote "file://$BARE"; }
pages_file() { git -C "$BARE" show "gh-pages:$1"; }
pages_commits() { git -C "$BARE" rev-list --count gh-pages; }
# seed_pages FILE CONTENT... — a gh-pages branch on the bare mirror holding the
# given files (pairs), as a backfill or a copied source index would have left it.
seed_pages() {
  local seed="$BATS_TEST_TMPDIR/seed-$RANDOM"
  git clone -q "file://$BARE" "$seed" 2>/dev/null
  git -C "$seed" checkout -q --orphan gh-pages
  while [ "$#" -gt 1 ]; do printf '%s' "$2" >"$seed/$1"; shift 2; done
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
  git -C "$seed" push -q origin gh-pages
}
# pages_clone — a working clone of the mirror's gh-pages; prints its path. The
# test puts strays in it the way a hand push would, then pages_push commits and
# pushes them.
pages_clone() { local c="$BATS_TEST_TMPDIR/clone-$RANDOM"; git clone -q -b gh-pages "file://$BARE" "$c" 2>/dev/null || return 1; printf '%s\n' "$c"; }
pages_push()  { git -C "$1" -c user.name=t -c user.email=t@example.invalid add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m strays && git -C "$1" push -q origin gh-pages; }
# Helm-index readers (see publish-helm-index.bats): the URL / created of a version.
url_for()     { awk -v want="$1" '/^  - / { if (v != "") c[v] = u; v = ""; u = "" } /^    version:/ { v = $2 } /^    - https/ { u = $2 } END { if (v != "") c[v] = u; print c[want] }'; }
created_for() { awk -v want="$1" '/^  - / { if (v != "") c[v] = cr; v = ""; cr = "" } /^    version:/ { v = $2 } /^    created:/ { cr = $2 } END { if (v != "") c[v] = cr; print c[want] }'; }
urls()        { grep -E '^    - https?://' | sed 's/^    - //' | sort; }

# mutant NAME REPLACEMENT — a copy of publish-mirror.sh with the line carrying
# `# mutation-anchor: NAME` replaced by REPLACEMENT; prints its path. Refuses
# unless the anchor was found exactly once, the copy differs and still parses.
# The copy gets its own scripts/ directory with the REAL publish-guard.sh
# beside it, since the command finds the guard next to itself.
mutant() {
  local name="$1" repl="$2" dir="$BATS_TEST_TMPDIR/mutant-$name/scripts" copy n
  mkdir -p "$dir"; cp "$REPO_ROOT/scripts/publish-guard.sh" "$dir/"
  copy="$dir/publish-mirror.sh"
  n="$(grep -c -- "# mutation-anchor: $name\$" "$PUB")"
  [ "$n" -eq 1 ] || { echo "anchor $name found $n time(s), need exactly 1"; return 1; }
  awk -v a="# mutation-anchor: $name" -v r="$repl" 'index($0, a) && substr($0, length($0) - length(a) + 1) == a { print r; next } { print }' "$PUB" >"$copy"
  cmp -s "$PUB" "$copy" && { echo "mutation $name did not change the script"; return 1; }
  bash -n "$copy" || { echo "mutant $name does not parse"; return 1; }
  printf '%s\n' "$copy"
}

# ── the defect: a publish onto a backfilled mirror ─────────────────────────────

@test "a mirror that already carries a backfilled index: every existing entry's URL stays on the mirror host, the new version is added under its own release, nothing of the source repository is read" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  push_stage
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local before after
  before="$(pages_file index.yaml | urls)"
  [ "$(printf '%s\n' "$before" | grep -c .)" -eq 4 ] || { echo "$before"; return 1; }
  # The publish: v1.0.3 lands on the mirror with its chart and the ingestor.
  add_release v1.0.3 false "$CHARTS/client-1.0.3.tgz" "$CHARTS/ingestor-0.2.0.tgz"
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || { cat "$RESULT"; return 1; }
  [ "$(res charts)" = 5 ] || { cat "$RESULT"; return 1; }
  [ "$(res stable_releases)" = 4 ] || return 1
  [ "$(res download_base)" = "$MIRROR_BASE" ] || return 1
  [ "$(res stage)" = "$OUT/stage" ] || return 1
  after="$(urls <"$OUT/stage/index.yaml")"
  # Every URL the backfilled index had is still there, byte for byte …
  [ "$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c .)" -eq 0 ] || { echo "lost: $(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"; return 1; }
  # … every URL names the mirror's release assets …
  [ "$(printf '%s\n' "$after" | grep -vc "^$MIRROR_BASE/")" -eq 0 ] || { echo "$after"; return 1; }
  # … and the new version is the one addition, under its own release.
  [ "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" = "$MIRROR_BASE/v1.0.3/client-1.0.3.tgz" ] || { echo "$after"; return 1; }
  [ "$(created_for 1.0.3 <"$OUT/stage/index.yaml")" = '"2026-01-04T12:00:00Z"' ] || { cat "$OUT/stage/index.yaml"; return 1; }
  [ "$(created_for 1.0.0 <"$OUT/stage/index.yaml")" = '"2026-01-01T12:00:00Z"' ] || return 1
  # Nothing of the source repository was read: no call names another repo, no
  # Pages index came down, and the only gh-pages touched is the mirror's file://.
  ! grep -qv 'acme/mirror' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  ! grep -q 'contents/index.yaml\|gh-pages' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  [ "$(grep -c '^release download v1.0.3 --repo acme/mirror ' "$GH_LOG")" -eq 1 ] || { cat "$GH_LOG"; return 1; }
  [[ "$output" == *"index: 5 chart version(s) from 4 stable release(s) of acme/mirror at $MIRROR_BASE/<tag>/; index.yaml changed against the mirror's gh-pages (present)"* ]] || { echo "$output"; return 1; }
  push_stage
  [ "$status" -eq 0 ] || return 1
  [ "$(pages_commits)" -eq 2 ] || return 1
  helm show chart "$STATE/assets/v1.0.3/client-1.0.3.tgz" | grep -q '^version: 1.0.3$' || return 1
}

@test "an index copied from the source (Pages URLs) on the mirror's gh-pages is REPLACED by mirror URLs, not kept" {
  seed_mirror
  seed_pages index.yaml "$(printf 'apiVersion: v1\nentries:\n  client:\n  - apiVersion: v2\n    created: "2026-01-01T00:00:00Z"\n    digest: %s\n    name: client\n    urls:\n    - https://acme.github.io/src/client-1.0.0.tgz\n    version: 1.0.0\ngenerated: "2026-01-07T12:00:00Z"\n' "$(sha256_of "$CHARTS/client-1.0.0.tgz")")"
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || return 1
  ! grep -q 'acme.github.io' "$OUT/stage/index.yaml" || { cat "$OUT/stage/index.yaml"; return 1; }
  [ "$(url_for 1.0.0 <"$OUT/stage/index.yaml")" = "$MIRROR_BASE/v1.0.0/client-1.0.0.tgz" ] || return 1
}

# ── unchanged → no push ───────────────────────────────────────────────────────

@test "unchanged: a second derivation over the same mirror is changed=false, stages the mirror's own index verbatim, and the publisher pushes nothing" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || return 1
  [ "$(res pages_existed)" = false ] || return 1
  push_stage
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == pushed\ [0-9a-f]* ]] || return 1
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = false ] || { cat "$RESULT"; return 1; }
  [ "$(res pages_existed)" = true ] || return 1
  cmp -s "$OUT/stage/index.yaml" <(pages_file index.yaml) || return 1
  [[ "$output" == *"index.yaml unchanged against the mirror's gh-pages (present)"* ]] || { echo "$output"; return 1; }
  push_stage
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == unchanged\ [0-9a-f]* ]] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 1 ] || return 1
}

@test "mutation: with the unchanged-index comparison removed, the second derivation says changed=true for a generated: stamp alone — the test above catches it" {
  local m
  m="$(mutant index-unchanged-not-pushed ':')" || { echo "$m"; return 1; }
  seed_mirror
  idx
  [ "$status" -eq 0 ] || return 1
  push_stage
  [ "$status" -eq 0 ] || return 1
  PUB_UNDER_TEST="$m" idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || return 1
}

# ── helm ──────────────────────────────────────────────────────────────────────

@test "helm missing: could-not-tell (exit 2) naming the binary, before any gh call, nothing written to --output" {
  seed_mirror
  idx --helm "$BATS_TEST_TMPDIR/no-such-helm"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: '"*"/no-such-helm' is not on PATH — the Helm index is rebuilt with it, and an index built any other way is not one helm would"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GH_LOG" ] || { cat "$GH_LOG"; return 1; }
  [ ! -e "$RESULT" ] || return 1
}

@test "mutation: with the helm check removed, a derivation over a chart-less mirror ends 0 having never needed helm — the test above catches it" {
  local m
  m="$(mutant index-helm-required ':')" || { echo "$m"; return 1; }
  PUB_UNDER_TEST="$m" idx --helm "$BATS_TEST_TMPDIR/no-such-helm" --allow-empty
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── the guard ─────────────────────────────────────────────────────────────────

@test "guard: a refuse-tier needle that hits the rebuilt index itself refuses (exit 1) naming the guard and assets/index.yaml; no result is written" {
  seed_mirror
  # A private needle (the workflow's --extra-forbidden) matching a chart name
  # hits index.yaml: the index is scanned like every other uploaded text asset.
  printf 'ingestor\n' >"$BATS_TEST_TMPDIR/needles.txt"
  idx --extra-forbidden "$BATS_TEST_TMPDIR/needles.txt"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::publish-mirror: REFUSED — index: the guard refused the index or the Pages branch: [forbidden-strings] REFUSED — [strings-refuse] private needle #1 found in "*" staged line(s)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"assets/index.yaml:"* ]] || { echo "$output"; return 1; }
  [ ! -e "$RESULT" ] || return 1
  ! git -C "$BARE" rev-parse --verify -q gh-pages >/dev/null || return 1
}

@test "guard: a refuse-tier needle a chart carries into the rebuilt index (its description) refuses the index push, naming the file, never echoing the text" {
  seed_mirror
  # The committed refuse tier, not a private needle: helm copies Chart.yaml's
  # description into index.yaml, so the branch text the guard reads carries it.
  chart_tgz "$BATS_TEST_TMPDIR/planted" client 1.0.3 'bucket arn:aws:s3:::planted'
  add_release v1.0.3 false "$BATS_TEST_TMPDIR/planted/client-1.0.3.tgz"
  idx
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — index: the guard refused the index or the Pages branch: [forbidden-strings] REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"assets/index.yaml:"* ]] || return 1
  [[ "$output" != *"planted"* ]] || return 1
  [ ! -e "$RESULT" ] || return 1
  ! git -C "$BARE" rev-parse --verify -q gh-pages >/dev/null || return 1
}

@test "guard: a stray text file on the branch is dropped BEFORE the guard — never scanned, never refused, pruned by the push" {
  seed_mirror
  seed_pages notes.txt $'bucket arn:aws:s3:::planted\n' index.yaml $'apiVersion: v1\nentries: {}\n'
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"index: dropping 'notes.txt' from the mirror's gh-pages — neither index.yaml nor a *.tgz;"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"planted"* ]] || return 1
  [ ! -e "$OUT/stage/notes.txt" ] || return 1
  [ "$(res changed)" = true ] || return 1
  push_stage
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$BARE" ls-tree --name-only gh-pages | sort | paste -sd' ' -)" = "index.yaml" ] || return 1
}

@test "mutation: with the guard dropped, the planted index is staged as changed=true, exit 0 — the needle tests catch it" {
  local m
  m="$(mutant index-guard ':')" || { echo "$m"; return 1; }
  seed_mirror
  printf 'ingestor\n' >"$BATS_TEST_TMPDIR/needles.txt"
  PUB_UNDER_TEST="$m" idx --extra-forbidden "$BATS_TEST_TMPDIR/needles.txt"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || return 1
  grep -q ingestor "$OUT/stage/index.yaml" || return 1
}

@test "--strict is passed to the guard: a report-tier needle a chart carries into the index refuses only under --strict, tier named" {
  seed_mirror
  chart_tgz "$BATS_TEST_TMPDIR/report" client 1.0.3 'tested against https://dev-api.tracebloc.io'
  add_release v1.0.3 false "$BATS_TEST_TMPDIR/report/client-1.0.3.tgz"
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  idx --strict
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-report (strict)] needle 'dev-api\.tracebloc\.io' found in 1 staged line(s)"* ]] || { echo "$output"; return 1; }
}

# ── what the index says ───────────────────────────────────────────────────────

@test "each chart version sits once, under the OLDEST stable release carrying it, with the original publish date; the prerelease chart is absent; helm reads it back" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local i="$OUT/stage/index.yaml"
  [ "$(grep -c '^    version:' "$i")" -eq 4 ] || { cat "$i"; return 1; }
  [ "$(url_for 1.0.0 <"$i")" = "$MIRROR_BASE/v1.0.0/client-1.0.0.tgz" ] || return 1
  [ "$(url_for 0.2.0 <"$i")" = "$MIRROR_BASE/v1.0.0/ingestor-0.2.0.tgz" ] || return 1
  [ "$(url_for 1.0.2 <"$i")" = "$MIRROR_BASE/v1.0.2/client-1.0.2.tgz" ] || return 1
  [ "$(created_for 1.0.0 <"$i")" = '"2026-01-01T12:00:00Z"' ] || return 1
  [ "$(created_for 0.2.0 <"$i")" = '"2026-01-01T12:00:00Z"' ] || return 1
  [ "$(created_for 1.0.2 <"$i")" = '"2026-01-03T12:00:00Z"' ] || return 1
  ! grep -q '1.0.4-rc.1' "$i" || return 1
  grep -q "digest: $(sha256_of "$CHARTS/client-1.0.2.tgz")" "$i" || return 1
  # Four downloads, one per chart version; v1.0.1's copy of client-1.0.0.tgz is never fetched.
  [ "$(grep -c '^release download ' "$GH_LOG")" -eq 4 ] || { cat "$GH_LOG"; return 1; }
  ! grep -q '^release download v1.0.1 .*--pattern client-1.0.0.tgz' "$GH_LOG" || return 1
  ! grep -q '^release download v1.0.4-rc.1 ' "$GH_LOG" || return 1
  [ -f "$OUT/index.yaml" ] && cmp -s "$OUT/index.yaml" "$i" || return 1
  [ "$(res index)" = "$OUT/index.yaml" ] || return 1
}

@test "mutation: with the stable-only filter dropped, the prerelease chart is listed — the index test catches it" {
  local m
  m="$(mutant index-stable-only 'jq -r '"'"'.[] | select(.draft == false) | .tag_name'"'"' "$out/mirror-releases.json" >"$out/stable-tags.txt"')" || { echo "$m"; return 1; }
  seed_mirror
  PUB_UNDER_TEST="$m" idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '1.0.4-rc.1' "$OUT/stage/index.yaml" || return 1
}

@test "mutation: with created left as helm stamped it, the index carries today, not the publish date — the index test catches it" {
  local m
  m="$(mutant index-created-from-source 'cp "$out/charts/index.yaml" "$out/index.yaml"')" || { echo "$m"; return 1; }
  seed_mirror
  PUB_UNDER_TEST="$m" idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(created_for 1.0.0 <"$OUT/stage/index.yaml")" != '"2026-01-01T12:00:00Z"' ] || return 1
}

@test "the index.yaml and *.tgz files on the mirror's gh-pages are kept in the stage; only index.yaml is replaced; nothing dropped" {
  seed_mirror
  seed_pages client-0.9.0.tgz 'not really gzip' index.yaml $'apiVersion: v1\nentries: {}\n'
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || return 1
  [ "$(res dropped)" = 0 ] || { cat "$RESULT"; return 1; }
  [ "$(cd "$OUT/stage" && find . -type f | sed 's|^\./||' | sort | paste -sd' ' -)" = "client-0.9.0.tgz index.yaml" ] || { ls -R "$OUT/stage"; return 1; }
  [ "$(cat "$OUT/stage/client-0.9.0.tgz")" = "not really gzip" ] || return 1
  grep -q 'releases/download/v1.0.2/client-1.0.2.tgz' "$OUT/stage/index.yaml" || return 1
  [[ "$output" != *"dropping"* ]] || { echo "$output"; return 1; }
}

# ── the Pages allowlist over what the branch already carries ──────────────────

@test "Pages allowlist: a stray file, a directory and a symlink on the mirror's gh-pages are dropped from the stage, each named by kind; the drop ALONE is changed=true; the push prunes them and the next derivation is changed=false" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  push_stage
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 1 ] || return 1
  # Strays land on the branch the way a hand push would leave them; the
  # index.yaml already there is the one just derived, so only the drops differ.
  local c
  c="$(pages_clone)" || return 1
  printf 'hello\n' >"$c/notes.txt"
  printf 'not really gzip' >"$c/client-0.9.0.tgz"
  mkdir -p "$c/assets"; printf 'x\n' >"$c/assets/x.txt"
  ln -s index.yaml "$c/link.yaml"
  pages_push "$c" || return 1
  [ "$(pages_commits)" -eq 2 ] || return 1
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = true ] || { cat "$RESULT"; return 1; }
  [ "$(res dropped)" = 3 ] || { cat "$RESULT"; return 1; }
  [ "$(cd "$OUT/stage" && find . -mindepth 1 | sed 's|^\./||' | sort | paste -sd' ' -)" = "client-0.9.0.tgz index.yaml" ] || { ls -laR "$OUT/stage"; return 1; }
  [[ "$output" == *"index: dropping 'notes.txt' from the mirror's gh-pages — neither index.yaml nor a *.tgz; the Pages branch carries only index.yaml and chart tarballs as plain files, so the push prunes it"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"index: dropping 'assets' from the mirror's gh-pages — a directory;"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"index: dropping 'link.yaml' from the mirror's gh-pages — a symlink;"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"index.yaml unchanged against the mirror's gh-pages (present), 3 item(s) dropped from the branch;"* ]] || { echo "$output"; return 1; }
  push_stage
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == pushed\ [0-9a-f]* ]] || { echo "$output"; return 1; }
  [ "$(pages_commits)" -eq 3 ] || return 1
  [ "$(git -C "$BARE" ls-tree --name-only gh-pages | sort | paste -sd' ' -)" = "client-0.9.0.tgz index.yaml" ] || return 1
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res changed)" = false ] || { cat "$RESULT"; return 1; }
  [ "$(res dropped)" = 0 ] || return 1
}

@test "mutation: with the allowlist not applied to plain files, the stray file is staged again and the push carries it forward — the test above catches it" {
  local m
  m="$(mutant index-pages-allowlist '      else :; fi')" || { echo "$m"; return 1; }
  seed_mirror
  seed_pages notes.txt $'hello\n' index.yaml $'apiVersion: v1\nentries: {}\n'
  PUB_UNDER_TEST="$m" idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$OUT/stage/notes.txt" ] || { ls -la "$OUT/stage"; return 1; }
  [ "$(res dropped)" = 0 ] || return 1
  [[ "$output" != *"dropping 'notes.txt'"* ]] || return 1
  # The real script drops it.
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$OUT/stage/notes.txt" ] || return 1
}

@test "a directory on the mirror's gh-pages used to stop the guard (--assets takes plain files only) on every publish; dropped first, the derivation succeeds" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || return 1
  push_stage
  [ "$status" -eq 0 ] || return 1
  local c
  c="$(pages_clone)" || return 1
  mkdir -p "$c/charts"; printf 'x\n' >"$c/charts/stray.txt"
  pages_push "$c" || return 1
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res dropped)" = 1 ] || return 1
  # Kept verbatim, the same directory is the guard's could-not-tell — the
  # failure the allowlist pass exists to prevent (the guard's own rule, exercised
  # here through the real guard, not restated).
  rm -rf "$OUT/stage/charts"; mkdir -p "$OUT/stage/charts"; printf 'x\n' >"$OUT/stage/charts/stray.txt"
  run bash "$REPO_ROOT/scripts/publish-guard.sh" --source "$OUT/scratch-src" --include "$OUT/include.txt" --forbidden "$REPO_ROOT/.publish-forbidden" --out "$BATS_TEST_TMPDIR/guard-out" --assets "$OUT/stage"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"holds something other than plain files (a directory or a symlink)"* ]] || { echo "$output"; return 1; }
}

# ── --mirror-releases: the caller's read of the list ──────────────────────────

@test "--mirror-releases: the caller's read of the mirror's release list is used — the list is not paginated again — and yields the same index; a missing or empty file is could-not-tell before any gh call" {
  seed_mirror
  idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^api --paginate repos/acme/mirror/releases$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  local fresh="$BATS_TEST_TMPDIR/fresh-index.yaml"
  cp "$OUT/index.yaml" "$fresh"
  # As `gh api --paginate` prints it — here one page.
  cp "$STATE/mirror-releases.json" "$BATS_TEST_TMPDIR/mirror-list.json"
  idx --mirror-releases "$BATS_TEST_TMPDIR/mirror-list.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^api --paginate repos/acme/mirror/releases$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  [ "$(grep -c '^release download ' "$GH_LOG")" -eq 4 ] || { cat "$GH_LOG"; return 1; }
  cmp -s <(grep -v '^generated:' "$fresh") <(grep -v '^generated:' "$OUT/index.yaml") || { diff "$fresh" "$OUT/index.yaml"; return 1; }
  idx --mirror-releases "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: --mirror-releases '"*"absent.json' is missing or empty"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GH_LOG" ] || { cat "$GH_LOG"; return 1; }
}

# ── nothing to index ──────────────────────────────────────────────────────────

@test "a mirror with no chart tarball on any stable release is refused (exit 1); --allow-empty makes it charts=0 changed=false, exit 0; a prerelease-only mirror counts as none" {
  idx
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — index: the mirror 'acme/mirror' carries no chart tarball on any stable release — a Helm index with nothing in it is not published"* ]] || { echo "$output"; return 1; }
  [ ! -e "$RESULT" ] || return 1
  idx --allow-empty
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(res charts)" = 0 ] || return 1
  [ "$(res changed)" = false ] || return 1
  [[ "$output" == *"carries no chart tarball on any stable release yet — nothing to index (--allow-empty)"* ]] || return 1
  add_release v1.0.4-rc.1 true "$CHARTS/client-1.0.4-rc.1.tgz"
  idx
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ ! -s "$OUT/stage/index.yaml" ] || return 1
}

# ── could not tell ────────────────────────────────────────────────────────────

@test "a mirror download whose bytes are not the mirror's digest is could-not-tell, never indexed" {
  seed_mirror
  printf 'tampered\n' >>"$STATE/assets/v1.0.1/client-1.0.1.tgz"
  idx
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: 'client-1.0.1.tgz' from 'acme/mirror' release 'v1.0.1' hashes to "*", the mirror says "*" — the download is not the asset"* ]] || { echo "$output"; return 1; }
  [ ! -e "$RESULT" ] || return 1
  [ ! -e "$OUT/index.yaml" ] || return 1
}

@test "mutation: with the download digest check removed, the tampered tarball is indexed, exit 0 — the test above catches it" {
  local m
  m="$(mutant index-download-digest ':')" || { echo "$m"; return 1; }
  seed_mirror
  # The asset's bytes are swapped for ANOTHER valid client 1.0.1 (a different
  # description, so different bytes) while the mirror keeps the original digest:
  # helm still reads it as client 1.0.1, so only the digest check can tell.
  local src="$BATS_TEST_TMPDIR/rebuilt-src"; mkdir -p "$src" "$BATS_TEST_TMPDIR/rebuilt"
  printf 'apiVersion: v2\nname: client\nversion: 1.0.1\ndescription: not the published bytes\n' >"$src/Chart.yaml"
  helm package "$src" --destination "$BATS_TEST_TMPDIR/rebuilt" >/dev/null
  cp "$BATS_TEST_TMPDIR/rebuilt/client-1.0.1.tgz" "$STATE/assets/v1.0.1/client-1.0.1.tgz"
  idx
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  PUB_UNDER_TEST="$m" idx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'client-1.0.1.tgz' "$OUT/stage/index.yaml" || return 1
}

@test "a tarball that is not the chart its name says, and a mirror release the source list has no date for, are could-not-tell" {
  seed_mirror
  cp "$CHARTS/ingestor-0.2.0.tgz" "$STATE/assets/v1.0.2/client-1.0.2.tgz"
  jq --arg d "sha256:$(sha256_of "$CHARTS/ingestor-0.2.0.tgz")" '(.[] | select(.tag_name == "v1.0.2") | .assets[] | select(.name == "client-1.0.2.tgz") | .digest) = $d' "$STATE/mirror-releases.json" >"$STATE/t.json" && mv "$STATE/t.json" "$STATE/mirror-releases.json"
  idx
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: 'client-1.0.2.tgz' contains chart 'ingestor' version '0.2.0', not what its name says"* ]] || { echo "$output"; return 1; }
  add_release v9.9.9 false "$CHARTS/client-1.0.3.tgz"
  idx
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: mirror release 'v9.9.9' has no publish date in '$SRC_RELEASES' — a release the source never had cannot be placed in time"* ]] || { echo "$output"; return 1; }
  # Placed in time comes before any download.
  ! grep -q '^release download' "$GH_LOG" || return 1
}

@test "an unreadable mirror release list, an unanswering remote, a missing or malformed source list, and a non-empty --out are could-not-tell naming the cause" {
  seed_mirror
  FAKE_GH_FAIL_RE='^api --paginate repos/acme/mirror/releases$' idx
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: could not read the releases of 'acme/mirror' (gh api --paginate repos/acme/mirror/releases failed: gh: Internal Server Error (HTTP 500)"* ]] || { echo "$output"; return 1; }
  rm -rf "$OUT" "$RESULT"
  run env PATH="$SHIM:$PATH" GH_LOG="$GH_LOG" FAKE_GH_STATE="$STATE" PUBLISH_GUARD_GITLEAKS="$SHIM/gitleaks" \
    bash "$PUB" index --repo acme/mirror --source-releases "$SRC_RELEASES" --out "$OUT" --remote "file://$BATS_TEST_TMPDIR/no-such.git" --output "$RESULT"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — index: the mirror remote did not answer (git ls-remote:"* ]] || { echo "$output"; return 1; }
  rm -rf "$OUT"
  run bash "$PUB" index --repo acme/mirror --source-releases "$BATS_TEST_TMPDIR/absent.json" --out "$OUT"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--source-releases '"*"absent.json' is missing or empty"* ]] || { echo "$output"; return 1; }
  printf 'not json' >"$BATS_TEST_TMPDIR/garbage.json"; rm -rf "$OUT"
  run env PATH="$SHIM:$PATH" bash "$PUB" index --repo acme/mirror --source-releases "$BATS_TEST_TMPDIR/garbage.json" --out "$OUT"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"did not parse as a release list"* ]] || { echo "$output"; return 1; }
  mkdir -p "$OUT"; printf 'stale' >"$OUT/leftover"
  run env PATH="$SHIM:$PATH" bash "$PUB" index --repo acme/mirror --source-releases "$SRC_RELEASES" --out "$OUT"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--out '$OUT' is not empty"* ]] || { echo "$output"; return 1; }
  run bash "$PUB" index --repo acme/mirror --out "$BATS_TEST_TMPDIR/x"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--repo, --source-releases and --out are all required"* ]] || return 1
}

@test "the script names no repository of its own: the mirror, the source list and the remote are all the caller's" {
  ! grep -qE 'tracebloc/client|github\.com/tracebloc|acme/' "$PUB" || return 1
  run bash "$PUB" --help
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"index    --repo OWNER/NAME --source-releases FILE --out DIR"* ]] || return 1
}
