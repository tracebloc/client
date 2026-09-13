#!/usr/bin/env bats
# mirror-publish-workflow.bats — the decisions .github/workflows/mirror-publish.yaml
# takes ITSELF, in step bodies no script owns: what to publish (plan), that the
# release tag is fetched as data and only at the expected commit (src), that a
# prerelease keeps the mirror's default branch (keep), and that a publisher
# refusal reaches the step log (target).
#
# THE CODE UNDER TEST IS THE WORKFLOW. Each step's `run:` body is read out of the
# YAML and executed under bash with the step's env set and `gh` shimmed — the
# same text Actions runs, not a copy of it (workspace rule 9). The gh shim
# answers `release view` and `api` from env; the tag fetch runs against a real
# bare repository over file://.
#
# WHAT IS PINNED, and the review finding each answers:
#   * a prerelease sets publish_tree=false and says why; a stable release sets
#     it true — and every step that pushes a tree is gated on that output, the
#     release step is not (Bugbot: "prerelease overwrites public default branch")
#   * a stable release that is NOT the newest one (releases/latest of the source
#     repo) also sets publish_tree=false, and an unreadable releases/latest is
#     refused — a rebuild or dispatch of an older tag must not roll the mirror's
#     default branch back (Bugbot: "older stable tags replace mirror docs")
#   * no actions/checkout step takes a `ref:` — the tooling runs from this
#     workflow's own commit; the release tag is fetched into a detached worktree
#     and refused unless it resolves to the commit the plan step expects
#     (CodeQL: "checkout of untrusted code in a privileged context")
#   * a refusal from publish-mirror.sh is a `::error::` line in the step's
#     stdout, so no step captures the publisher through `$(...)` (Bugbot:
#     "captured output hides publish refusals")
#   * isPrerelease must be an explicit boolean: a missing or malformed value is
#     refused, never read as "stable" (Bugbot: "prerelease tree-push guard
#     fails open")
#   * a guard refusal still lands in the step summary and the step exits with
#     the guard's status — under the `-e` Actions runs every body with (Bugbot:
#     "guard refusal skips step summary")
#   * the mirror's chart index is DERIVED from the mirror's own releases
#     (`publish-mirror.sh index`, after the release step) and never read from a
#     Pages branch: the only `git fetch` is the release tag's, no step reads an
#     index.yaml by path, and the gh-pages push is gated on the index step
#     reporting `changed` — so a backfilled index whose URLs name the mirror is
#     re-derived, not overwritten with the source's Pages URLs (review on the
#     backfill: "the next stable publish replaces the backfilled index")
#   * the index step passes --allow-empty on a DRY RUN and only there: a dry run
#     creates no release, so a mirror with no stable chart yet has nothing to
#     index — a note, as backfill's dry run — while a real publish, which has
#     just created a release, still refuses an empty index (Bugbot: "dry-run
#     index refuses empty mirrors")
#
# FAILS CLOSED: an unreadable workflow, a missing step id, or PyYAML absent is a
# named refusal, never "nothing to check". The shape check is one function run
# over the real workflow AND over mutated copies, so a mutation that reddens
# here reddens the check that gates the tree.

WF=""
REPO_ROOT=""
SHIM=""
WORK=""

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows/mirror-publish.yaml"
  python3 -c 'import yaml' 2>/dev/null || { echo "[ERROR] PyYAML required (pip install pyyaml)"; return 1; }
  SHIM="$BATS_TEST_TMPDIR/shim"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$SHIM" "$WORK" "$BATS_TEST_TMPDIR/runner-temp"
  # gh shim: `release view` prints GH_RELEASE_JSON (or fails with GH_RELEASE_RC);
  # `api .../releases/latest` prints GH_LATEST_TAG (or fails with GH_LATEST_RC);
  # any other `api ... --jq .sha` prints GH_API_SHA (or fails with GH_API_RC).
  # Every call is logged so a test can assert WHICH question the step asked.
  cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case "${1:-} ${2:-}" in
  "release view")
    [ "${GH_RELEASE_RC:-0}" -eq 0 ] || { echo "release not found" >&2; exit "$GH_RELEASE_RC"; }
    printf '%s\n' "${GH_RELEASE_JSON:?}" ;;
  "api "*"/releases/latest")
    [ "${GH_LATEST_RC:-0}" -eq 0 ] || { echo "HTTP 404: Not Found" >&2; exit "$GH_LATEST_RC"; }
    printf '%s\n' "${GH_LATEST_TAG:?}" ;;
  "api "*)
    [ "${GH_API_RC:-0}" -eq 0 ] || { echo "HTTP 409: Git Repository is empty" >&2; exit "$GH_API_RC"; }
    printf '%s\n' "${GH_API_SHA:?}" ;;
