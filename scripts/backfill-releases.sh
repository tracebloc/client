#!/usr/bin/env bash
# =============================================================================
#  backfill-releases.sh — one-shot backfill of this repository's HISTORICAL
#  releases onto the public deliverable mirror, and of the Helm repository
#  index the mirror serves for them.
#
#  .github/workflows/mirror-publish.yaml publishes each NEW release to the
#  mirror as it is cut. Releases that existed before the mirror did are carried
#  over once, by this script, run by a human. Idempotent: a re-run over an
#  already-backfilled mirror reads everything and writes nothing.
#
#  THE DECISION (taken once, stated here so nobody re-derives it):
#    * every published release — stable and prerelease alike, the way the
#      workflow mirrors both — gets its tag and its GitHub release on the
#      mirror with ALL of its assets: the packaged charts (`*.tgz`), the two
#      installer bootstraps, the signed manifest and its cosign companions.
#      Chart tarballs are small, so nothing is cut; BINARY_KEEP exists for the
#      day that changes and defaults to `all`;
#    * drafts are never carried; `--stable-only` leaves prereleases out;
#    * the mirror's `gh-pages` branch must serve the Helm repository for what
#      was backfilled: `--pages` rebuilds `index.yaml` from the chart tarballs
#      the MIRROR's releases carry, every URL a release-asset download URL on
#      the mirror, and pushes it through the same publisher step the workflow
#      uses for the Pages branch. The rebuild itself is publish-mirror.sh
#      `index` — the same command the workflow runs on every stable publish, so
#      a publish after the backfill re-derives the index from the mirror
#      instead of overwriting it.
#
#  HOW MIRROR TAGS ARE ANCHORED: the mirror holds the deliverable, not the
#  source, so no tag can point at the commit a release was built from. Each
#  tag is created as an ANNOTATED tag on the mirror's default-branch head. The
#  annotation carries the ORIGINAL date (the source tag's tagger date when the
#  source tag is annotated, the release's created_at otherwise) and the
#  original message, and says in plain words that the tag is a RELEASE MARKER
#  on the mirror, not a source snapshot. The original message is source text
#  that lands on the public mirror, so it goes through the guard's
#  forbidden-string scan with the notes, before any write (a hit refuses the
#  release and names the tier). A tag already on the mirror is accepted only
#  if it points at a commit the mirror has; a dangling one is refused, never
#  repointed.
#
#  RELEASE NOTES: --notes fixed (DEFAULT) writes the same fixed text the
#  workflow writes for new releases. Historical source bodies are GitHub's
#  generated ones — merged pull requests by title — and nearly every one
#  carries strings the guard's report tier counts, which the public mirror
#  should not repeat; so the source body is an explicit opt-in: --notes source
#  carries it, and it then goes through the guard's forbidden-string scan like
#  any text asset (a hit refuses the release and names the tier). Either way a
#  footer names the original publish date (GitHub does not let a created
#  release carry a past date, so the footer and the tag annotation are where
#  the date survives).
#
#  WHAT IS REUSED: scripts/publish-mirror.sh `target` decides the mirror name
#  (unset, malformed, or equal to the source is refused there — one rule, one
#  place), `index` rebuilds the Helm index from the mirror's releases and runs
#  the guard over the staged Pages branch (one implementation, shared with the
#  workflow), and `tree` pushes the Pages branch (plain push, never a force; the
#  caller's git credentials, so no token lands on a command line);
#  scripts/publish-guard.sh scans every text asset, the notes and the rebuilt
#  index.yaml with the repo's own .publish-forbidden (and the private needles
#  from BACKFILL_EXTRA_FORBIDDEN, when given) plus gitleaks, before anything is
#  uploaded or pushed. Chart tarballs are opaque to a string scan by design;
#  each one is verified against the SOURCE release's asset digest (the API's
#  sha256, which every asset carries) and, where the source's own Helm index
#  lists that chart version, against the index's digest too — a mismatch
#  refuses the release naming the asset, and a tarball whose source digest is
#  missing is refused too: "cannot verify" is not "verified".
#
#  Usage:
#    MIRROR_REPO=NAME scripts/backfill-releases.sh [--dry-run | --apply]
#        [--from-tag TAG | --only-tag TAG] [--stable-only]
#        [--notes fixed|source] [--strict] [--pages]
#
#  Environment:
#    SOURCE_REPO     OWNER/REPO to read releases from (default: the repository
#                    `gh repo view` reports for the current checkout)
#    MIRROR_REPO     bare repository name in the source's organisation; REQUIRED
#    BINARY_KEEP     `all` (default) or how many of the newest releases carry
#                    their chart tarballs; the rest carry text assets only
#    BACKFILL_EXTRA_FORBIDDEN
#                    file of extra refuse-tier needles for the guard (the
#                    private list the workflow gets from a secret); optional
#    BACKFILL_PAGES_REMOTE
#                    git URL of the mirror for the Pages branch (default
#                    https://github.com/OWNER/NAME.git); tests point it at file://
#    PUBLISH_MIRROR_GIT_NAME / PUBLISH_MIRROR_GIT_EMAIL
#                    tagger identity on the mirror tags (default github-actions[bot])
#    GH_TOKEN        gh's; must be able to write the mirror under --apply. The
#                    --pages push goes through git, so git needs credentials
#                    for the mirror too (`gh auth setup-git`, or the credential
#                    helper the workflow configures).
#
#  Modes:
#    --dry-run       DEFAULT. Every read runs, the text assets and notes of
#                    each release that would change are downloaded and put
#                    through the guard, the plan is printed, nothing is written.
#                    With --pages the index is rebuilt from the mirror's current
#                    releases, guarded and compared, and not pushed.
#    --apply         performs the writes: tag, release, uploads; then, with
#                    --pages, the index push.
#    --from-tag TAG  resume: process TAG and every release newer than it
#                    (releases are processed oldest to newest).
#    --only-tag TAG  process TAG alone.
#                    Both keep the BINARY_KEEP decision of the FULL list, so a
#                    partial run carries the same tarballs a full run would.
#    --pages         after the releases: rebuild the mirror's index.yaml from
#                    the chart tarballs on the mirror's STABLE releases (the
#                    chart workflow keeps prereleases out of the index, so does
#                    this), each chart version placed under the OLDEST release
#                    that carries it, `created` set to that release's original
#                    publish date so the index is the same bytes on every run;
#                    push to the mirror's gh-pages when it differs from what is
#                    there, keeping the index.yaml and *.tgz files already on
#                    that branch and dropping anything else. The rebuild
#                    is publish-mirror.sh `index` (its header has the contract);
#                    this script adds the push. Needs helm, and says so before
#                    any gh call.
#
#  Exit 0 done (every release created or already present); 1 at least one
#  release was REFUSED (the table says which and why; the rest went ahead);
#  2 COULD NOT TELL — a read that did not complete, a tool missing, an input
#  malformed. "Cannot tell" stops the run at once and never writes.
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="${BACKFILL_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
PUBLISH_MIRROR="$SCRIPTS_DIR/publish-mirror.sh"
PUBLISH_GUARD="$SCRIPTS_DIR/publish-guard.sh"
FORBIDDEN_LIST="$REPO_ROOT/.publish-forbidden"
HELM="${BACKFILL_HELM:-helm}"

