#!/usr/bin/env bats
# scripts/publish-guard.sh — stage the public deliverable and refuse anything
# else. Every test drives the REAL script against a fixture git repository it
# builds itself; the allowlists and forbidden lists the fixtures use are written
# HERE, independently of the repo's own .publish-include / .publish-forbidden,
# so the guard is never tested against its own copy of the rule. The repo's
# real lists get their own section at the end, fed inputs this file writes.
#
# Three verdicts, and every test names the one it expects: 0 clean, 1 refused,
# 2 could not tell. A mutation that reddens the guard must redden it for the
# rule the test is named for, so refusals are matched on the guard's `[name]`
# and the offending path/needle, not on the exit code alone.
#
# gitleaks is replaced by a PATH shim in every test but one, so the verdict
# plumbing (clean / leak / crash / absent) is exercised hermetically; the last
# gitleaks test runs the real binary when it is on PATH and skips visibly
# otherwise.

GUARD=""
REPO=""
SRC=""
OUT=""
SHIM=""

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="$REPO/scripts/publish-guard.sh"
  SRC="$BATS_TEST_TMPDIR/src"
  OUT="$BATS_TEST_TMPDIR/out"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM"
  # gitleaks shim: GL_MODE=clean|leak|crash. Prints its own marker so a test can
  # tell the shim ran.
  cat >"$SHIM/gitleaks" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in version) echo "shim-9.9.9"; exit 0 ;; esac
echo "shim gitleaks ran: $*"
case "${GL_MODE:-clean}" in
  clean) exit 0 ;;
  leak)  echo "Finding: REDACTED"; echo "File: tree/README.md"; echo "Line: 1"; exit 9 ;;
  crash) echo "panic: shim crash"; exit 1 ;;
esac
EOF
  chmod +x "$SHIM/gitleaks"
  export PUBLISH_GUARD_GITLEAKS="$SHIM/gitleaks"
  mk_repo
}

# A fixture repository with the shapes the guards must tell apart: deliverable
# files, a test suite inside a deliverable directory, source, build files.
mk_repo() {
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" config user.email t@example.invalid
  git -C "$SRC" config user.name t
  add_file README.md 'Fixture chart. Deployment help: support@tracebloc.io'
  add_file LICENSE 'Apache-2.0'
  add_file client/Chart.yaml 'apiVersion: v2'
  add_file client/templates/deploy.yaml 'kind: Deployment'
  add_file client/tests/x_test.yaml 'suite: x'
  add_file notes/tests 'a FILE named tests, not a directory'
  add_file scripts/install.sh '#!/usr/bin/env bash'
  add_file scripts/lib/common.sh 'log() { :; }'
  add_file scripts/tests/a.bats '@test "x" { :; }'
  add_file other/scripts/tests/b.bats '@test "y" { :; }'
  add_file Makefile 'all:'
  add_file CLAUDE.md 'guidance'
  add_file .github/workflows/ci.yml 'on: push'
  add_file internal/main.go 'package main'
  commit
  write_include \
    'client/**' \
    '!client/tests/**' \
    'scripts/install.sh' \
    'scripts/lib/**' \
    'notes/**' \
    'README.md' \
    'LICENSE'
  write_forbidden
}