esac
exit 0
EOF
  chmod +x "$SHIM/gh"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : >"$GITHUB_OUTPUT"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  export GITHUB_REPOSITORY="example/source"
  export GITHUB_WORKSPACE="$REPO_ROOT"
  # The plan step's job-level env, every field set (the body runs under set -u).
  export EVENT_NAME=workflow_run INPUT_TAG="" INPUT_DRY_RUN="" INPUT_MIRROR="" INPUT_STRICT=""
  export RUN_HEAD_BRANCH="" RUN_HEAD_SHA="" VAR_MIRROR="" VAR_STRICT=""
  export TAG="" EXPECT_SHA="" BRANCH="" REPO="" SOURCE_RELEASES="" DRY_RUN=""
}

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222

# step_run <workflow> <step id> — print that step's `run:` body; refuse when absent.
step_run() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except (OSError, yaml.YAMLError) as e:
    sys.exit("FAIL: cannot read or parse workflow %s: %s" % (path, e))
steps = ((doc.get("jobs") or {}).get("publish") or {}).get("steps") or []
for s in steps:
    if isinstance(s, dict) and s.get("id") == want:
        if "run" not in s:
            sys.exit("FAIL: step %r has no run: body" % want)
        sys.stdout.write(s["run"])
        sys.exit(0)
sys.exit("FAIL: no step with id %r in %s" % (want, path))
PY
}

# run_step <step id> [cwd] — execute the step body as Actions would: its own
# bash, the exported env, the gh shim first on PATH. RUN_WF names the workflow
# to read the body from (default: the real one; a mutation test points it at a
# mutated copy so the same step body runs with one decision removed).
run_step() {
  local body="$BATS_TEST_TMPDIR/step-$1.sh"
  step_run "${RUN_WF:-$WF}" "$1" >"$body" || { cat "$body"; return 1; }
  local dir="${2:-$WORK}"
  # `bash -e`: what Actions runs a `run:` body with. A body that relies on
  # surviving a failing command (the guard steps' tee pipeline) is tested under
  # the same errexit it gets in CI, or the test proves nothing about the step.
  run env PATH="$SHIM:$PATH" bash -c "cd '$dir' && bash -e '$body'"
}

out() { grep -E "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }

release_json() { # <tag> <isPrerelease>
  printf '{"tagName":"%s","isDraft":false,"isPrerelease":%s}' "$1" "$2"
}

# ── plan ──────────────────────────────────────────────────────────────────────

@test "plan: the newest stable release from workflow_run publishes tree and release, pinned to head_sha" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON GH_LATEST_TAG=v1.2.3
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  run_step plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out tag)" = "v1.2.3" ] || return 1
  [ "$(out dry_run)" = "false" ] || return 1
  [ "$(out prerelease)" = "false" ] || return 1
  [ "$(out publish_tree)" = "true" ] || return 1
  [ "$(out expect_sha)" = "$SHA_A" ] || return 1
  grep -q '^release view v1.2.3 --repo example/source --json tagName,isDraft,isPrerelease$' "$GH_LOG" || return 1
  # The newest-stable answer is GitHub's, asked of the SOURCE repository.
  grep -q '^api repos/example/source/releases/latest --jq .tag_name$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  [[ "$output" != *"::notice::"* ]] || return 1
}

@test "plan: a prerelease mirrors only its release — publish_tree=false, and the log says why" {
  export RUN_HEAD_BRANCH=v1.2.3-rc.1 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON
  GH_RELEASE_JSON="$(release_json v1.2.3-rc.1 true)"
  run_step plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out prerelease)" = "true" ] || return 1
  [ "$(out publish_tree)" = "false" ] || return 1
  [ "$(out expect_sha)" = "$SHA_A" ] || return 1
  [[ "$output" == *"::notice::'v1.2.3-rc.1' is a prerelease: only its GitHub release is mirrored (marked prerelease)."*"default branch and chart index are not pushed"* ]] || { echo "$output"; return 1; }
  # A prerelease is never the newest stable release; the question is not asked.
  ! grep -q 'releases/latest' "$GH_LOG" || return 1
}

@test "plan: a release whose isPrerelease is not a boolean is refused — the tree push is armed only by an explicit false" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON GH_LATEST_TAG=v1.2.3
  GH_RELEASE_JSON='{"tagName":"v1.2.3","isDraft":false}'
  run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::release 'v1.2.3' reports isPrerelease 'null' — not a boolean, refusing"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "plan: a stable release that is not the newest one mirrors only its release — publish_tree=false, not marked prerelease" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON GH_LATEST_TAG=v1.3.0
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  run_step plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out tag)" = "v1.2.3" ] || return 1
  [ "$(out prerelease)" = "false" ] || return 1
  [ "$(out publish_tree)" = "false" ] || return 1
  [ "$(out expect_sha)" = "$SHA_A" ] || return 1
  [[ "$output" == *"::notice::'v1.2.3' is not the newest stable release (v1.3.0 is): only its GitHub release is mirrored."*"they keep the newest stable release"* ]] || { echo "$output"; return 1; }
}

