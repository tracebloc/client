#!/usr/bin/env bats
# Tests for scripts/check-chart-contents.sh — "a packaged chart carries no test
# suites or CI values". The guard's value is that it fails LOUD on a shipped
# tests/ or ci/ directory and fails CLOSED when it cannot list the tarball, so
# every test asserts one of three verdicts: refused (1), clean (0), could not
# tell (2).
#
# Two seams, both real code:
#   * hand-built tarballs (plain `tar`) drive the verdict logic with one defect
#     each, so the input domain is written down independently of the guard;
#   * `helm package` of the REAL charts, and of a copy whose .helmignore has the
#     rule stripped, proves the rule is the load-bearing mechanism and that the
#     guard sees the artefact helm actually produces (workspace rules 5 and 9).
#     Those tests need helm on PATH — `Standard checks / Unit tests` installs it
#     (azure/setup-helm) — and are SKIPPED, visibly, where it is absent.

GUARD_SH=""
REPO=""

setup() {
  GUARD_SH="${BATS_TEST_DIRNAME}/../check-chart-contents.sh"
  REPO="${BATS_TEST_DIRNAME}/../.."
  cd "$BATS_TEST_TMPDIR" || return 1
}

# Build <name>.tgz holding the given member paths (files; a trailing / makes a
# directory). Every member is prefixed with the chart name, as helm does. Each
# call stages in its own fresh directory, so nothing is ever deleted.
mk_tgz() { # $1 = chart name, $2... = member paths relative to the chart root
  local chart="$1"; shift
  local root
  root="$(mktemp -d "$BATS_TEST_TMPDIR/src-$chart.XXXXXX")"
  mkdir -p "$root/$chart"
  local m
  for m in "$@"; do
    case "$m" in
      */) mkdir -p "$root/$chart/$m" ;;
      *)  mkdir -p "$(dirname "$root/$chart/$m")"; printf 'x\n' >"$root/$chart/$m" ;;
    esac
  done
  tar -czf "$chart.tgz" -C "$root" "$chart"
}

guard() { run bash "$GUARD_SH" "$@"; }

# ── verdicts on hand-built tarballs ──────────────────────────────────────────

@test "a chart with templates, values and Chart.yaml is clean" {
  mk_tgz client Chart.yaml values.yaml templates/deployment.yaml templates/_helpers.tpl
  guard client.tgz
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"client.tgz clean ("* ]] || return 1
  [[ "$output" == *"ships only what helm installs"* ]] || return 1
}

@test "a chart-root tests/ directory is refused and every member is named" {
  mk_tgz client Chart.yaml values.yaml tests/rbac_test.yaml tests/secrets_test.yaml
  guard client.tgz
  [ "$status" -eq 1 ] || return 1
  # 3 = the tests/ directory entry itself plus its two files; tar lists all three.
  [[ "$output" == *"::error::check-chart-contents: client.tgz ships 3 member(s)"* ]] || return 1
  [[ "$output" == *"client/tests/rbac_test.yaml"* ]] || return 1
  [[ "$output" == *"client/tests/secrets_test.yaml"* ]] || return 1
  [[ "$output" == *".helmignore"* ]] || return 1
}

@test "a chart-root ci/ directory is refused" {
  mk_tgz client Chart.yaml ci/aks-values.yaml
  guard client.tgz
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client/ci/aks-values.yaml"* ]] || return 1
}

@test "helm's own templates/tests/ hook convention is NOT refused" {
  mk_tgz client Chart.yaml templates/tests/test-connection.yaml
  guard client.tgz
  [ "$status" -eq 0 ] || return 1
}

@test "a file merely named tests is not a directory finding" {
  mk_tgz client Chart.yaml tests values.yaml
  guard client.tgz
  [ "$status" -eq 0 ] || return 1
}

@test "two tarballs: one dirty reddens the run and both are reported" {
  mk_tgz client Chart.yaml values.yaml
  mk_tgz ingestor Chart.yaml tests/x_test.yaml
  guard client.tgz ingestor.tgz
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"client.tgz clean"* ]] || return 1
  [[ "$output" == *"ingestor/tests/x_test.yaml"* ]] || return 1
}

@test "a clean tarball after a dirty one does not rescue the run" {
  mk_tgz client Chart.yaml tests/x_test.yaml
  mk_tgz ingestor Chart.yaml
  guard client.tgz ingestor.tgz
  [ "$status" -eq 1 ] || return 1
}

# ── could not tell is never clean ────────────────────────────────────────────

@test "no tarball named is exit 2, not clean" {
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"no chart tarball named"* ]] || return 1
}

