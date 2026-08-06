#!/usr/bin/env bats
# Tests for scripts/chart-version-guard.sh — "chart content ⇒ Chart.yaml version
# bump". Covers BOTH published charts (client#519: the first version of the guard
# classified only client/** and therefore let every unbumped ingestor/** edit
# through, which is the same dark ship it was written to stop — PR #472), the
# derived chart list, and every fail-closed read.
#
# These run against a REAL throwaway git repo, not a stubbed `git`: the guard's
# whole job is reading a diff correctly, so stubbing the diff would test the stub.

GUARD_SH=""
BASE=""

setup() {
  GUARD_SH="${BATS_TEST_DIRNAME}/../chart-version-guard.sh"
  cd "$BATS_TEST_TMPDIR" || return 1
  rm -rf repo && mkdir repo && cd repo || return 1

  git init -q -b main .
  git config user.email guard@test.local
  git config user.name  guard-test

  mkdir -p .github/workflows client/templates client/ci client/tests ingestor/templates
  seed_workflow './client --version "${TAG#v}" --app-version "${TAG#v}"' './ingestor'
  printf 'name: client\nversion: 1.9.9\nappVersion: "1.9.9"\n'   >client/Chart.yaml
  printf 'name: ingestor\nversion: 0.2.0\nappVersion: "0.3.0"\n' >ingestor/Chart.yaml
  printf 'replicas: 1\n'  >client/values.yaml
  printf 'replicas: 1\n'  >ingestor/values.yaml
  printf '{"type":"object"}\n' >client/values.schema.json
  printf 'kind: Deployment\n' >client/templates/app.yaml
  printf 'kind: Job\n'        >ingestor/templates/job.yaml
  printf 'aks: true\n'        >client/ci/aks-values.yaml
  printf 'public: true\n'     >client/tests/values-public-images.yaml
  printf '# migration notes\n' >client/MIGRATION.md
  git add -A && git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# Write a release workflow whose `helm package` lines name the given charts.
seed_workflow() {
  {
    printf 'name: Release helm chart\njobs:\n  release:\n    steps:\n      - run: |\n'
    for spec in "$@"; do printf '          helm package %s\n' "$spec"; done
  } >.github/workflows/release-helm-chart.yaml
}

commit()  { git add -A && git commit -qm change; }
bump()    { sed -i.bak 's/^version: .*/version: 99.0.0/' "$1/Chart.yaml" && rm -f "$1/Chart.yaml.bak"; }
guard()   { run env BASE_SHA="$BASE" bash "$GUARD_SH"; }

# ── the client#519 regression: ingestor is a published chart too ─────────────

@test "ingestor/templates change without a bump is REJECTED (client#519)" {
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ingestor/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "ingestor/templates change WITH an ingestor bump passes" {
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  bump ingestor
  commit
  guard
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ingestor chart content changed and ingestor/Chart.yaml 'version:' was bumped"* ]] || return 1
}

@test "ingestor/values.yaml change without a bump is REJECTED" {
  printf 'replicas: 3\n' >ingestor/values.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ingestor/Chart.yaml"* ]] || return 1
}

@test "deleting an ingestor template without a bump is REJECTED" {
  git rm -q ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ingestor/Chart.yaml"* ]] || return 1
}

@test "bumping the WRONG chart does not satisfy the other chart" {
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  bump client            # client bumped, ingestor is the one that changed
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ingestor/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

# ── client chart: preserved behaviour + the newly covered schema ─────────────

@test "client/templates change without a bump is REJECTED" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "client/templates change WITH a client bump passes" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  bump client
  commit
  guard
  [ "$status" -eq 0 ] || return 1
}

@test "client/values.schema.json change without a bump is REJECTED" {
  printf '{"type":"object","required":["x"]}\n' >client/values.schema.json
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "an appVersion-only edit is NOT a version bump" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  sed -i.bak 's/^appVersion: .*/appVersion: "2.0.0"/' client/Chart.yaml && rm -f client/Chart.yaml.bak
  commit
  guard
  [ "$status" -eq 1 ] || return 1
}

# ── both charts in one PR ────────────────────────────────────────────────────

@test "both charts changed, neither bumped: BOTH are reported in one run" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  printf 'kind: Job\nnew: true\n'        >ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client/Chart.yaml 'version:' was NOT bumped"*   ]] || return 1
  [[ "$output" == *"ingestor/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "both charts changed, only one bumped: fails naming just the unbumped one" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  printf 'kind: Job\nnew: true\n'        >ingestor/templates/job.yaml
  bump client
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client chart content changed and client/Chart.yaml 'version:' was bumped"* ]] || return 1
  [[ "$output" == *"ingestor/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "both charts changed and both bumped passes" {
  printf 'kind: Deployment\nnew: true\n' >client/templates/app.yaml
  printf 'kind: Job\nnew: true\n'        >ingestor/templates/job.yaml
  bump client
  bump ingestor
  commit
  guard
  [ "$status" -eq 0 ] || return 1
}

# ── not chart content ────────────────────────────────────────────────────────

@test "docs-only change is N/A" {
  printf '# migration notes\nmore\n' >client/MIGRATION.md
  commit
  guard
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"guard N/A"* ]] || return 1
}

@test "ci/ and tests/ values are packaged but never rendered: N/A" {
  printf 'aks: false\n'    >client/ci/aks-values.yaml
  printf 'public: false\n' >client/tests/values-public-images.yaml
  commit
  guard
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"guard N/A"* ]] || return 1
}

@test "a Chart.yaml bump with no content change is N/A, not an error" {
  bump client
  commit
  guard
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"guard N/A"* ]] || return 1
}