# die2 REASON — could-not-tell: the reason, then exit 2. The reason goes to
# STDERR on purpose: most callers (jq_of above all) sit inside "$(...)", where
# stdout is the variable being assigned — a stdout reason would be captured
# into it and never seen, leaving a bare exit 2. On stderr it reaches the
# operator either way, and the substitution's status 2 aborts the assignment
# under `set -e`. That abort is the ONLY thing ending the parent, so never
# put a die2-capable "$(...)" inside an && / || list or a `[ ]` test, where
# `set -e` is suspended — hoist it into its own assignment first (the
# per-release block does).
die2() { echo "::error::backfill-releases: COULD NOT TELL — $1 (nothing more is written)" >&2; exit 2; }   # mutation-anchor: die2-stderr
note() { echo "backfill-releases: $1"; }

# ---- arguments -----------------------------------------------------------------
APPLY=0; FROM_TAG=""; ONLY_TAG=""; STABLE_ONLY=0; NOTES_MODE=fixed; STRICT=0; PAGES=0   # mutation-anchor: notes-default-fixed
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)     APPLY=0; shift ;;
    --apply)       APPLY=1; shift ;;
    --from-tag)    FROM_TAG="${2:-}"; shift 2 ;;
    --only-tag)    ONLY_TAG="${2:-}"; shift 2 ;;
    --stable-only) STABLE_ONLY=1; shift ;;
    --notes)       NOTES_MODE="${2:-}"; shift 2 ;;
    --strict)      STRICT=1; shift ;;
    --pages)       PAGES=1; shift ;;
    -h|--help)     sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die2 "unknown argument '$1' (see --help)" ;;
  esac
done
[ -z "$FROM_TAG" ] || [ -z "$ONLY_TAG" ] || die2 "--from-tag and --only-tag exclude each other"
case "$NOTES_MODE" in fixed|source) ;; *) die2 "--notes must be 'fixed' or 'source', not '$NOTES_MODE'" ;; esac
BINARY_KEEP="${BINARY_KEEP:-all}"
[ "$BINARY_KEEP" = all ] || [[ "$BINARY_KEEP" =~ ^[0-9]+$ ]] || die2 "BINARY_KEEP '$BINARY_KEEP' is neither 'all' nor a non-negative integer"
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
# <chart>-<version>.tgz: the chart name, then a semver (with an optional
# prerelease suffix), read off an UPLOAD's file name to look its digest up in
# the source's Helm index. publish-mirror.sh `index` carries the same
# expression for the mirror's tarballs and also checks it against what
# `helm show chart` reads inside; the shape of a chart file name is helm's,
# not either script's, which is why both spell it the same way.
CHART_FILE_RE='^([A-Za-z0-9_.-]+)-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)\.tgz$'
[ -z "$FROM_TAG" ] || [[ "$FROM_TAG" =~ $TAG_RE ]] || die2 "--from-tag '$FROM_TAG' is not a release tag"
[ -z "$ONLY_TAG" ] || [[ "$ONLY_TAG" =~ $TAG_RE ]] || die2 "--only-tag '$ONLY_TAG' is not a release tag"

# ---- tools -----------------------------------------------------------------------
for t in gh jq git awk base64; do command -v "$t" >/dev/null 2>&1 || die2 "'$t' is not on PATH"; done
command -v "${PUBLISH_GUARD_GITLEAKS:-gitleaks}" >/dev/null 2>&1 || die2 "'${PUBLISH_GUARD_GITLEAKS:-gitleaks}' is not on PATH — the guard treats a missing scanner as could-not-tell, so nothing could be uploaded"
if [ "$PAGES" -eq 1 ]; then
  # A pre-flight, so a run that will need helm says so before its first gh
  # call; publish-mirror.sh `index` refuses a missing helm again on its own.
  command -v "$HELM" >/dev/null 2>&1 || die2 "'$HELM' is not on PATH — --pages rebuilds the Helm index with it, and an index built any other way is not one helm would"   # mutation-anchor: helm-required
fi
[ -f "$PUBLISH_MIRROR" ] || die2 "$PUBLISH_MIRROR is missing"
[ -f "$PUBLISH_GUARD" ]  || die2 "$PUBLISH_GUARD is missing"
[ -r "$FORBIDDEN_LIST" ] || die2 "$FORBIDDEN_LIST is missing or unreadable — the scan has no rules"
if [ -n "${BACKFILL_EXTRA_FORBIDDEN:-}" ]; then
  [ -s "$BACKFILL_EXTRA_FORBIDDEN" ] || die2 "BACKFILL_EXTRA_FORBIDDEN '$BACKFILL_EXTRA_FORBIDDEN' is missing or empty"
fi
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die2 "neither sha256sum nor shasum is on PATH"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/backfill-releases.XXXXXX")" && [ -d "$TMP" ] || die2 "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# ---- gh wrappers -----------------------------------------------------------------
# gh_read OUTFILE ARGS... — a READ that must complete. Any failure is
# could-not-tell: an unreadable list is never an empty list.
gh_read() {
  local out="$1"; shift
  if ! gh "$@" >"$out" 2>"$TMP/gh.err"; then
    die2 "gh $* failed: $(tr '\n' ' ' <"$TMP/gh.err")"
  fi
}
# gh_read_maybe OUTFILE ARGS... — a READ where "not there" is an answer.
# Returns 0 on success, 1 on a clear HTTP 404 or the HTTP 409 GitHub gives for
# a commit read on an EMPTY repository; anything else is could-not-tell.
gh_read_maybe() {
  local out="$1"; shift
  if gh "$@" >"$out" 2>"$TMP/gh.err"; then return 0; fi
  grep -qE 'HTTP 404|HTTP 409' "$TMP/gh.err" && return 1
  die2 "gh $* failed: $(tr '\n' ' ' <"$TMP/gh.err")"
}
# gh_write OUTFILE ARGS... — a WRITE (apply only). A failed write is fatal:
# the mirror may now be half-changed and the human decides, with the table.
gh_write() {
  local out="$1"; shift
  [ "$APPLY" -eq 1 ] || die2 "internal: gh_write reached in dry-run (gh $*)"
  if ! gh "$@" >"$out" 2>"$TMP/gh.err"; then
    die2 "gh $* failed: $(tr '\n' ' ' <"$TMP/gh.err") — re-run to resume; completed steps are skipped"
  fi
}
# jq_of FILE FILTER — jq over a file that MUST parse; a malformed answer is
# could-not-tell, not an empty one.
jq_of() { jq -r "$2" "$1" 2>"$TMP/jq.err" || die2 "could not parse $1 with '$2': $(tr '\n' ' ' <"$TMP/jq.err")"; }

