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
  export TAG="" EXPECT_SHA="" BRANCH="" REPO=""
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
  run env PATH="$SHIM:$PATH" bash -c "cd '$dir' && bash '$body'"
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

releases = [s for s in steps if re.search(r"publish-mirror\.sh\s+\"?\$\{?args|publish-mirror\.sh\s+release\b", str(s.get("run", "")))]
if len(releases) != 1:
    fail("expected exactly one release step, found %d" % len(releases))
if "publish_tree" in str(releases[0].get("if", "")):
    fail("the release step is gated on publish_tree — a prerelease must still get its release")
print("OK: the release step is not gated on publish_tree")

captured = [s for s in steps if re.search(r"\$\(\s*bash\s+scripts/publish-mirror\.sh", str(s.get("run", "")))]
if captured:
    fail("step %r captures publish-mirror.sh through $(...) — a refusal's ::error:: line would never reach the log" % captured[0].get("name"))
print("OK: no step captures the publisher's output")

fetches = [s for s in steps if re.search(r"git fetch[^\n]*refs/tags/", str(s.get("run", "")))]
if len(fetches) != 1:
    fail("expected exactly one step fetching a tag, found %d" % len(fetches))
if "EXPECT_SHA" not in str(fetches[0].get("run", "")):
    fail("the tag fetch step does not compare against EXPECT_SHA")
print("OK: the one tag fetch compares against the expected commit")

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
  [[ "$output" == *"OK: the one tag fetch compares against the expected commit"* ]] || return 1
  [[ "$output" == *"OK: the publish_tree decision reads releases/latest"* ]] || { echo "$output"; return 1; }
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