add_file() { # path content
  mkdir -p "$SRC/$(dirname "$1")"
  printf '%s\n' "$2" >"$SRC/$1"
  git -C "$SRC" add -f "$1"
}
commit() { git -C "$SRC" commit -q -m fixture --allow-empty; }
write_include() { printf '# fixture allowlist\n' >"$SRC/.publish-include"; printf '%s\n' "$@" >>"$SRC/.publish-include"; }
# The fixture's forbidden list — a DIFFERENT list from the repo's, written here.
# Two string tiers: a mailbox and an ARN refuse; a tracker reference, an RFC
# identifier and a non-production host are reported.
write_forbidden() {
  {
    printf '[paths]\n'
    printf '%s\n' 'tests/' 'scripts/tests/' 'Makefile' 'CLAUDE.md' '.github/' '*.go' 'kubeconfig*'
    printf '\n[strings-refuse]\n'
    printf '%s\n' '[A-Za-z0-9._%+-]+@tracebloc\.io' 'arn:aws:'
    printf '\n[strings-report]\n'
    printf '%s\n' 'backend#' 'RFC-0' 'dev-api\.tracebloc\.io'
    printf '\n[allow]\n'
    printf '%s\n' 'support@tracebloc\.io'
  } >"$SRC/.publish-forbidden"
}
# A forbidden list with only a [paths] section and the refuse tier below, for
# the tests that exercise path matching alone.
paths_only_forbidden() { printf '[paths]\n%s\n[strings-refuse]\narn:aws:\n' "$1" >"$SRC/.publish-forbidden"; }
# plant PATH LINE — append LINE to a fixture file, commit, and PROVE it landed
# (an inert mutation and real coverage look identical in a log).
plant() {
  printf '%s\n' "$2" >>"$SRC/$1"
  git -C "$SRC" add "$1" && commit
  [ "$(grep -cF -- "$2" "$SRC/$1")" -eq 1 ] || return 1
}
guard() { run bash "$GUARD" --source "$SRC" --out "$OUT" "$@"; }
staged() { ( cd "$OUT/tree" && find . -type f | sed 's|^\./||' | sort ); }

# ── the clean case, and what "clean" is made of ───────────────────────────────

@test "a clean fixture is staged, all four guards report, exit 0" {
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[allowlist] staged 7 of 14 tracked file(s)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-paths] clean (7 pattern(s) against 7 staged path(s))"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] clean (2 refuse + 3 report needle(s), 1 allow token(s); 7 text file(s) scanned, 0 binary"* ]] || return 1
  [[ "$output" == *"[gitleaks] clean"* ]] || return 1
  [[ "$output" == *"publish-guard: OK — all 4 guards ran and passed"* ]] || return 1
  # The staged tree is exactly the allowlisted set: nothing more, nothing less.
  [ "$(staged | paste -sd' ' -)" = "LICENSE README.md client/Chart.yaml client/templates/deploy.yaml notes/tests scripts/install.sh scripts/lib/common.sh" ] || { staged; return 1; }
  [ ! -e "$OUT/tree/Makefile" ] || return 1
  [ ! -e "$OUT/tree/client/tests" ] || return 1
  [ ! -e "$OUT/tree/internal" ] || return 1
}

@test "an untracked file matching the allowlist is not staged (tracked files only)" {
  printf 'scratch\n' >"$SRC/client/untracked.yaml"
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$OUT/tree/client/untracked.yaml" ] || return 1
}

@test "every guard still runs and reports after an earlier one has refused" {
  write_include 'client/**' 'README.md'     # drops the !client/tests/** line
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"[forbidden-paths] REFUSED"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] clean"* ]] || return 1
  [[ "$output" == *"[gitleaks] clean"* ]] || return 1
  [[ "$output" == *"publish-guard: REFUSED — do not publish"* ]] || return 1
}

# ── guard 2: forbidden paths ──────────────────────────────────────────────────

@test "mutation: dropping the !client/tests/** exclusion is caught by the tests/ path rule" {
  write_include 'client/**' 'README.md'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ -f "$OUT/tree/client/tests/x_test.yaml" ] || return 1   # the mutation landed: the file WAS staged
  [[ "$output" == *"[forbidden-paths] REFUSED — forbidden path pattern 'tests/' matched:"* ]] || return 1
  [[ "$output" == *"tree:client/tests/x_test.yaml"* ]] || return 1
}

@test "mutation: allowlisting Go source is caught by *.go, by file name anywhere in the tree" {
  write_include 'client/**' '!client/tests/**' 'internal/**' 'README.md'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forbidden path pattern '*.go' matched:"* ]] || return 1
  [[ "$output" == *"tree:internal/main.go"* ]] || return 1
}

@test "mutation: allowlisting the Makefile and CLAUDE.md is caught by name" {
  write_include 'Makefile' 'CLAUDE.md' 'README.md'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"forbidden path pattern 'Makefile' matched:"*"tree:Makefile"* ]] || return 1
  [[ "$output" == *"forbidden path pattern 'CLAUDE.md' matched:"*"tree:CLAUDE.md"* ]] || return 1
}

@test "mutation: a workflow directory is caught by .github/ as a directory anywhere" {
  write_include '.github/**' 'README.md'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"forbidden path pattern '.github/' matched:"*"tree:.github/workflows/ci.yml"* ]] || return 1
}