# ---- source and mirror ---------------------------------------------------------------
SRC="${SOURCE_REPO:-}"
if [ -z "$SRC" ]; then
  gh_read "$TMP/self.json" repo view --json nameWithOwner
  SRC="$(jq_of "$TMP/self.json" '.nameWithOwner')"
fi
[[ "$SRC" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die2 "source repository '$SRC' is not OWNER/REPO"

# The mirror name is decided by publish-mirror.sh `target`, so an unset or
# malformed name and a mirror equal to the source are refused by the same rule
# the workflow applies. Run directly, output captured to a file: its
# ::error:: line is the reason, and its exit status is ours.
rc=0
bash "$PUBLISH_MIRROR" target --mirror "${MIRROR_REPO:-}" --source-repo "$SRC" >"$TMP/target.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then cat "$TMP/target.out"; echo "::error::backfill-releases: REFUSED — the mirror target was refused above"; exit "$rc"; fi
MIRROR="$(tail -1 "$TMP/target.out")"

gh_read "$TMP/mirror.json" api "repos/$MIRROR"
MIRROR_FULL="$(jq_of "$TMP/mirror.json" '.full_name')"
MIRROR_BRANCH="$(jq_of "$TMP/mirror.json" '.default_branch')"
if [ "$(printf '%s' "$MIRROR_FULL" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$SRC" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "::error::backfill-releases: REFUSED — mirror '$MIRROR_FULL' resolves to the source repository"; exit 1
fi
[ -n "$MIRROR_BRANCH" ] && [ "$MIRROR_BRANCH" != null ] || die2 "mirror '$MIRROR' reports no default branch"
# Every mirror tag is anchored here. An empty mirror has no head: that is a
# refusal with instructions, not a guess.
if ! gh_read_maybe "$TMP/head.json" api "repos/$MIRROR/commits/$MIRROR_BRANCH"; then
  echo "::error::backfill-releases: REFUSED — mirror '$MIRROR' has no commit on '$MIRROR_BRANCH' to anchor tags to; publish the deliverable tree first"; exit 1
fi
MIRROR_HEAD="$(jq_of "$TMP/head.json" '.sha')"
[[ "$MIRROR_HEAD" =~ ^[0-9a-f]{40}$ ]] || die2 "mirror head '$MIRROR_HEAD' is not a commit sha"
PAGES_REMOTE="${BACKFILL_PAGES_REMOTE:-https://github.com/$MIRROR.git}"

# ---- the release list, derived from the API -----------------------------------------
# --paginate concatenates one JSON array per page; `jq -s add` joins them.
gh_read "$TMP/src-pages.json" api --paginate "repos/$SRC/releases"   # mutation-anchor: releases-read-fail-closed
jq -s 'add // []' "$TMP/src-pages.json" >"$TMP/src-releases.json" 2>"$TMP/jq.err" || die2 "release list of '$SRC' did not parse: $(tr '\n' ' ' <"$TMP/jq.err")"
# Newest first by created_at; drafts never; prereleases unless --stable-only.
FILTER='[ .[] | select(.draft == false) | select($stable == 0 or .prerelease == false) ] | sort_by(.created_at) | reverse'
jq --argjson stable "$STABLE_ONLY" "$FILTER" "$TMP/src-releases.json" >"$TMP/releases.json" 2>"$TMP/jq.err" || die2 "could not filter the release list: $(tr '\n' ' ' <"$TMP/jq.err")"
N_ALL="$(jq_of "$TMP/releases.json" 'length')"
[ "$N_ALL" -gt 0 ] || die2 "'$SRC' has no published release matching the filter — nothing to backfill is not a clean run"
jq -r '.[].tag_name' "$TMP/releases.json" >"$TMP/tags-newest-first.txt"
while IFS= read -r t; do [[ "$t" =~ $TAG_RE ]] || die2 "release tag '$t' on '$SRC' is not a release tag"; done <"$TMP/tags-newest-first.txt"
# Which releases carry their chart tarballs: all of them (the default), or the
# newest BINARY_KEEP of the FULL filtered list — decided before
# --from-tag/--only-tag narrow the run, so a partial run agrees with a full one.
if [ "$BINARY_KEEP" = all ]; then
  cp "$TMP/tags-newest-first.txt" "$TMP/tags-with-binaries.txt"
else
  head -n "$BINARY_KEEP" "$TMP/tags-newest-first.txt" >"$TMP/tags-with-binaries.txt"
fi
NEWEST_STABLE="$(jq_of "$TMP/releases.json" '[ .[] | select(.prerelease == false) ] | .[0].tag_name // ""')"
carries_binaries() { grep -qxF -- "$1" "$TMP/tags-with-binaries.txt"; }

# The source's own Helm index — the chart manifest: name, version, digest per
# entry. A chart version it lists must hash to that digest wherever it is
# carried. Read from the Pages branch; an index that cannot be read is
# could-not-tell, not an empty one.
gh_read "$TMP/src-index.json" api "repos/$SRC/contents/index.yaml?ref=gh-pages"
jq_of "$TMP/src-index.json" '.content' | tr -d '\n' | base64 -d >"$TMP/src-index.yaml" 2>"$TMP/b64.err" || die2 "the Helm index of '$SRC' did not decode: $(tr '\n' ' ' <"$TMP/b64.err")"
[ -s "$TMP/src-index.yaml" ] || die2 "the Helm index of '$SRC' (gh-pages index.yaml) is empty"
# index_entries FILE → `name<TAB>version<TAB>digest` per chart entry. Entries
# are the `  - ` items under `entries:`; field order inside one does not matter.
index_entries() {
  awk '
    function flush() { if (n != "" && v != "") print n "\t" v "\t" d; n = ""; v = ""; d = "" }
    /^  - /          { flush() }
    /^    name: /    { n = $2 }
    /^    version: / { v = $2 }
    /^    digest: /  { d = $2 }
    END              { flush() }
  ' "$1"
}
index_entries "$TMP/src-index.yaml" >"$TMP/src-index.tsv"
[ "$(grep -c . "$TMP/src-index.tsv")" -gt 0 ] || die2 "the Helm index of '$SRC' lists no chart — a manifest with nothing in it cannot vouch for a tarball"
src_index_digest() { awk -F'\t' -v n="$1" -v v="$2" '$1 == n && $2 == v { print $3; exit }' "$TMP/src-index.tsv"; }

# Processing order: oldest to newest, so the mirror's release order reads like
# the source's and the newest stable release is created last.
sed -n '1!G;h;$p' "$TMP/tags-newest-first.txt" >"$TMP/tags-ordered.txt"
if [ -n "$ONLY_TAG" ]; then
  grep -qxF -- "$ONLY_TAG" "$TMP/tags-ordered.txt" || die2 "--only-tag '$ONLY_TAG' is not a release of '$SRC' matching the filter"
  printf '%s\n' "$ONLY_TAG" >"$TMP/tags-run.txt"
elif [ -n "$FROM_TAG" ]; then
  grep -qxF -- "$FROM_TAG" "$TMP/tags-ordered.txt" || die2 "--from-tag '$FROM_TAG' is not a release of '$SRC' matching the filter"
  awk -v t="$FROM_TAG" 'f || $0 == t { f = 1; print }' "$TMP/tags-ordered.txt" >"$TMP/tags-run.txt"
else
  cp "$TMP/tags-ordered.txt" "$TMP/tags-run.txt"
fi
N_RUN="$(grep -c . "$TMP/tags-run.txt" || true)"

# ---- what the mirror already has ----------------------------------------------------
read_mirror_releases() {
  gh_read "$TMP/mirror-pages.json" api --paginate "repos/$MIRROR/releases"
  jq -s 'add // []' "$TMP/mirror-pages.json" >"$TMP/mirror-releases.json" 2>"$TMP/jq.err" || die2 "release list of '$MIRROR' did not parse"
}
read_mirror_releases
gh_read "$TMP/mirror-tag-pages.json" api --paginate "repos/$MIRROR/git/matching-refs/tags/"
jq -s 'add // []' "$TMP/mirror-tag-pages.json" >"$TMP/mirror-tags.json" 2>"$TMP/jq.err" || die2 "tag list of '$MIRROR' did not parse"

MODE=dry-run; [ "$APPLY" -eq 1 ] && MODE=apply
if [ "$BINARY_KEEP" = all ]; then KEEP_TEXT="tarballs for every release"; else KEEP_TEXT="tarballs for the newest $BINARY_KEEP"; fi
FILTER_TEXT="stable and prerelease"; [ "$STABLE_ONLY" -eq 0 ] || FILTER_TEXT="stable only"
note "source $SRC → mirror $MIRROR ($MIRROR_BRANCH @ ${MIRROR_HEAD:0:12}); $N_ALL release(s) match the filter ($FILTER_TEXT), $N_RUN in this run; $KEEP_TEXT; notes=$NOTES_MODE; pages=$PAGES; mode=$MODE"
[ "$STRICT" -eq 0 ] || note "--strict: the guard's [strings-report] tier refuses"

# ---- the guard's scratch source tree -------------------------------------------------
# publish-guard.sh stages a tree from a git checkout by design. The backfill has
# no tree to publish, so it hands the guard a one-file scratch checkout and puts
# what matters — the text assets, the notes, the index — in --assets, where
# guards 2–4 (forbidden paths, forbidden strings, gitleaks) read them.
SCRATCH="$TMP/scratch-src"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q || die2 "could not init the guard's scratch checkout"
printf 'backfill scratch tree\n' >"$SCRATCH/README.md"
# This runs on a human's machine: a global commit.gpgsign=true would try to
# sign the scratch commit as backfill@localhost, fail, and end the run before
# a single release is planned. The scratch commit is never published — unsigned.
git -C "$SCRATCH" add README.md && git -C "$SCRATCH" -c user.name=backfill -c user.email=backfill@localhost -c commit.gpgsign=false commit -q -m scratch || die2 "could not commit the guard's scratch checkout"
printf 'README.md\n' >"$TMP/include.txt"

# run_guard ASSETS_DIR OUT_DIR — the guard over ASSETS_DIR. Returns the guard's
# exit status (0 clean, 1 refused, 2 could not tell); its output is in OUT_DIR.log.
run_guard() {
  local assets="$1" out="$2" rc=0
  local -a args=(--source "$SCRATCH" --include "$TMP/include.txt" --forbidden "$FORBIDDEN_LIST" --out "$out" --assets "$assets")
  [ -z "${BACKFILL_EXTRA_FORBIDDEN:-}" ] || args+=(--extra-forbidden "$BACKFILL_EXTRA_FORBIDDEN")
  [ "$STRICT" -eq 0 ] || args+=(--strict)
  bash "$PUBLISH_GUARD" "${args[@]}" >"$out.log" 2>&1 || rc=$?
  return "$rc"
}
guard_refusal_text() { grep -E 'REFUSED' "$1" | sed 's/^::error::publish-guard: //' | paste -sd';' -; }

# ---- per-release helpers -------------------------------------------------------------------
# Decision files: one line per asset, `name<TAB>action<TAB>sha`, action one of
# upload | skip | compare | refuse. `compare` means the mirror has the asset and
# the source's digest is unknown, so the download is hashed before deciding.
count_action() { awk -F'\t' -v a="$2" '$2 == a { n++ } END { print n + 0 }' "$1"; }
mirror_digest() { # NAME → sha256 hex; "" when absent; "?" when present without a digest
  [ "$MREL_PRESENT" -eq 1 ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { print ($2 == "" ? "?" : $2); exit }' "$R/mirror-assets.tsv"
}
# decide LIST NAME EXPECTED_SHA — EXPECTED_SHA may be "" (unknown).
decide() {
  local list="$1" name="$2" expected="$3" have
  have="$(mirror_digest "$name")"
  if [ "$have" = "?" ]; then die2 "$TAG: mirror asset '$name' has no digest — cannot tell whether it matches"; fi
  if [ -z "$have" ]; then printf '%s\tupload\t%s\n' "$name" "$expected" >>"$list"; return 0; fi
  if [ -z "$expected" ]; then printf '%s\tcompare\t%s\n' "$name" "$have" >>"$list"; return 0; fi
  if [ "$have" = "$expected" ]; then printf '%s\tskip\t%s\n' "$name" "$expected" >>"$list"; return 0; fi   # mutation-anchor: idempotent-skip
  [ -n "$REFUSAL" ] || REFUSAL="asset '$name' is on the mirror with SHA256 $have but the source release says $expected — a published asset is never replaced"
  printf '%s\trefuse\t%s\n' "$name" "$expected" >>"$list"
}
# resolve_compares LIST DIR — hash each `compare` download; equal → skip,
# different → REFUSAL (a published asset is never replaced).
resolve_compares() {
  local list="$1" dir="$2" aname action have got
  while IFS=$'\t' read -r aname action have; do
    [ "$action" = compare ] || continue
    [ -f "$dir/$aname" ] || die2 "$TAG: '$aname' did not download from '$SRC'"
    got="$(sha256_of "$dir/$aname")"
    if [ "$got" = "$have" ]; then
      awk -F'\t' -v OFS='\t' -v n="$aname" '$1 == n && $2 == "compare" { $2 = "skip" } { print }' "$list" >"$list.new" && mv "$list.new" "$list"
    else
      [ -n "$REFUSAL" ] || REFUSAL="asset '$aname' is on the mirror with SHA256 $have but the source's is $got — a published asset is never replaced"
    fi
  done <"$list"
}
# download_listed LIST DIR — `gh release download` of every upload/compare
# entry in LIST into DIR (one call; a pattern that matches nothing is an error
# gh reports, which is could-not-tell here).
download_listed() {
  local list="$1" dir="$2" f
  local -a pats=()
  while IFS= read -r f; do pats+=(--pattern "$f"); done < <(awk -F'\t' '$2 == "upload" || $2 == "compare" { print $1 }' "$list")
  [ "${#pats[@]}" -gt 0 ] || return 0
  gh_read "$dir.log" release download "$TAG" --repo "$SRC" --dir "$dir" "${pats[@]}"
}
cols() { # → TEXT_COL / BIN_COL from the decision files
  local tu ts bu bs
  tu="$(count_action "$R/upload-text.txt" upload)"; ts="$(count_action "$R/upload-text.txt" skip)"
  TEXT_COL="$tu up/$ts skip"
  BIN_COL="-"
  [ "$WANT_BIN" -eq 1 ] || return 0
  bu="$(count_action "$R/upload-bin.txt" upload)"; bs="$(count_action "$R/upload-bin.txt" skip)"
  BIN_COL="$bu up/$bs skip"
}
# bytes_listed LIST — the size of every upload entry in LIST, from the
# source's asset list, so the plan says how much a run moves.
bytes_listed() {
  awk -F'\t' 'NR == FNR { if ($2 == "upload") up[$1] = 1; next } ($1 in up) { b += $2 } END { print b + 0 }' "$1" "$R/assets.tsv"
}

# Table rows: tag | kind | tag-action | release-action | text | tarballs | verdict
: >"$TMP/table.txt"
N_REFUSED=0; N_CREATED=0; N_SKIPPED=0; BYTES_TOTAL=0
# For the `latest` fallback after the loop: was the newest stable release
# refused before its own POST (the one carrying make_latest=true), and which
# stable release did this run create last (= newest, the run is oldest-first).
NEWEST_STABLE_REFUSED=0; LAST_STABLE_CREATED=""; LAST_STABLE_CREATED_ID=""
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$TMP/table.txt"; }
refuse() { # TAG REASON — the release is refused, the run goes on
  echo "::error::backfill-releases: REFUSED $1 — $2"
  # Refusing a release the mirror already has leaves `latest` where it is;
  # refusing the newest stable BEFORE it is created leaves nothing marked.
  if [ "$1" = "$NEWEST_STABLE" ] && [ "$REL_ACTION" = create ]; then NEWEST_STABLE_REFUSED=1; fi
  N_REFUSED=$((N_REFUSED + 1)); cols; row "$1" "$KIND" "$TAG_ACTION" "$REL_ACTION" "$TEXT_COL" "$BIN_COL" refused
}

# ---- per-release work -------------------------------------------------------------------
while IFS= read -r TAG; do
  R="$TMP/r-$TAG"; mkdir -p "$R/text" "$R/bin" "$R/guard-assets"
  jq --arg t "$TAG" '.[] | select(.tag_name == $t)' "$TMP/releases.json" >"$R/release.json"
  # Own assignment, not `[ "$(jq_of …)" = true ]`: inside a test the
  # substitution's exit 2 is swallowed and a malformed release.json would
  # silently read as "stable".
  PRERELEASE="$(jq_of "$R/release.json" '.prerelease')"
  KIND=stable; [ "$PRERELEASE" = true ] && KIND=prerelease
  NAME="$(jq_of "$R/release.json" '.name // .tag_name')"
  CREATED="$(jq_of "$R/release.json" '.created_at')"
  PUBLISHED="$(jq_of "$R/release.json" '.published_at // .created_at')"
  jq -r '.body // ""' "$R/release.json" >"$R/body.md"
  WANT_BIN=0; carries_binaries "$TAG" && WANT_BIN=1
  TAG_ACTION=create; REL_ACTION=create; REFUSAL=""
  : >"$R/upload-text.txt"; : >"$R/upload-bin.txt"

  # Assets, classified: a `*.tgz` is a packaged chart (a tarball, opaque to
  # the string scan, verified by digest); everything else is a text asset the
  # guard reads. The source's digest travels with each name.
  # name, size, digest — the digest LAST: it may be empty, and `read` with a
  # tab IFS collapses an empty field in the middle (the size would be read as
  # the digest), while a trailing empty field reads as "".
  jq -r '.assets[] | [.name, (.size // 0), ((.digest // "") | ltrimstr("sha256:"))] | @tsv' "$R/release.json" >"$R/assets.tsv"
  : >"$R/text.txt"; : >"$R/bin.txt"
  while IFS=$'\t' read -r aname _asize adigest; do
    case "$aname" in
      *.tgz) printf '%s\t%s\n' "$aname" "$adigest" >>"$R/bin.txt" ;;
      *)     printf '%s\t%s\n' "$aname" "$adigest" >>"$R/text.txt" ;;
    esac
  done <"$R/assets.tsv"

  # -- mirror state for this tag ----------------------------------------------------------
  jq --arg t "$TAG" '[ .[] | select(.tag_name == $t) ] | .[0] // empty' "$TMP/mirror-releases.json" >"$R/mirror-release.json"
  MREL_PRESENT=0; [ -s "$R/mirror-release.json" ] && MREL_PRESENT=1
  : >"$R/mirror-assets.tsv"
  [ "$MREL_PRESENT" -eq 0 ] || jq -r '.assets[] | [.name, ((.digest // "") | ltrimstr("sha256:"))] | @tsv' "$R/mirror-release.json" >"$R/mirror-assets.tsv"
  jq --arg r "refs/tags/$TAG" '[ .[] | select(.ref == $r) ] | .[0] // empty' "$TMP/mirror-tags.json" >"$R/mirror-tag.json"
  MTAG_PRESENT=0; [ -s "$R/mirror-tag.json" ] && MTAG_PRESENT=1
  if [ "$MTAG_PRESENT" -eq 1 ]; then
    # The tag exists: it must point at a commit the mirror has. Dereference an
    # annotated tag first; a dangling tag is refused, never repointed.
    OBJ_SHA="$(jq_of "$R/mirror-tag.json" '.object.sha')"; OBJ_TYPE="$(jq_of "$R/mirror-tag.json" '.object.type')"
    if [ "$OBJ_TYPE" = tag ]; then
      gh_read "$R/mirror-tagobj.json" api "repos/$MIRROR/git/tags/$OBJ_SHA"
      OBJ_SHA="$(jq_of "$R/mirror-tagobj.json" '.object.sha')"; OBJ_TYPE="$(jq_of "$R/mirror-tagobj.json" '.object.type')"
    fi
    if [ "$OBJ_TYPE" != commit ] || ! gh_read_maybe "$R/mirror-tagcommit.json" api "repos/$MIRROR/git/commits/$OBJ_SHA"; then
      REFUSAL="tag '$TAG' exists on the mirror but points at $OBJ_TYPE $OBJ_SHA, which the mirror does not have — a dangling tag is not repointed"
    fi
    TAG_ACTION=present
  fi
  [ "$MREL_PRESENT" -eq 0 ] || REL_ACTION=present

  # -- assets: skip / upload / compare / refuse, per asset --------------------------------------
  # An asset already on the mirror is skipped when its SHA256 equals the
  # source's, refused when it differs (a published asset is never replaced),
  # uploaded when absent. The mirror's digest comes from the API; a mirror
  # asset without one cannot be compared, and "cannot compare" is not "equal".
  # A tarball whose SOURCE digest is missing cannot be verified at all, so it
  # is refused: an unverified chart is not what a customer installs.
  while IFS=$'\t' read -r aname adigest; do decide "$R/upload-text.txt" "$aname" "$adigest"; done <"$R/text.txt"
  if [ "$WANT_BIN" -eq 1 ]; then
    while IFS=$'\t' read -r aname adigest; do
      if [ -z "$adigest" ]; then
        [ -n "$REFUSAL" ] || REFUSAL="tarball '$aname' has no digest on the source release — it cannot be verified, so it is not carried"   # mutation-anchor: tarball-digest-required
        continue
      fi
      decide "$R/upload-bin.txt" "$aname" "$adigest"
    done <"$R/bin.txt"
  fi
  if [ -n "$REFUSAL" ]; then refuse "$TAG" "$REFUSAL"; continue; fi
  N_TODO="$(cat "$R"/upload-*.txt | awk -F'\t' '$2 == "upload" || $2 == "compare" { n++ } END { print n + 0 }')"
  if [ "$TAG_ACTION" = present ] && [ "$REL_ACTION" = present ] && [ "$N_TODO" -eq 0 ]; then
    note "$TAG: already on the mirror, every asset matches — nothing to do"
    N_SKIPPED=$((N_SKIPPED + 1)); cols; row "$TAG" "$KIND" present present "$TEXT_COL" "$BIN_COL" skipped; continue
  fi

  # -- downloads ------------------------------------------------------------------------------
  # Text assets to upload or compare come down in both modes (the guard reads
  # them). Tarballs come down under --apply only: they are opaque to the scan;
  # each is checked against the source's digest, and against the source's Helm
  # index where it lists that chart version, before anything is written.
  download_listed "$R/upload-text.txt" "$R/text"
  resolve_compares "$R/upload-text.txt" "$R/text"
  if [ -n "$REFUSAL" ]; then refuse "$TAG" "$REFUSAL"; continue; fi
  N_INDEXED=0
  if [ "$APPLY" -eq 1 ] && [ "$WANT_BIN" -eq 1 ]; then
    download_listed "$R/upload-bin.txt" "$R/bin"
    while IFS=$'\t' read -r aname action expected; do
      [ "$action" = upload ] || continue
      [ -f "$R/bin/$aname" ] || die2 "$TAG: tarball '$aname' did not download from '$SRC'"
      got="$(sha256_of "$R/bin/$aname")"
      [ "$got" = "$expected" ] || { REFUSAL="tarball '$aname' hashes to $got but the source release's digest is $expected — not uploaded"; break; }   # mutation-anchor: sha-check
      if [[ "$aname" =~ $CHART_FILE_RE ]]; then
        IDX_DIGEST="$(src_index_digest "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
        if [ -n "$IDX_DIGEST" ]; then
          [ "$got" = "$IDX_DIGEST" ] || { REFUSAL="tarball '$aname' hashes to $got but the source's Helm index lists ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} as $IDX_DIGEST — not uploaded"; break; }   # mutation-anchor: index-cross-check
          N_INDEXED=$((N_INDEXED + 1))
        fi
      fi
    done <"$R/upload-bin.txt"
    if [ -n "$REFUSAL" ]; then refuse "$TAG" "$REFUSAL"; continue; fi
  fi

  # -- notes --------------------------------------------------------------------------------
  if [ "$REL_ACTION" = create ]; then
    if [ "$NOTES_MODE" = fixed ]; then
      {
        echo "tracebloc client $TAG."
        echo
        echo "Install with the one-liner in the README; the assets attached here are the"
        echo "installer, the packaged Helm charts and the cosign-signed installer manifest."
        echo "Verification recipe: docs/SUPPLY_CHAIN.md."
      } >"$R/notes.md"
    else
      cp "$R/body.md" "$R/notes.md"
    fi
    {
      echo
      echo "---"
      echo "Backfilled release marker: originally published $PUBLISHED. The tag \`$TAG\` on this repository points at the default branch, not at the sources this release was built from."
      if [ "$WANT_BIN" -eq 0 ]; then
        echo "Chart tarballs are carried only for the newest $BINARY_KEEP releases; install this version from the Helm repository index instead."
      fi
    } >>"$R/notes.md"
  fi

  # -- tag message ----------------------------------------------------------------------------
  # The original tag's date and message, when it is annotated; the release's
  # created_at otherwise. Read from the source, never invented. Composed here,
  # before the guard, because the original message is source text that lands on
  # the public mirror as the tag annotation — it is scanned like the notes.
  if [ "$TAG_ACTION" = create ]; then
    gh_read "$R/src-ref.json" api "repos/$SRC/git/ref/tags/$TAG"
    SRC_OBJ_TYPE="$(jq_of "$R/src-ref.json" '.object.type')"; SRC_OBJ_SHA="$(jq_of "$R/src-ref.json" '.object.sha')"
    TAG_DATE="$CREATED"; ORIG_MSG=""
    if [ "$SRC_OBJ_TYPE" = tag ]; then
      gh_read "$R/src-tagobj.json" api "repos/$SRC/git/tags/$SRC_OBJ_SHA"
      TAG_DATE="$(jq_of "$R/src-tagobj.json" '.tagger.date // empty')"; [ -n "$TAG_DATE" ] || TAG_DATE="$CREATED"
      ORIG_MSG="$(jq_of "$R/src-tagobj.json" '.message // ""')"
    fi
    {
      echo "Release $TAG"
      echo
      echo "Mirror release marker for $TAG: this tag points at the mirror's default-branch head, not at the sources the release was built from. Original tag date: $TAG_DATE."
      if [ -n "$ORIG_MSG" ]; then echo; echo "--- original tag message ---"; printf '%s\n' "$ORIG_MSG"; fi
    } >"$R/tag-message.txt"
  fi

  # -- the guard: text assets, notes and the tag message, before any write --------------------
  while IFS= read -r f; do cp "$R/text/$f" "$R/guard-assets/$f"; done < <(awk -F'\t' '$2 == "upload" { print $1 }' "$R/upload-text.txt")
  [ "$REL_ACTION" != create ] || cp "$R/notes.md" "$R/guard-assets/RELEASE_NOTES.md"
  [ "$TAG_ACTION" != create ] || cp "$R/tag-message.txt" "$R/guard-assets/TAG_MESSAGE.txt"   # mutation-anchor: tag-message-guarded
  if [ -n "$(ls -A "$R/guard-assets")" ]; then
    rc=0; run_guard "$R/guard-assets" "$R/guard-out" || rc=$?
    case "$rc" in
      0) ;;
      1) REFUSAL="the guard refused the notes, the tag message or a text asset: $(guard_refusal_text "$R/guard-out.log")" ;;   # mutation-anchor: guard-refusal
      *) cat "$R/guard-out.log"; die2 "$TAG: the guard could not tell (exit $rc)" ;;
    esac
    if [ -n "$REFUSAL" ]; then grep -E 'REFUSED|^    ' "$R/guard-out.log" | sed 's/^/    /'; refuse "$TAG" "$REFUSAL"; continue; fi
  fi

  cols
  if [ "$WANT_BIN" -eq 1 ]; then BIN_PLAN="$BIN_COL"; else BIN_PLAN="none (older than the newest $BINARY_KEEP)"; fi
  BYTES="$(( $(bytes_listed "$R/upload-text.txt") + $( [ "$WANT_BIN" -eq 1 ] && bytes_listed "$R/upload-bin.txt" || echo 0) ))"
  BYTES_TOTAL=$((BYTES_TOTAL + BYTES))
  PLAN="tag: $TAG_ACTION | release: $REL_ACTION | text: $TEXT_COL | tarballs: $BIN_PLAN | $BYTES bytes"
  if [ "$APPLY" -eq 0 ]; then
    note "$TAG [$KIND] would: $PLAN"
    N_CREATED=$((N_CREATED + 1)); row "$TAG" "$KIND" "$TAG_ACTION" "$REL_ACTION" "$TEXT_COL" "$BIN_COL" planned; continue
  fi

  # -- writes -----------------------------------------------------------------------------------
  note "$TAG [$KIND]: $PLAN ($N_INDEXED tarball(s) also matched the source's Helm index)"
  if [ "$TAG_ACTION" = create ]; then
    # The annotation text and date were composed above and passed the guard.
    gh_write "$R/tagobj.json" api -X POST "repos/$MIRROR/git/tags" \
      -f "tag=$TAG" -F "message=@$R/tag-message.txt" -f "object=$MIRROR_HEAD" -f type=commit \
      -f "tagger[name]=${PUBLISH_MIRROR_GIT_NAME:-github-actions[bot]}" \
      -f "tagger[email]=${PUBLISH_MIRROR_GIT_EMAIL:-github-actions[bot]@users.noreply.github.com}" \
      -f "tagger[date]=$TAG_DATE"
    TAGOBJ_SHA="$(jq_of "$R/tagobj.json" '.sha')"
    [[ "$TAGOBJ_SHA" =~ ^[0-9a-f]{40}$ ]] || die2 "$TAG: the created tag object has no sha"
    gh_write "$R/ref.json" api -X POST "repos/$MIRROR/git/refs" -f "ref=refs/tags/$TAG" -f "sha=$TAGOBJ_SHA"
  fi
  if [ "$REL_ACTION" = create ]; then
    LATEST=false; [ "$TAG" = "$NEWEST_STABLE" ] && LATEST=true
    PRE=false; [ "$KIND" = prerelease ] && PRE=true
    gh_write "$R/created.json" api -X POST "repos/$MIRROR/releases" \
      -f "tag_name=$TAG" -f "name=$NAME" -F "body=@$R/notes.md" -F "prerelease=$PRE" -F draft=false -f "make_latest=$LATEST"
  fi
  UPLOADS=()
  while IFS= read -r f; do UPLOADS+=("$f"); done < <(
    awk -F'\t' -v d="$R/text" '$2 == "upload" { print d "/" $1 }' "$R/upload-text.txt"
    awk -F'\t' -v d="$R/bin"  '$2 == "upload" { print d "/" $1 }' "$R/upload-bin.txt"
  )
  if [ "${#UPLOADS[@]}" -gt 0 ]; then
    gh_write "$R/upload.log" release upload "$TAG" "${UPLOADS[@]}" --repo "$MIRROR"
  fi
  if [ "$KIND" = stable ] && [ "$REL_ACTION" = create ]; then
    LAST_STABLE_CREATED="$TAG"; LAST_STABLE_CREATED_ID="$(jq_of "$R/created.json" '.id')"
    [[ "$LAST_STABLE_CREATED_ID" =~ ^[0-9]+$ ]] || die2 "$TAG: the created release has no numeric id"
  fi
  N_CREATED=$((N_CREATED + 1))
  row "$TAG" "$KIND" "$TAG_ACTION" "$REL_ACTION" "$TEXT_COL" "$BIN_COL" "done"