@test "plan: an unreadable releases/latest is refused — 'cannot tell' does not replace the default branch" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON GH_LATEST_TAG="" GH_LATEST_RC=1
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::cannot read the newest stable release of example/source (releases/latest) — refusing"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "plan mutation: with the newest-stable comparison removed, an older tag publishes the tree — the test above catches it" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'plan'][0]; s['run'] = s['run'].replace('if [ \"\$LATEST\" != \"\$TAG\" ]; then', 'if false; then')")" || return 1
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON GH_LATEST_TAG=v1.3.0
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  RUN_WF="$m" run_step plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The mutated body lets the older tag through: this is the outcome the real
  # test refuses, so the assertion there is live, not vacuous.
  [ "$(out publish_tree)" = "true" ] || { echo "$output"; return 1; }
}

@test "plan: a workflow_run whose head is a branch, not a tag, is refused before anything is read" {
  export RUN_HEAD_BRANCH=develop RUN_HEAD_SHA="$SHA_A"
  run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::'develop' is not a release tag"* ]] || return 1
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
  [ ! -s "$GH_LOG" ] || return 1
}

@test "plan: a release whose tag_name is not the run's tag is refused" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA="$SHA_A" GH_RELEASE_JSON
  GH_RELEASE_JSON="$(release_json v9.9.9 false)"
  run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::release 'v1.2.3' reports tag_name 'v9.9.9' — the tag and the release disagree, refusing."* ]] || return 1
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "plan: a workflow_run without a full head_sha to pin the tag to is refused" {
  export RUN_HEAD_BRANCH=v1.2.3 RUN_HEAD_SHA=abc123 GH_RELEASE_JSON
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::cannot determine the commit release 'v1.2.3' was cut from (got 'abc123')"* ]] || return 1
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "plan: a dispatch takes the expected commit from the API and is a dry run unless told 'false'" {
  export EVENT_NAME=workflow_dispatch INPUT_TAG=v1.2.3 INPUT_DRY_RUN=true GH_RELEASE_JSON GH_API_SHA="$SHA_B" GH_LATEST_TAG=v1.2.3
  GH_RELEASE_JSON="$(release_json v1.2.3 false)"
  run_step plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out dry_run)" = "true" ] || return 1
  [ "$(out publish_tree)" = "true" ] || return 1
  [ "$(out expect_sha)" = "$SHA_B" ] || return 1
  grep -q '^api repos/example/source/commits/v1.2.3 --jq .sha$' "$GH_LOG" || return 1
  # The API not answering is "cannot tell", never an unpinned fetch.
  : >"$GITHUB_OUTPUT"
  GH_API_RC=1 run_step plan
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::cannot determine the commit release 'v1.2.3' was cut from (got '<empty>')"* ]] || return 1
}

# ── src: the release tag is data, fetched only at the expected commit ─────────

make_origin() { # a bare origin with one commit tagged v1.2.3 (annotated); WORK becomes its clone; prints the commit
  local seed="$BATS_TEST_TMPDIR/seed" bare="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare "$bare"
  # The bare HEAD is pinned to `main` explicitly: with init.defaultBranch unset
  # (a fresh runner) it would point at a `master` that never receives a push,
  # the clone would have an unborn HEAD, and `rev-parse HEAD` would print the
  # literal word HEAD as the expected sha (measured on the first CI run).
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git init -q "$seed"
  printf 'readme\n' >"$seed/README.md"
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid add README.md
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m one
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid tag -a v1.2.3 -m v1.2.3
  git -C "$seed" push -q "file://$bare" HEAD:refs/heads/main refs/tags/v1.2.3
  rm -rf "$WORK"
  git clone -q "file://$bare" "$WORK" 2>/dev/null
  git -C "$seed" rev-parse --verify HEAD
}

@test "src: the tag is fetched into a detached worktree outside the checkout, only at the expected commit" {
  local sha
  sha="$(make_origin)"
  export TAG=v1.2.3 EXPECT_SHA="$sha"
  run_step src
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out dir)" = "$RUNNER_TEMP/release-src" ] || return 1
  [ "$(git -C "$RUNNER_TEMP/release-src" rev-parse HEAD)" = "$sha" ] || return 1
  [ -f "$RUNNER_TEMP/release-src/README.md" ] || return 1
  [[ "$output" == *"release source: v1.2.3 at $sha (data only)"* ]] || return 1
}