@test "a pattern with a slash is anchored to the staged root; one without matches any component" {
  write_include 'scripts/tests/**' 'other/**' 'README.md'
  paths_only_forbidden 'scripts/tests/'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forbidden path pattern 'scripts/tests/' matched:"* ]] || return 1
  [[ "$output" == *"tree:scripts/tests/a.bats"* ]] || return 1
  [[ "$output" != *"tree:other/scripts/tests/b.bats"* ]] || return 1   # anchored: not this one
  # The unanchored form reaches it.
  rm -rf "$OUT"
  paths_only_forbidden 'tests/'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"tree:other/scripts/tests/b.bats"* ]] || return 1
}

@test "a trailing slash means 'as a directory': a FILE named tests is not a tests/ finding" {
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$OUT/tree/notes/tests" ] || return 1
}

@test "a release asset named like a credential file is refused by the path rule" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  printf 'apiVersion: v1\n' >"$BATS_TEST_TMPDIR/assets/kubeconfig.yaml"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forbidden path pattern 'kubeconfig*' matched:"*"assets:kubeconfig.yaml"* ]] || return 1
}

@test "no [paths] entries is could-not-tell, not clean" {
  printf '[strings-refuse]\narn:aws:\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[forbidden-paths] COULD NOT TELL — '"*"' has no [paths] entries"* ]] || return 1
}

# ── guard 3: forbidden strings — the refuse tier ──────────────────────────────

@test "mutation: a refuse-tier needle in a staged file is refused, tier, file and line named" {
  plant README.md 'role arn:aws:iam::000000000000:role/planted'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s):"* ]] || return 1
  [[ "$output" == *"    tree/README.md:2"* ]] || return 1
  # The matched text itself is never echoed.
  [[ "$output" != *"role/planted"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 1 refuse-tier hit(s), 0 report-tier hit(s) counted"* ]] || return 1
}

@test "needles match case-insensitively" {
  plant README.md 'ARN:AWS:s3:::planted'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"[strings-refuse] needle 'arn:aws:' found in 1 staged line(s)"* ]] || return 1
}

@test "an [allow] token spares a line only when it was the whole reason the needle hit" {
  # The fixture README already carries support@tracebloc.io → clean.
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # A personal mailbox on the same line as the allowed one is still refused.
  rm -rf "$OUT"
  plant README.md 'or write to someone@tracebloc.io / support@tracebloc.io'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-refuse] needle '[A-Za-z0-9._%+-]+@tracebloc\.io' found in 1 staged line(s):"*"tree/README.md:2"* ]] || return 1
}

@test "mutation: a private needle supplied with --extra-forbidden joins the refuse tier" {
  printf '# private list\nplanted-tenant\n' >"$BATS_TEST_TMPDIR/tenants.txt"
  plant client/templates/deploy.yaml '# for Planted-Tenant only'
  guard --extra-forbidden "$BATS_TEST_TMPDIR/tenants.txt"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-refuse] needle 'planted-tenant' found in 1 staged line(s):"*"tree/client/templates/deploy.yaml:2"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 1 refuse-tier hit(s), 0 report-tier hit(s) counted (3 refuse + 3 report needle(s)"* ]] || return 1
}

@test "an empty --extra-forbidden list is could-not-tell: the private needles were not supplied" {
  printf '# nothing here\n\n' >"$BATS_TEST_TMPDIR/tenants.txt"
  guard --extra-forbidden "$BATS_TEST_TMPDIR/tenants.txt"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — extra forbidden list '"*"tenants.txt' is empty"* ]] || return 1
}

@test "a missing --extra-forbidden list is could-not-tell" {
  guard --extra-forbidden "$BATS_TEST_TMPDIR/absent.txt"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — extra forbidden list '"*"absent.txt' is missing or unreadable"* ]] || return 1
}

@test "a refuse-tier needle inside a release asset is refused with the asset named" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  printf '#!/bin/sh\n# bucket arn:aws:s3:::planted\n' >"$BATS_TEST_TMPDIR/assets/install.sh"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[assets] staged 1 release asset(s):"*"    install.sh"* ]] || return 1
  [[ "$output" == *"[strings-refuse] needle 'arn:aws:' found in 1 staged line(s):"*"assets/install.sh:2"* ]] || return 1
}