done <"$TMP/tags-run.txt"

# ---- latest, when the newest stable release was refused -----------------------------
# make_latest=true travels on the newest stable release's own POST; every older
# release is created with make_latest=false. Refused before that POST, the newest
# stable leaves the mirror's releases/latest answering 404 until a human re-runs
# --only-tag for it. Until then the newest stable release this run DID write is
# marked latest — that re-run's POST moves `latest` forward again.
if [ "$APPLY" -eq 1 ] && [ "$NEWEST_STABLE_REFUSED" -eq 1 ]; then
  if [ -n "$LAST_STABLE_CREATED" ]; then
    note "latest: $NEWEST_STABLE was refused — marking $LAST_STABLE_CREATED, the newest stable release written in this run, as latest until $NEWEST_STABLE is re-run"
    # -f, not -F: make_latest is a STRING enum ("true"/"false"/"legacy") in the
    # releases API; a typed boolean is a 422, which here would be a die2 in the
    # very case this fallback exists for. Same reason the create path uses -f.
    gh_write "$TMP/latest.json" api -X PATCH "repos/$MIRROR/releases/$LAST_STABLE_CREATED_ID" -f make_latest=true
  else
    echo "::warning::backfill-releases: $NEWEST_STABLE was refused and this run wrote no stable release — nothing is newly marked latest; re-run --only-tag $NEWEST_STABLE once the refusal is fixed"
  fi