@test "src: a tag that does not resolve to the expected commit is refused and nothing is checked out" {
  make_origin >/dev/null
  export TAG=v1.2.3 EXPECT_SHA="$SHA_B"
  run_step src
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::tag 'v1.2.3' resolves to "*" but the release was cut at $SHA_B — the tag has moved or the run is not this release's; refusing."* ]] || return 1
  [ ! -e "$RUNNER_TEMP/release-src" ] || return 1
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "src: a tag origin does not have is refused" {
  make_origin >/dev/null
  export TAG=v9.9.9 EXPECT_SHA="$SHA_A"
  run_step src
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::could not fetch tag 'v9.9.9' from origin"* ]] || return 1
  [ ! -e "$RUNNER_TEMP/release-src" ] || return 1
}

# ── target / keep: refusals annotate, results go to GITHUB_OUTPUT ─────────────

@test "target: an unset MIRROR_REPO is refused with the ::error:: line IN THE STEP LOG, nothing captured" {
  export VAR_MIRROR="" INPUT_MIRROR=""
  run_step target "$REPO_ROOT"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::publish-mirror: REFUSED — no mirror repository is configured (MIRROR_REPO is unset)"* ]] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "target: a configured mirror lands in GITHUB_OUTPUT as repo= and name=" {
  export VAR_MIRROR=source-public INPUT_MIRROR=""
  run_step target "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out repo)" = "example/source-public" ] || return 1
  [ "$(out name)" = "source-public" ] || return 1
}

@test "keep: a release-only publish is pinned to the mirror's default-branch head; an empty mirror is refused" {
  export REPO=example/source-public BRANCH=main TAG=v1.2.3-rc.1 GH_API_SHA="$SHA_B"
  run_step keep
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out sha)" = "$SHA_B" ] || return 1
  grep -q '^api repos/example/source-public/commits/main --jq .sha$' "$GH_LOG" || return 1
  [[ "$output" == *"release-only v1.2.3-rc.1: default branch 'main' and gh-pages left untouched"* ]] || { echo "$output"; return 1; }
  : >"$GITHUB_OUTPUT"
  GH_API_RC=1 run_step keep
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::'v1.2.3-rc.1' does not replace the mirror's default branch (a prerelease, or not the newest stable release) and the mirror has no commit on 'main' to pin its release to — the first publish to an empty mirror must be the newest stable release."* ]] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

# ── guard steps: a refusal reaches the step summary, the step exits with it ────

# fake_guard <dir> — a cwd holding a scripts/publish-guard.sh that refuses
# (prints a guard line, exits 1) whatever it is asked; the guard itself has its
# own suite, this is about what the STEP does with a refusal.
fake_guard() {
  mkdir -p "$1/scripts"
  cat >"$1/scripts/publish-guard.sh" <<'EOF'
#!/usr/bin/env bash
echo "::error::publish-guard: [forbidden-strings] REFUSED — planted refusal"
exit 1
EOF
}

@test "guard-tree: a guard refusal is written to the step summary and the step exits with the guard's status" {
  fake_guard "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" TAG="" STRICT="" SRC_DIR=""
  : >"$GITHUB_STEP_SUMMARY"
  run_step guard-tree
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — planted refusal"* ]] || { echo "$output"; return 1; }
  grep -q '^## Mirror publish — tree$' "$GITHUB_STEP_SUMMARY" || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
  grep -q 'REFUSED — planted refusal' "$GITHUB_STEP_SUMMARY" || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
}

@test "guard-tree mutation: without catching the guard's status, errexit skips the summary — the test above catches it" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'guard-tree'][0]; s['run'] = s['run'].replace(' || rc=\$?', '')")" || return 1
  fake_guard "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" TAG="" STRICT="" SRC_DIR=""
  : >"$GITHUB_STEP_SUMMARY"
  RUN_WF="$m" run_step guard-tree
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  # The refusal happened, but the summary is empty: the finding, reproduced.
  [ ! -s "$GITHUB_STEP_SUMMARY" ] || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
}

# ── dates / index: the chart index derived from the mirror, its verdict in the summary ──

@test "dates: this repository's release list is read with the default token into RUNNER_TEMP; an unreadable list is exit 2 naming the repository" {
  export GH_API_SHA='[{"tag_name":"v1.2.3","published_at":"2026-01-01T00:00:00Z"}]'
  run_step dates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out file)" = "$RUNNER_TEMP/source-releases.json" ] || return 1
  [ "$(jq -r '.[0].tag_name' "$RUNNER_TEMP/source-releases.json")" = v1.2.3 ] || return 1
  grep -q '^api --paginate repos/example/source/releases$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  [[ "$output" == *"release list of example/source: 1 release(s)"* ]] || { echo "$output"; return 1; }
  : >"$GITHUB_OUTPUT"
  GH_API_RC=1 run_step dates
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::error::could not read the releases of example/source — the chart index stamps each entry with its original publish date and cannot be rebuilt without them; refusing."* ]] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