@test "a binary asset is opaque to the string scan and counted as such" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  printf 'ELF\000\000arn:aws:x\000' >"$BATS_TEST_TMPDIR/assets/tracebloc-linux-amd64"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"7 text file(s) scanned, 1 binary file(s) opaque to this scan"* ]] || return 1
}

# ── guard 3: forbidden strings — the report tier and --strict ─────────────────

@test "a report-tier hit alone is counted, not refused: exit 0, per-needle total, most-hit files" {
  plant README.md 'see backend#1234 for the rationale'
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] [strings-report] needle 'backend#' found in 1 staged line(s) — counted, not refused (--strict refuses)"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] [strings-report] 1 hit(s) in 1 file(s); most-hit files:"* ]] || return 1
  [[ "$output" == *"         1  tree/README.md"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 0 refuse-tier hit(s), 1 report-tier hit(s) counted"* ]] || return 1
  [[ "$output" != *"REFUSED"* ]] || return 1
  [[ "$output" == *"publish-guard: OK — all 4 guards ran and passed"* ]] || return 1
  # The matched text itself is never echoed; the full location list is in the report.
  [[ "$output" != *"for the rationale"* ]] || return 1
  grep -qF "[strings-report] needle 'backend#':" "$OUT/publish-guard-report.txt" || return 1
  grep -qF "tree/README.md:2" "$OUT/publish-guard-report.txt" || return 1
}

@test "mutation: the same report-tier hit under --strict is refused, tier named" {
  plant README.md 'see backend#1234 for the rationale'
  guard --strict
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] REFUSED — [strings-report (strict)] needle 'backend#' found in 1 staged line(s):"* ]] || return 1
  [[ "$output" == *"    tree/README.md:2"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 0 refuse-tier hit(s), 1 report-tier hit(s) refused under --strict"* ]] || return 1
  [[ "$output" == *"publish-guard: REFUSED — do not publish"* ]] || return 1
}

@test "--strict with no report-tier hit is still clean" {
  guard --strict
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] clean (2 refuse + 3 report needle(s)"* ]] || return 1
}

@test "a non-production hostname is report-tier: counted, and refused under --strict" {
  plant client/Chart.yaml '# points at dev-api.tracebloc.io'
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-report] needle 'dev-api\.tracebloc\.io' found in 1 staged line(s) — counted, not refused"* ]] || return 1
  rm -rf "$OUT"
  guard --strict
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"REFUSED — [strings-report (strict)] needle 'dev-api\.tracebloc\.io' found in 1 staged line(s):"*"tree/client/Chart.yaml:2"* ]] || return 1
}

@test "the most-hit table sums every report-tier needle per file, largest first, ten rows at most" {
  plant README.md 'backend#1 and RFC-0001 on one line'
  plant README.md 'backend#2 on another'
  plant client/Chart.yaml '# backend#3'
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-report] needle 'backend#' found in 3 staged line(s)"* ]] || return 1
  [[ "$output" == *"[strings-report] needle 'RFC-0' found in 1 staged line(s)"* ]] || return 1
  # 3 + 1 hits, 2 files; README's two lines (three hits) outrank Chart.yaml's one.
  [[ "$output" == *"[strings-report] 4 hit(s) in 2 file(s); most-hit files:"*"         3  tree/README.md"*"         1  tree/client/Chart.yaml"* ]] || { echo "$output"; return 1; }
  # Eleven files, one hit each: the table stops at ten.
  rm -rf "$OUT"
  local i
  for i in 01 02 03 04 05 06 07 08 09 10 11; do add_file "notes/n$i.md" "ref backend#$i"; done
  commit
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[strings-report] 15 hit(s) in 13 file(s); most-hit files:"* ]] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -cE '^ +[0-9]+  (tree|assets)/')" -eq 10 ] || { echo "$output"; return 1; }
}