@test "a missing tarball is exit 2" {
  guard nope.tgz
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"does not exist"* ]] || return 1
}

@test "a file that is not a tarball is exit 2" {
  printf 'not a tarball\n' >client.tgz
  guard client.tgz
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"could not list client.tgz"* ]] || return 1
}

@test "a tarball with no Chart.yaml is exit 2 — not a chart, so not vouched for" {
  mk_tgz client values.yaml templates/deployment.yaml
  guard client.tgz
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"carries no <chart>/Chart.yaml"* ]] || return 1
}

# ── the real charts, through helm ────────────────────────────────────────────

need_helm() { command -v helm >/dev/null 2>&1 || skip "helm not on PATH (CI installs it; run inside the verify container locally)"; }

@test "helm package of the real client and ingestor charts is clean" {
  need_helm
  helm package "$REPO/client" >/dev/null
  helm package "$REPO/ingestor" >/dev/null
  guard client-*.tgz ingestor-*.tgz
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The exclusion actually removed something: the source tree has suites.
  [ -d "$REPO/client/tests" ] || return 1
  [ "$(find "$REPO/client/tests" -type f | wc -l)" -gt 0 ] || return 1
}

@test "mutation: strip tests/ and ci/ from .helmignore and the packaged chart reddens" {
  need_helm
  cp -R "$REPO/client" ./client-mutant
  grep -qE '^/tests/$' client-mutant/.helmignore || return 1   # anchor present before the mutation
  sed -e '/^\/tests\/$/d' -e '/^\/ci\/$/d' client-mutant/.helmignore >client-mutant/.helmignore.new
  mv client-mutant/.helmignore.new client-mutant/.helmignore
  ! grep -qE '^/(tests|ci)/$' client-mutant/.helmignore || return 1   # anchor applied
  helm package ./client-mutant >/dev/null
  guard client-*.tgz
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"client/tests/"* ]] || return 1
  [[ "$output" == *"client/ci/"* ]] || return 1
}

@test "the real .helmignore keeps a templates/tests/ hook while dropping chart-root tests/ (anchoring)" {
  need_helm
  # A minimal chart wearing the REAL client .helmignore: helm matches an
  # unanchored `tests/` against every path component, so only the leading
  # slash keeps helm's own `templates/tests/` hook convention shippable.
  mkdir -p fixture/templates/tests fixture/tests/deep fixture/ci
  printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' >fixture/Chart.yaml
  : >fixture/values.yaml; : >fixture/templates/deploy.yaml; : >fixture/templates/tests/hook.yaml
  : >fixture/tests/a_test.yaml; : >fixture/tests/deep/b_test.yaml; : >fixture/ci/v.yaml
  cp "$REPO/client/.helmignore" fixture/.helmignore
  grep -qE '^/tests/$' fixture/.helmignore || return 1
  helm package ./fixture >/dev/null
  tar tzf fixture-0.1.0.tgz >members.txt
  grep -qx 'fixture/templates/tests/hook.yaml' members.txt || { cat members.txt; return 1; }
  ! grep -qE '^fixture/(tests|ci)/' members.txt || { cat members.txt; return 1; }
  guard fixture-0.1.0.tgz
  [ "$status" -eq 0 ] || return 1
  # Mutation: the unanchored form drops the hook -- the defect Bugbot named.
  printf 'tests/\nci/\n' >fixture/.helmignore
  helm package ./fixture >/dev/null
  tar tzf fixture-0.1.0.tgz >members2.txt
  ! grep -qx 'fixture/templates/tests/hook.yaml' members2.txt || return 1
}

# ── the workflow calls the guard, right after packaging ──────────────────────

@test "release-helm-chart.yaml runs the guard after helm package and before anything is published" {
  wf="$REPO/.github/workflows/release-helm-chart.yaml"
  pkg=$(grep -n 'helm package ./ingestor' "$wf" | head -1 | cut -d: -f1)
  chk=$(grep -n 'bash scripts/check-chart-contents.sh' "$wf" | head -1 | cut -d: -f1)
  upl=$(grep -n 'name: Upload chart artifacts' "$wf" | head -1 | cut -d: -f1)
  [ -n "$pkg" ] && [ -n "$chk" ] && [ -n "$upl" ] || return 1
  [ "$pkg" -lt "$chk" ] || return 1
  [ "$chk" -lt "$upl" ] || return 1
  # Both packaged charts are named to the guard, not just one.
  grep -q 'check-chart-contents.sh client-\*.tgz ingestor-\*.tgz' "$wf" || return 1
}