# fake_index <dir> — a cwd holding a scripts/publish-mirror.sh that answers
# `index` per FAKE_INDEX: `refuse` prints the command's refusal line and exits
# 1; otherwise it writes a one-entry index into --out, the result keys into
# --output, and exits 0. The command has its own suite
# (publish-mirror-index.bats); this is about what the STEP does with its
# verdict and its result.
fake_index() {
  mkdir -p "$1/scripts"
  cat >"$1/scripts/publish-mirror.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PM_LOG:?}"
[ "${1:-}" = index ] || { echo "fake publish-mirror: not index: $*" >&2; exit 99; }
if [ "${FAKE_INDEX:-ok}" = refuse ]; then
  echo "    [forbidden-strings] REFUSED — [strings-refuse] private needle #1 found in 1 staged line(s):"
  echo "::error::publish-mirror: REFUSED — index: the guard refused the index or the Pages branch: planted refusal"
  exit 1
fi
out=""; output=""
while [ "$#" -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; --output) output="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out/stage"
printf 'apiVersion: v1\nentries:\n  client:\n  - version: 1.2.3\n    urls:\n    - https://github.com/example/source-public/releases/download/v1.2.3/client-1.2.3.tgz\n' >"$out/index.yaml"
cp "$out/index.yaml" "$out/stage/index.yaml"
printf 'charts=1\nstable_releases=1\nchanged=true\npages_existed=false\nstage=%s/stage\nindex=%s/index.yaml\n' "$out" "$out" >>"$output"
echo "index: 1 chart version(s) from 1 stable release(s) of example/source-public; index.yaml changed against the mirror's gh-pages (absent)"
EOF
  chmod +x "$1/scripts/publish-mirror.sh"
  export PM_LOG="$BATS_TEST_TMPDIR/pm.log"; : >"$PM_LOG"
}

@test "index: the command's result lands in GITHUB_OUTPUT, the rebuilt index.yaml in the step summary; a dry run allows an empty mirror and says nothing was pushed, a real run does neither" {
  fake_index "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" REPO=example/source-public SOURCE_RELEASES="$BATS_TEST_TMPDIR/src.json" STRICT=true DRY_RUN=true
  : >"$GITHUB_STEP_SUMMARY"
  run_step index
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out changed)" = true ] || { cat "$GITHUB_OUTPUT"; return 1; }
  [ "$(out stage)" = "$RUNNER_TEMP/index/stage" ] || return 1
  grep -q -- '--repo example/source-public --source-releases .*/src.json --out .*/index --forbidden .*/.publish-forbidden --extra-forbidden .*/tenants.txt --output .* --strict --allow-empty$' "$PM_LOG" || { cat "$PM_LOG"; return 1; }
  grep -q "^## Mirror publish — chart index (derived from the mirror's releases)$" "$GITHUB_STEP_SUMMARY" || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
  grep -q 'index.yaml as rebuilt' "$GITHUB_STEP_SUMMARY" || return 1
  grep -q 'releases/download/v1.2.3/client-1.2.3.tgz' "$GITHUB_STEP_SUMMARY" || return 1
  [[ "$output" == *"dry run: the index above is what the mirror's releases yield today"*"Nothing was pushed."* ]] || { echo "$output"; return 1; }
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_STEP_SUMMARY"; rm -rf "$RUNNER_TEMP/index"
  DRY_RUN=false STRICT=false run_step index
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"dry run:"* ]] || return 1
  ! grep -q -- '--strict' <(tail -1 "$PM_LOG") || return 1
  # A real publish has just created a release: an empty index stays a refusal.
  ! grep -q -- '--allow-empty' <(tail -1 "$PM_LOG") || { cat "$PM_LOG"; return 1; }
}

@test "index mutation: with --allow-empty dropped, a dry run against a mirror with no stable chart yet would refuse — the test above catches it" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'index'][0]; s['run'] = s['run'].replace('[ \"\$DRY_RUN\" != \"true\" ] || args+=(--allow-empty)', ':')")" || return 1
  fake_index "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" REPO=example/source-public SOURCE_RELEASES="$BATS_TEST_TMPDIR/src.json" STRICT="" DRY_RUN=true
  : >"$GITHUB_STEP_SUMMARY"
  RUN_WF="$m" run_step index
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q -- '--allow-empty' <(tail -1 "$PM_LOG") || { cat "$PM_LOG"; return 1; }
}