@test "a refuse-tier hit and a report-tier hit in one run: refused, and the report tier still counted" {
  plant README.md 'arn:aws:iam::000000000000:root — see backend#9'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — [strings-refuse] needle 'arn:aws:' found in 1 staged line(s):"* ]] || return 1
  [[ "$output" == *"[strings-report] needle 'backend#' found in 1 staged line(s) — counted, not refused"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 1 refuse-tier hit(s), 1 report-tier hit(s) counted"* ]] || return 1
}

# ── guard 3: the forbidden list itself ────────────────────────────────────────

@test "no [strings-refuse] entries is could-not-tell, not clean (a guard with nothing to refuse)" {
  printf '[paths]\ntests/\n[strings-report]\nbackend#\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — '"*"' has no [strings-refuse] entries — a guard with nothing to refuse is misconfigured"* ]] || return 1
  # A present-but-empty section is the same finding.
  rm -rf "$OUT"
  printf '[paths]\ntests/\n[strings-refuse]\n# none yet\n[strings-report]\nbackend#\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"has no [strings-refuse] entries"* ]] || return 1
}

@test "an empty [strings-refuse] is judged before the private needles join it" {
  printf '[paths]\ntests/\n[strings-report]\nbackend#\n' >"$SRC/.publish-forbidden"
  printf 'planted-tenant\n' >"$BATS_TEST_TMPDIR/tenants.txt"
  guard --extra-forbidden "$BATS_TEST_TMPDIR/tenants.txt"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"has no [strings-refuse] entries"* ]] || return 1
}

@test "a needle listed in both string tiers is could-not-tell, the duplicate named" {
  printf '[paths]\ntests/\n[strings-refuse]\narn:aws:\nbackend#\n[strings-report]\nbackend#\nRFC-0\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — '"*"' lists needle 'backend#' in both [strings-refuse] and [strings-report] — a needle has one tier"* ]] || return 1
}

@test "an unknown section header is could-not-tell for both scans that read the list" {
  # The retired name is the likeliest misspelling; nothing under it may be read
  # as a rule of the section before it.
  printf '[paths]\ntests/\n[strings]\narn:aws:\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-paths] COULD NOT TELL — '"*"' has an unknown section [strings] — the guard reads only [paths] [strings-refuse] [strings-report] [allow]"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — '"*"' has an unknown section [strings]"* ]] || return 1
  # A header with a space or a case slip is a header too, refused by name rather
  # than read as a needle of the section before it.
  rm -rf "$OUT"
  printf '[paths]\ntests/\n[strings-refuse]\narn:aws:\n[strings report]\nbackend#\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"has an unknown section [strings report]"* ]] || return 1
  [[ "$output" != *"needle 'backend#'"* ]] || return 1
}

@test "a missing forbidden list is could-not-tell for both scans that read it" {
  rm "$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[forbidden-paths] COULD NOT TELL — forbidden list '"*"' is missing or unreadable"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — forbidden list '"*"' is missing or unreadable"* ]] || return 1
}

# ── guard 1: allowlist fail-closed cases ──────────────────────────────────────

@test "an allowlist with no include entries is could-not-tell" {
  printf '# only comments\n\n' >"$SRC/.publish-include"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[allowlist] COULD NOT TELL — allowlist '"*"' lists no include entries"* ]] || return 1
}

@test "a missing allowlist is could-not-tell" {
  rm "$SRC/.publish-include"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[allowlist] COULD NOT TELL — allowlist '"*"' is missing or unreadable"* ]] || return 1
}

@test "an allowlist that matches nothing is could-not-tell (a mirror with nothing in it)" {
  write_include 'nothing-here/**'
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[allowlist] COULD NOT TELL — the allowlist matched none of the 14 tracked files"* ]] || return 1
}

@test "a symlink in the allowlisted set is could-not-tell" {
  ln -s ../Makefile "$SRC/client/link"
  git -C "$SRC" add client/link && commit
  guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[allowlist] COULD NOT TELL — 'client/link' is a symlink"* ]] || return 1
}

@test "a non-empty --out is could-not-tell" {
  mkdir -p "$OUT" && printf 'stale\n' >"$OUT/stale.txt"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — --out '"*"' is not empty"* ]] || return 1
}

@test "a source that is not a git work tree is could-not-tell" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  cp "$SRC/.publish-include" "$SRC/.publish-forbidden" "$BATS_TEST_TMPDIR/plain/"
  run bash "$GUARD" --source "$BATS_TEST_TMPDIR/plain" --out "$OUT"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[allowlist] COULD NOT TELL — git ls-files failed"* ]] || return 1
}

