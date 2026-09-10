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
write_forbidden() {
  {
    printf '[paths]\n'
    printf '%s\n' 'tests/' 'scripts/tests/' 'Makefile' 'CLAUDE.md' '.github/' '*.go' 'kubeconfig*'
    printf '\n[strings]\n'
    printf '%s\n' 'backend#' 'RFC-0' 'dev-api\.tracebloc\.io' '[A-Za-z0-9._%+-]+@tracebloc\.io'
    printf '\n[allow]\n'
    printf '%s\n' 'support@tracebloc\.io'
  } >"$SRC/.publish-forbidden"
}
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
  [[ "$output" == *"[forbidden-strings] clean (4 needle(s), 1 allow token(s); 7 text file(s) scanned, 0 binary"* ]] || return 1
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
  printf '[paths]\nscripts/tests/\n[strings]\nbackend#\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forbidden path pattern 'scripts/tests/' matched:"* ]] || return 1
  [[ "$output" == *"tree:scripts/tests/a.bats"* ]] || return 1
  [[ "$output" != *"tree:other/scripts/tests/b.bats"* ]] || return 1   # anchored: not this one
  # The unanchored form reaches it.
  rm -rf "$OUT"
  printf '[paths]\ntests/\n[strings]\nbackend#\n' >"$SRC/.publish-forbidden"
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
  printf '[strings]\nbackend#\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[forbidden-paths] COULD NOT TELL — '"*"' has no [paths] entries"* ]] || return 1
}

# ── guard 3: forbidden strings ────────────────────────────────────────────────

@test "mutation: an internal tracker reference in a staged file is refused, file and line named" {
  plant README.md 'see backend#1234 for the rationale'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-strings] REFUSED — needle 'backend#' found in 1 staged line(s):"* ]] || return 1
  [[ "$output" == *"    tree/README.md:2"* ]] || return 1
  # The matched text itself is never echoed.
  [[ "$output" != *"for the rationale"* ]] || return 1
}

@test "mutation: a non-production hostname in a staged file is refused" {
  plant client/Chart.yaml '# points at dev-api.tracebloc.io'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"needle 'dev-api\.tracebloc\.io' found in 1 staged line(s):"*"tree/client/Chart.yaml:2"* ]] || return 1
}

@test "needles match case-insensitively" {
  plant README.md 'BACKEND#7'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"needle 'backend#' found in 1 staged line(s)"* ]] || return 1
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
  [[ "$output" == *"needle '[A-Za-z0-9._%+-]+@tracebloc\.io' found in 1 staged line(s):"*"tree/README.md:2"* ]] || return 1
}

@test "mutation: a private needle supplied with --extra-forbidden is enforced" {
  printf '# private list\nplanted-tenant\n' >"$BATS_TEST_TMPDIR/tenants.txt"
  plant client/templates/deploy.yaml '# for Planted-Tenant only'
  guard --extra-forbidden "$BATS_TEST_TMPDIR/tenants.txt"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"needle 'planted-tenant' found in 1 staged line(s):"*"tree/client/templates/deploy.yaml:2"* ]] || return 1
  [[ "$output" == *"[forbidden-strings] 1 hit(s) across 5 needle(s)"* ]] || return 1
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

@test "an internal reference inside a release asset is refused with the asset named" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  printf '#!/bin/sh\n# see backend#42\n' >"$BATS_TEST_TMPDIR/assets/install.sh"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[assets] staged 1 release asset(s):"*"    install.sh"* ]] || return 1
  [[ "$output" == *"needle 'backend#' found in 1 staged line(s):"*"assets/install.sh:2"* ]] || return 1
}

@test "a binary asset is opaque to the string scan and counted as such" {
  mkdir -p "$BATS_TEST_TMPDIR/assets"
  printf 'ELF\000\000backend#1\000' >"$BATS_TEST_TMPDIR/assets/tracebloc-linux-amd64"
  guard --assets "$BATS_TEST_TMPDIR/assets"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"7 text file(s) scanned, 1 binary file(s) opaque to this scan"* ]] || return 1
}

@test "no [strings] entries is could-not-tell, not clean" {
  printf '[paths]\ntests/\n' >"$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"[forbidden-strings] COULD NOT TELL — '"*"' has no [strings] entries"* ]] || return 1
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

@test "the committed .publish-forbidden refuses an internal reference planted in a fixture" {
  cp "$REPO/.publish-forbidden" "$SRC/.publish-forbidden"
  plant README.md 'rationale in backend#1'
  guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"needle 'backend#' found in 1 staged line(s):"*"tree/README.md:2"* ]] || return 1
}

@test "the committed .publish-forbidden refuses a non-production hostname and spares the support mailbox" {
  cp "$REPO/.publish-forbidden" "$SRC/.publish-forbidden"
  guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }    # README's support@tracebloc.io is allowed
  rm -rf "$OUT"
  plant scripts/lib/common.sh 'API=https://stg-api.tracebloc.io/'
  guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"needle 'stg-api\.tracebloc\.io' found in 1 staged line(s):"*"tree/scripts/lib/common.sh:2"* ]] || return 1
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
  # Not asserted clean: the strings scan has a known backlog in the chart and
  # installer comments (internal tracker references) that is tracked separately;
  # what this test pins is that the allowlist and path rules hold on the real
  # tree and that the guard could evaluate it.
  [ "$status" -le 1 ] || { echo "$output"; return 1; }
  [[ "$output" != *"COULD NOT TELL"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"[forbidden-paths] clean"* ]] || { echo "$output"; return 1; }
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