@test "index mutation: with --allow-empty passed unconditionally, a real publish would accept an empty index — the test above catches it" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'index'][0]; s['run'] = s['run'].replace('[ \"\$DRY_RUN\" != \"true\" ] || args+=(--allow-empty)', 'args+=(--allow-empty)')")" || return 1
  fake_index "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" REPO=example/source-public SOURCE_RELEASES="$BATS_TEST_TMPDIR/src.json" STRICT="" DRY_RUN=false
  : >"$GITHUB_STEP_SUMMARY"
  RUN_WF="$m" run_step index
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q -- '--allow-empty' <(tail -1 "$PM_LOG") || { cat "$PM_LOG"; return 1; }
}

@test "index: a refusal is written to the step summary and the step exits with the command's status; nothing lands in GITHUB_OUTPUT" {
  fake_index "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" REPO=example/source-public SOURCE_RELEASES="$BATS_TEST_TMPDIR/src.json" STRICT="" DRY_RUN=false FAKE_INDEX=refuse
  : >"$GITHUB_STEP_SUMMARY"
  run_step index
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — index: the guard refused the index or the Pages branch: planted refusal"* ]] || { echo "$output"; return 1; }
  grep -q 'planted refusal' "$GITHUB_STEP_SUMMARY" || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
  ! grep -q 'index.yaml as rebuilt' "$GITHUB_STEP_SUMMARY" || return 1
  [ ! -s "$GITHUB_OUTPUT" ] || return 1
}

@test "index mutation: without catching the command's status, errexit skips the summary — the test above catches it" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'index'][0]; s['run'] = s['run'].replace(' || rc=\$?', '')")" || return 1
  fake_index "$WORK"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" REPO=example/source-public SOURCE_RELEASES="$BATS_TEST_TMPDIR/src.json" STRICT="" DRY_RUN=false FAKE_INDEX=refuse
  : >"$GITHUB_STEP_SUMMARY"
  RUN_WF="$m" run_step index
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ ! -s "$GITHUB_STEP_SUMMARY" ] || { cat "$GITHUB_STEP_SUMMARY"; return 1; }
}

# ── shape: derived from the workflow, one implementation for real and mutated ──