@test "an --assets directory with no files is could-not-tell" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — --assets '"*"' holds no files"* ]] || return 1
}

# ── guard 4: gitleaks plumbing, then the real thing ───────────────────────────

@test "a missing scanner is could-not-tell, never clean" {
  PUBLISH_GUARD_GITLEAKS="$BATS_TEST_TMPDIR/no-such-gitleaks" guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[gitleaks] COULD NOT TELL — scanner '"*"no-such-gitleaks' is not on PATH"* ]] || return 1
  [[ "$output" == *"publish-guard: COULD NOT TELL — do not publish"* ]] || return 1
}

@test "a scanner that finds a secret refuses, and its redacted report is shown" {
  GL_MODE=leak guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[gitleaks] REFUSED — secrets detected in the staged tree:"* ]] || return 1
  [[ "$output" == *"Finding: REDACTED"* ]] || return 1
}

@test "a scanner that crashes is could-not-tell (its exit code is not a verdict)" {
  GL_MODE=crash guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[gitleaks] COULD NOT TELL — scanner exited 1"* ]] || return 1
}

@test "the scanner is pointed at the staged tree, with --no-git and --redact" {
  # The scanner's own output is shown on a refusal, which is when its argv is
  # visible to this test. The guard resolves --out to an absolute path, so only
  # the tail of the --source value is compared.
  GL_MODE=leak guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"shim gitleaks ran: detect --no-git --redact --no-banner --exit-code 9 --source "*"/out"* ]] || { echo "$output"; return 1; }
}

@test "real gitleaks: a planted access-key-shaped string in a staged file is refused" {
  command -v gitleaks >/dev/null 2>&1 || skip "gitleaks not on PATH (the publish workflow installs it; run locally with gitleaks installed)"
  unset PUBLISH_GUARD_GITLEAKS
  # Built at run time, so this file never carries a key-shaped literal.
  local key
  key="AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
  plant client/templates/deploy.yaml "  aws_key: $key"
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[gitleaks] REFUSED — secrets detected"* ]] || return 1
  [[ "$output" != *"$key"* ]] || return 1   # --redact held
}

# ── the repo's OWN lists, fed inputs written here ─────────────────────────────
# The inputs below are written independently of .publish-forbidden; the summary
# line's needle counts are asserted so a needle added to either tier without a
# planted input here reddens this file.

@test "the committed .publish-forbidden refuses every refuse-tier needle by name and spares the support mailbox" {
  cp "$REPO/.publish-forbidden" "$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }    # README's support@tracebloc.io is allowed
  [[ "$output" == *"[forbidden-strings] clean (3 refuse + 10 report needle(s), 1 allow token(s)"* ]] || { echo "$output"; return 1; }
  rm -rf "$OUT"
  plant README.md 'ask someone@tracebloc.io'
  plant client/Chart.yaml '# role arn:aws:iam::000000000000:role/x'
  plant scripts/lib/common.sh 'IMG=000000000000.dkr.ecr.eu-central-1.amazonaws.com/x'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  local needle
  for needle in '[A-Za-z0-9._%+-]+@tracebloc\.io' 'arn:aws:' '[0-9]{12}\.dkr\.ecr\.'; do
    [[ "$output" == *"REFUSED — [strings-refuse] needle '$needle' found in 1 staged line(s):"* ]] || { echo "missing: $needle"; echo "$output"; return 1; }
  done
  [[ "$output" == *"[forbidden-strings] 3 refuse-tier hit(s), 0 report-tier hit(s) counted"* ]] || return 1
}