# ── the chart list is DERIVED, so a new published chart is guarded on day one ─

@test "a third packaged chart is guarded without touching the guard" {
  mkdir -p extra/templates
  printf 'name: extra\nversion: 0.1.0\n' >extra/Chart.yaml
  printf 'kind: ConfigMap\n'             >extra/templates/cm.yaml
  seed_workflow './client' './ingestor' './extra'
  commit
  BASE="$(git rev-parse HEAD)"          # the chart now exists on both sides

  printf 'kind: ConfigMap\nnew: true\n' >extra/templates/cm.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"extra/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}

@test "a chart removed from the release workflow stops being guarded" {
  seed_workflow './client'              # ingestor no longer published
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"guard N/A"* ]] || return 1
}

# ── fail closed: a guard that cannot verify must not claim it did ────────────

@test "missing BASE_SHA fails closed" {
  run env -u BASE_SHA bash "$GUARD_SH"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"could not determine the PR base SHA"* ]] || return 1
}

@test "unusable BASE_SHA fails closed" {
  run env BASE_SHA=0000000000000000000000000000000000000000 bash "$GUARD_SH"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"refusing to report N/A without checking"* ]] || return 1
}

@test "an absent release workflow fails closed" {
  git rm -q .github/workflows/release-helm-chart.yaml
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"could not read the packaged chart list"* ]] || return 1
}

@test "a release workflow that packages nothing fails closed" {
  printf 'name: Release\njobs: {}\n' >.github/workflows/release-helm-chart.yaml
  printf 'kind: Job\nnew: true\n'    >ingestor/templates/job.yaml
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"could not read the packaged chart list"* ]] || return 1
}

@test "a packaged chart with no Chart.yaml fails closed" {
  seed_workflow './client' './ingestor' './ghost'
  commit
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ghost/Chart.yaml does not exist"* ]] || return 1
}

# ── the SIGPIPE class this guard must never regress into ────────────────────

@test "a changed-file list past the 64KB pipe buffer still catches the bump" {
  mkdir -p docs/filler
  i=0
  while [ "$i" -lt 2200 ]; do
    : >"docs/filler/padding-file-with-a-deliberately-long-name-${i}.md"
    i=$((i + 1))
  done
  printf 'kind: Job\nnew: true\n' >ingestor/templates/job.yaml
  commit
  # Prove the list really is past the buffer that flipped the old pipeline.
  bytes="$(git diff --name-only "${BASE}...HEAD" | wc -c)"
  [ "$bytes" -gt 65622 ] || return 1
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"ingestor/Chart.yaml 'version:' was NOT bumped"* ]] || return 1
}