# shape <workflow.yaml> — OK lines / one FAIL line. Every rule is derived from
# the steps themselves (which steps check out, which steps invoke the
# publisher), never from a list of step names held here.
shape() {
  run python3 - "$1" <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

path = sys.argv[1]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except (OSError, yaml.YAMLError) as e:
    fail("cannot read or parse workflow %s: %s" % (path, e))
publish = ((doc or {}).get("jobs") or {}).get("publish")
if not isinstance(publish, dict):
    fail("no `publish` job in %s" % path)
steps = [s for s in (publish.get("steps") or []) if isinstance(s, dict)]
if not steps:
    fail("`publish` has no steps")

GATE = "steps.plan.outputs.publish_tree == 'true'"

checkouts = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
if not checkouts:
    fail("no actions/checkout step — the tooling has to come from somewhere")
for s in checkouts:
    with_ = s.get("with") or {}
    if "ref" in with_:
        fail("checkout step %r takes a ref (%r): the tooling must come from this workflow's own commit, the release tag is data" % (s.get("name"), with_["ref"]))
print("OK: %d checkout step(s), none with a ref" % len(checkouts))

tree_pushes = [s for s in steps if re.search(r"publish-mirror\.sh\s+tree\b", str(s.get("run", "")))]
if not tree_pushes:
    fail("no step invokes `publish-mirror.sh tree` — nothing to gate")
for s in tree_pushes:
    if GATE not in str(s.get("if", "")):
        fail("step %r pushes a tree without `if: ... %s` — a prerelease would replace the mirror's branch" % (s.get("name"), GATE))
print("OK: %d tree push step(s), each gated on publish_tree" % len(tree_pushes))

releases = [s for s in steps if re.search(r"args=\(release\b|publish-mirror\.sh\s+release\b", str(s.get("run", "")))]
if len(releases) != 1:
    fail("expected exactly one release step, found %d" % len(releases))
if "publish_tree" in str(releases[0].get("if", "")):
    fail("the release step is gated on publish_tree — a prerelease must still get its release")
print("OK: the release step is not gated on publish_tree")

# The ONLY `git fetch` is the release tag's, as data. A second fetch is how the
# source's gh-pages index used to reach the mirror.
fetches = [s for s in steps if re.search(r"\bgit fetch\b", str(s.get("run", "")))]
if len(fetches) != 1:
    fail("expected exactly one step running `git fetch` (the release tag, as data), found %d — a second fetch is how the source's Pages index reached the mirror" % len(fetches))
if "refs/tags/" not in str(fetches[0].get("run", "")):
    fail("the one git fetch step %r does not fetch a release tag" % fetches[0].get("name"))
if "EXPECT_SHA" not in str(fetches[0].get("run", "")):
    fail("the tag fetch step does not compare against EXPECT_SHA")
print("OK: the one git fetch is the release tag's, compared against the expected commit")

# The chart index: ONE step derives it from the mirror's releases, AFTER the
# release step (so the release just published is in it); a dry run derives it
# too (the plan); the gh-pages push stages what that step produced and is
# gated on it reporting changed=true.
indexers = [s for s in steps if re.search(r"args=\(index\b|publish-mirror\.sh\s+index\b", str(s.get("run", "")))]
if len(indexers) != 1:
    fail("expected exactly one step deriving the chart index (`publish-mirror.sh index`), found %d" % len(indexers))
index_step = indexers[0]
index_id = index_step.get("id")
if not index_id:
    fail("the index step has no id — the gh-pages push cannot be gated on its result")
if steps.index(index_step) < steps.index(releases[0]):
    fail("the index step %r runs before the release step — the release just published would be missing from the index" % index_step.get("name"))
index_if = str(index_step.get("if", ""))
if "steps.plan.outputs.publish_tree == 'true'" not in index_if or "steps.plan.outputs.dry_run == 'true'" not in index_if:
    fail("the index step %r is not gated on publish_tree for a real run and enabled for a dry run (its if: %r)" % (index_step.get("name"), index_if))
print("OK: one index step, after the release step, derived for a dry run too")

gh_pushes = [s for s in tree_pushes if re.search(r"--branch\s+gh-pages\b", str(s.get("run", "")))]
if len(gh_pushes) != 1:
    fail("expected exactly one step pushing gh-pages, found %d" % len(gh_pushes))
gh_push = gh_pushes[0]
m = re.search(r"steps\.([A-Za-z0-9_-]+)\.outputs\.changed == 'true'", str(gh_push.get("if", "")))
if not m:
    fail("step %r pushes gh-pages without `if: ... steps.<index>.outputs.changed == 'true'` — an unchanged index would be a commit, and a refused one has no result to gate on" % gh_push.get("name"))
if m.group(1) != index_id:
    fail("step %r is gated on steps.%s.outputs.changed but the index step's id is %r" % (gh_push.get("name"), m.group(1), index_id))
if steps.index(gh_push) < steps.index(index_step):
    fail("step %r pushes gh-pages before the index step derived it" % gh_push.get("name"))
if ("steps.%s.outputs.stage" % index_id) not in yaml.safe_dump(gh_push):
    fail("step %r does not stage what the index step produced (steps.%s.outputs.stage)" % (gh_push.get("name"), index_id))
print("OK: the gh-pages push stages the index step's result and is gated on it having changed")

for s in steps:
    if re.search(r"contents/index\.yaml|publish-include-pages|pages-src", str(s.get("run", ""))):
        fail("step %r reads a Pages index by path — the mirror's index is derived from the mirror's releases, never read from a Pages branch" % s.get("name"))
    if "continue-on-error" in s:
        fail("step %r has continue-on-error — a refusal must stop the job" % s.get("name"))
print("OK: no step reads a Pages index, none continues on error")

captured = [s for s in steps if re.search(r"\$\(\s*bash\s+scripts/publish-mirror\.sh", str(s.get("run", "")))]
if captured:
    fail("step %r captures publish-mirror.sh through $(...) — a refusal's ::error:: line would never reach the log" % captured[0].get("name"))
print("OK: no step captures the publisher's output")

# A global git credential helper outlives the step that installed it and reads
# MIRROR_TOKEN when git consults it (after a 401). Every later step that invokes
# the publisher must carry MIRROR_TOKEN in its env, or a mirror answering 401
# would have git send an empty token and the step die as "could not tell".
installers = [i for i, s in enumerate(steps) if "credential.helper" in str(s.get("run", ""))]
if len(installers) != 1:
    fail("expected exactly one step installing a git credential helper, found %d" % len(installers))
for s in steps[installers[0] + 1:]:
    if re.search(r"publish-mirror\.sh", str(s.get("run", ""))) and "MIRROR_TOKEN" not in (s.get("env") or {}):
        fail("step %r invokes the publisher after the credential helper was installed but sets no MIRROR_TOKEN — a 401 from the mirror would have git send an empty token" % s.get("name"))
print("OK: every publisher step after the credential helper carries MIRROR_TOKEN")


# The step that DECIDES publish_tree (writes it to GITHUB_OUTPUT) must ask
# GitHub which release is the newest stable one; a decision that never asks
# would let a rebuild of an older tag replace the mirror's default branch.
deciders = [s for s in steps if re.search(r"publish_tree=", str(s.get("run", "")))]
if len(deciders) != 1:
    fail("expected exactly one step writing publish_tree=, found %d" % len(deciders))
if "releases/latest" not in str(deciders[0].get("run", "")):
    fail("step %r decides publish_tree without reading releases/latest — an older stable tag would replace the mirror's default branch" % deciders[0].get("name"))
print("OK: the publish_tree decision reads releases/latest")
PY
}