@test "the committed .publish-forbidden counts every report-tier needle by name, and --strict refuses them" {
  cp "$REPO/.publish-forbidden" "$SRC/.publish-forbidden"
  plant README.md 'see backend#1 and rfcs#2 and RFC-0003 and RFC-BACKEND-0004'
  plant README.md 'see e2e-test-agent#5 and tracebloc/backend'
  plant scripts/lib/common.sh 'A=https://dev-api.tracebloc.io/ B=https://stg-api.tracebloc.io/'
  plant scripts/lib/common.sh 'C=https://dev.tracebloc.io/ D=https://stg.tracebloc.io/'
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local needle
  for needle in 'backend#' 'rfcs#' 'RFC-0' 'RFC-BACKEND' 'e2e-test-agent#' 'tracebloc/backend' \
                'dev-api\.tracebloc\.io' 'stg-api\.tracebloc\.io' 'dev\.tracebloc\.io' 'stg\.tracebloc\.io'; do
    [[ "$output" == *"[strings-report] needle '$needle' found in 1 staged line(s) — counted, not refused"* ]] || { echo "missing: $needle"; echo "$output"; return 1; }
  done
  [[ "$output" == *"[strings-report] 10 hit(s) in 2 file(s); most-hit files:"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 0 refuse-tier hit(s), 10 report-tier hit(s) counted (3 refuse + 10 report needle(s)"* ]] || return 1
  rm -rf "$OUT"
  guard --strict
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — [strings-report (strict)] needle 'backend#' found in 1 staged line(s):"*"tree/README.md:2"* ]] || return 1
  [[ "$output" == *"REFUSED — [strings-report (strict)] needle 'stg\.tracebloc\.io' found in 1 staged line(s):"*"tree/scripts/lib/common.sh:3"* ]] || return 1
}

@test "the committed .publish-forbidden refuses each forbidden path class by name" {
  cp "$REPO/.publish-forbidden" "$SRC/.publish-forbidden"
  add_file docs/rfcs/0001.md 'rfc'
  add_file docs/migration-tools/x.sh 'tool'
  add_file STYLE.md 'style'
  add_file .cursor/BUGBOT.md 'bot'
  add_file go.mod 'module x'
  add_file secret.pem 'pem'
  add_file .env.local 'x=1'
  commit
  write_include 'docs/**' 'STYLE.md' '.cursor/**' 'go.mod' 'secret.pem' '.env.local' 'README.md'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  local pat
  for pat in 'docs/rfcs/' 'docs/migration-tools/' 'STYLE.md' '.cursor/' 'go.mod' '*.pem' '.env*'; do
    [[ "$output" == *"forbidden path pattern '$pat' matched:"* ]] || { echo "missing: $pat"; echo "$output"; return 1; }
  done
}

@test "the committed .publish-include stages the deliverable of the real repo and nothing forbidden" {
  run bash "$GUARD" --source "$REPO" --out "$OUT"
  # Asserted CLEAN: the refuse tier must hold on the real deliverable, and the
  # report tier (the known backlog of internal references in the chart and the
  # installers) is counted, not refused, until --strict is the policy. A
  # refuse-tier needle landing in a deliverable file reddens this test — which
  # is the point.
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-paths] clean"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] 0 refuse-tier hit(s), "* || "$output" == *"[forbidden-strings] clean ("* ]] || { echo "$output"; return 1; }
  local f
  for f in client/Chart.yaml client/values.yaml ingestor/Chart.yaml scripts/install.sh scripts/install.ps1 scripts/install-k8s.sh scripts/lib/common.sh scripts/manifest.sha256 README.md LICENSE docs/INSTALL.md; do
    [ -f "$OUT/tree/$f" ] || { echo "not staged: $f"; return 1; }
  done
  for f in client/tests client/ci Makefile CLAUDE.md STYLE.md .github .cursor scripts/tests docs/rfcs docs/migration-tools scripts/publish-guard.sh; do
    [ ! -e "$OUT/tree/$f" ] || { echo "staged but forbidden: $f"; return 1; }
  done
  # The manifest's own list is the installer's shipped set: every file it names
  # was staged (derived, not restated).
  while read -r _digest path _rest; do
    [ -z "$path" ] || [ -f "$OUT/tree/$path" ] || { echo "manifest names $path, not staged"; return 1; }
  done <"$REPO/scripts/manifest.sha256"
}

@test "the committed .publish-include-pages stages exactly the chart index and packages" {
  add_file index.yaml 'apiVersion: v1'
  add_file client-1.0.0.tgz 'not really gzip'
  add_file notes.md 'stray'
  commit
  cp "$REPO/.publish-include-pages" "$SRC/.publish-include"
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(staged | paste -sd' ' -)" = "client-1.0.0.tgz index.yaml" ] || { staged; return 1; }
}