fi

# ---- the Helm index the mirror serves --------------------------------------------------
# One implementation, publish-mirror.sh `index`, shared with the workflow's
# every-stable-publish step: it reads the MIRROR's releases fresh (so under
# --apply the index covers the releases written above), downloads and verifies
# each chart tarball, places every chart version once under the OLDEST stable
# release carrying it, builds the index with helm at the mirror's release-asset
# URLs, stamps `created` from the SOURCE's release list, compares against the
# mirror's current gh-pages apart from `generated:`, keeps the index.yaml and
# *.tgz files already on that branch (anything else is dropped and the drop
# counts as a change), and runs the guard over the staged branch. It pushes nothing;
# the push below is this script's, through the same `tree` step the workflow
# uses. The source's Pages index is never read for this: its URLs name the
# source's Pages site (it IS read above, as the digest manifest for uploads).
PAGES_RESULT=""
if [ "$PAGES" -eq 1 ]; then
  P="$TMP/pages"; mkdir -p "$P"
  IDX_ARGS=(index --repo "$MIRROR" --source-releases "$TMP/src-pages.json" --out "$P/index" --remote "$PAGES_REMOTE" --forbidden "$FORBIDDEN_LIST" --helm "$HELM" --output "$P/result.txt")
  [ -z "${BACKFILL_EXTRA_FORBIDDEN:-}" ] || IDX_ARGS+=(--extra-forbidden "$BACKFILL_EXTRA_FORBIDDEN")
  [ "$STRICT" -eq 0 ] || IDX_ARGS+=(--strict)
  # A dry run before the first release has nothing to index yet — that is a
  # note, not a refusal; under --apply an empty index is refused.
  [ "$APPLY" -eq 1 ] || IDX_ARGS+=(--allow-empty)
  # A dry run wrote nothing since read_mirror_releases paginated the mirror's
  # list above, so `index` reuses that read instead of paginating it again;
  # under --apply the releases written above are not in it, so `index` reads
  # the list fresh (review on #1060).
  [ "$APPLY" -eq 1 ] || IDX_ARGS+=(--mirror-releases "$TMP/mirror-pages.json")   # mutation-anchor: pages-mirror-list-reuse
  rc=0
  bash "$PUBLISH_MIRROR" "${IDX_ARGS[@]}" >"$P/index.out" 2>&1 || rc=$?   # mutation-anchor: pages-index-call
  cat "$P/index.out"
  case "$rc" in
    0) ;;
    1) # `|| true`, as for TREE_RESULT below: under pipefail a grep with no match
       # exits 1 and the assignment would abort the script at exit 1 BEFORE the
       # ::error:: line, the refused count and the report. Today `index` exits 1
       # only through its two `index: `-prefixed refusals, so the grep always
       # matches; this guards the next unprefixed exit 1 (Bugbot on #1060).
       IDX_REASON="$(grep -E '^::error::publish-mirror: REFUSED — index: ' "$P/index.out" | tail -1 | sed 's/^::error::publish-mirror: REFUSED — index: //' || true)"   # mutation-anchor: pages-refuse-reason
       echo "::error::backfill-releases: REFUSED — --pages: ${IDX_REASON:-the index rebuild was refused (see above)}"
       N_REFUSED=$((N_REFUSED + 1))
       case "$IDX_REASON" in
         "the guard refused"*) PAGES_RESULT="refused by the guard" ;;
         *) PAGES_RESULT="refused (no chart on the mirror)" ;;
       esac ;;
    *) die2 "--pages: the index rebuild could not tell (exit $rc, see above)" ;;
  esac
  if [ -z "$PAGES_RESULT" ]; then
    idx_result() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$P/result.txt"; }
    N_CHARTS="$(idx_result charts)"; N_PAGES_STABLE="$(idx_result stable_releases)"; IDX_CHANGED="$(idx_result changed)"; IDX_BASE="$(idx_result download_base)"; IDX_STAGE="$(idx_result stage)"
    [[ "$N_CHARTS" =~ ^[0-9]+$ ]] && [ -n "$IDX_STAGE" ] || die2 "--pages: the index rebuild exited 0 but reported no charts=/stage= result"
    PAGES_PRESENT=absent; [ "$(idx_result pages_existed)" != true ] || PAGES_PRESENT=present
    CHANGE_TEXT=unchanged; [ "$IDX_CHANGED" != true ] || CHANGE_TEXT=changed
    if [ "$N_CHARTS" -eq 0 ]; then
      note "--pages: the mirror carries no chart tarball on any stable release yet — nothing to index in this dry-run; run --apply first"
      PAGES_RESULT="nothing to index yet"
    elif [ "$APPLY" -eq 0 ]; then
      note "--pages would: index $N_CHARTS chart(s) from $N_PAGES_STABLE stable release(s) at $IDX_BASE/<tag>/; index.yaml $CHANGE_TEXT against the mirror's gh-pages ($PAGES_PRESENT); not pushed"
      PAGES_RESULT="planned ($N_CHARTS chart(s), index $CHANGE_TEXT)"
    else
      rc=0
      bash "$PUBLISH_MIRROR" tree --stage "$IDX_STAGE" --repo "$MIRROR" --branch gh-pages --message "Chart index: backfill of $N_CHARTS chart version(s)" --remote "$PAGES_REMOTE" >"$P/tree.out" 2>&1 || rc=$?   # mutation-anchor: pages-publisher
      cat "$P/tree.out"
      [ "$rc" -eq 0 ] || die2 "--pages: the publisher did not push gh-pages (exit $rc, see above)"
      # `|| true`: under pipefail a grep with no match exits 1 and the assignment
      # would abort the script at exit 1 BEFORE the die2 below can say why. A
      # publisher that exits 0 without its contract line is the could-not-tell
      # case that die2 exists for (review on #1057).
      TREE_RESULT="$(grep -E '^(pushed|unchanged) [0-9a-f]{40}$' "$P/tree.out" || true)"   # mutation-anchor: pages-result-grep
      TREE_RESULT="$(printf '%s\n' "$TREE_RESULT" | tail -1)"
      [ -n "$TREE_RESULT" ] || die2 "--pages: the publisher exited 0 but reported no 'pushed <sha>' / 'unchanged <sha>' line"
      PAGES_RESULT="$TREE_RESULT ($N_CHARTS chart(s), index $CHANGE_TEXT)"
      note "--pages: $PAGES_RESULT"
    fi
  fi
fi

# ---- report -------------------------------------------------------------------------
echo
echo "backfill-releases: $MODE report — $SRC → $MIRROR"
{
  printf 'TAG\tKIND\tTAG-ON-MIRROR\tRELEASE\tTEXT ASSETS\tTARBALLS\tVERDICT\n'
  cat "$TMP/table.txt"
} | column -t -s "$(printf '\t')" 2>/dev/null || cat "$TMP/table.txt"
echo
VERB=written; [ "$APPLY" -eq 1 ] || VERB=planned
echo "backfill-releases: $N_RUN release(s) in this run — $N_CREATED $VERB, $N_SKIPPED already complete, $N_REFUSED refused; $BYTES_TOTAL bytes of assets $VERB"
[ -z "$PAGES_RESULT" ] || echo "backfill-releases: Helm index (gh-pages): $PAGES_RESULT"
if [ "$N_REFUSED" -gt 0 ]; then
  echo "::error::backfill-releases: REFUSED — $N_REFUSED item(s) were refused (see above); the rest went ahead"
  exit 1
fi
exit 0