# mutate <python expression over `doc`> — write a mutated copy of the real
# workflow and print its path. The mutation is applied to the PARSED document,
# and asserted to have changed it, so an inert edit cannot pass as coverage.
mutate() {
  local out="$BATS_TEST_TMPDIR/mutated-$BATS_TEST_NUMBER.yaml"
  python3 - "$WF" "$out" "$1" <<'PY' || return 1
import copy, sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
src, dst, expr = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    doc = yaml.safe_load(fh)
before = copy.deepcopy(doc)
steps = doc["jobs"]["publish"]["steps"]
exec(expr, {"doc": doc, "steps": steps})
if doc == before:
    sys.exit("mutation did not change the document: " + expr)
with open(dst, "w") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False)
print(dst)
PY
}

@test "shape: the real workflow — no checkout ref, tree pushes gated, release ungated, nothing captured, one pinned tag fetch" {
  shape "$WF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: 1 checkout step(s), none with a ref"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: 2 tree push step(s), each gated on publish_tree"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: the release step is not gated on publish_tree"* ]] || return 1
  [[ "$output" == *"OK: no step captures the publisher's output"* ]] || return 1
  [[ "$output" == *"OK: the one git fetch is the release tag's, compared against the expected commit"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: the publish_tree decision reads releases/latest"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: one index step, after the release step, derived for a dry run too"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: the gh-pages push stages the index step's result and is gated on it having changed"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: no step reads a Pages index, none continues on error"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"OK: every publisher step after the credential helper carries MIRROR_TOKEN"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: the index step without MIRROR_TOKEN reddens — the global credential helper would answer a 401 with an empty token" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'index'][0]; del s['env']['MIRROR_TOKEN']")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"invokes the publisher after the credential helper was installed but sets no MIRROR_TOKEN"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: restoring the source-index copy (a step fetching origin gh-pages) reddens — the index is derived from the mirror, never copied" {
  local m
  m="$(mutate "steps.insert(7, {'name': 'Guard the chart index (gh-pages)', 'id': 'guard-pages', 'run': 'git fetch --depth 1 origin gh-pages\\ngit worktree add --detach \"\$RUNNER_TEMP/pages-src\" FETCH_HEAD\\n'})")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: expected exactly one step running \`git fetch\` (the release tag, as data), found 2"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: a step reading a Pages index.yaml by path reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'dates'][0]; s['run'] = s['run'] + 'gh api repos/x/y/contents/index.yaml?ref=gh-pages\\n'")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"reads a Pages index by path"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: dropping the only-push-when-changed gate from the gh-pages push reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'push-index'][0]; s['if'] = \"steps.plan.outputs.dry_run != 'true' && steps.plan.outputs.publish_tree == 'true'\"")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"pushes gh-pages without"*"changed == 'true'"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: the index step moved before the release step reddens — the release just published would be missing" {
  local m
  m="$(mutate "i = [n for n, s in enumerate(steps) if s.get('id') == 'index'][0]; r = [n for n, s in enumerate(steps) if 'args=(release' in str(s.get('run', ''))][0]; steps.insert(r, steps.pop(i))")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: the index step "*"runs before the release step"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: an index step that a dry run skips reddens — the dry run must show the planned index" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'index'][0]; s['if'] = \"steps.plan.outputs.dry_run != 'true' && steps.plan.outputs.publish_tree == 'true'\"")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: the index step "*"is not gated on publish_tree for a real run and enabled for a dry run"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: a publish_tree decision that never reads releases/latest reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'plan'][0]; s['run'] = s['run'].replace('releases/latest', 'releases/tags/latest')")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"decides publish_tree without reading releases/latest"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: a checkout that takes a ref reddens" {
  local m
  m="$(mutate "[s for s in steps if str(s.get('uses','')).startswith('actions/checkout')][0]['with'] = {'ref': '\${{ steps.plan.outputs.tag }}'}")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: checkout step "*"takes a ref"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: a tree push without the publish_tree gate reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'push'][0]; s['if'] = \"steps.plan.outputs.dry_run != 'true'\"")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"pushes a tree without"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: capturing the publisher through \$(...) reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'target'][0]; s['run'] = 'REPO=\"\$(bash scripts/publish-mirror.sh target --mirror x --source-repo a/b)\"\n'")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: step "*"captures publish-mirror.sh through"* ]] || { echo "$output"; return 1; }
}

@test "shape mutation: a tag fetch that skips the EXPECT_SHA comparison reddens" {
  local m
  m="$(mutate "s = [s for s in steps if s.get('id') == 'src'][0]; s['run'] = s['run'].replace('EXPECT_SHA', 'IGNORED')")" || return 1
  shape "$m"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL: the tag fetch step does not compare against EXPECT_SHA"* ]] || { echo "$output"; return 1; }
}
