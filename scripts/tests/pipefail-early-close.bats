#!/usr/bin/env bats
# The '| head under pipefail' hazard, encoded (backend#1778).
#
# WHY THIS EXISTS
# ---------------
# Under `set -o pipefail` + `set -e`, a `producer | head -n N` diagnostic aborts
# its own caller once the producer outgrows the ~64KB pipe buffer: head closes
# the pipe, the producer takes SIGPIPE, the pipeline returns 141, errexit kills
# the script. It is size-dependent, so it survives review — measured on the
# client#656 case, 50 lines exit 1 and 20k exit 141.
#
# The repo had already converted every instance by hand and documented the idiom
# in seven places. Prose is not a gate: the org standard is "if a rule matters,
# encode it", and this rule has now cost two incidents (client#656, client#678).
# So the audit's lasting deliverable is this scanner, not another sweep.
#
# ONE IMPLEMENTATION, shared by the gate and its own self-tests
# (pipefail-early-close.awk) — never an inline copy of the rule. An inline copy
# drifts from the real scanner and then proves that a regex nobody runs would
# have caught the bug (backend#1729 rule 9).

setup() {
  SCANNER="${BATS_TEST_DIRNAME}/pipefail-early-close.awk"
  GATE="${BATS_TEST_DIRNAME}/pipefail-early-close.sh"
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/pfhead.XXXXXX")"
}

teardown() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  return 0
}

scan() { awk -f "$SCANNER" "$@"; }

# Write a file that DOES enable both options, i.e. the hazardous context.
hazardous() {
  local f="$WORK/$1"; shift
  { printf '#!/usr/bin/env bash\nset -euo pipefail\n'; printf '%s\n' "$@"; } > "$f"
  printf '%s' "$f"
}

# ── the gate ─────────────────────────────────────────────────────────────────

@test "no shell script in the tree pipes into an early-closing reader under errexit+pipefail" {
  # Through the GATE, not a private find: scripts/sh-files.sh is the repo's one
  # definition of "which files are shell" (extension, else shebang), and a
  # hand-rolled `find scripts docs -name '*.sh'` silently skipped
  # docker/k3s-cuda/build.sh -- which sets `set -euo pipefail` and converted a
  # `grep | head` for this very ticket -- plus every `.bash` file (Bugbot #763).
  local offenders
  offenders="$(bash "$GATE")"
  if [ -n "$offenders" ]; then
    printf 'offenders:\n%s\n' "$offenders" >&2
  fi
  [ -z "$offenders" ] || return 1
}

@test "the gate reads the repo's own sh-files derivation, so docker/ and .bash are in scope" {
  # This must exercise the GATE's scope, not sh-files.sh's output: asserting what
  # sh-files.sh prints passes just as well when the gate ignores it and rolls its
  # own find (found by mutation -- the first version of this test was vacuous).
  # So: plant an offender OUTSIDE `scripts/` and `docs/` and require the gate to
  # find it. sh-files.sh reads `git ls-files`, hence the real git fixture.
  mkdir -p "$WORK/repo/scripts/tests" "$WORK/repo/docker/img"
  cp "$SCANNER" "$GATE" "$WORK/repo/scripts/tests/"
  cp "$REPO/scripts/sh-files.sh" "$WORK/repo/scripts/"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nls /tmp | head -1\n' > "$WORK/repo/docker/img/build.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nls /tmp | head -1\n' > "$WORK/repo/scripts/helper.bash"
  git -C "$WORK/repo" init -q
  git -C "$WORK/repo" add -A
  run bash "$WORK/repo/scripts/tests/pipefail-early-close.sh"
  [[ "$output" == *"docker/img/build.sh"* ]] || return 1
  [[ "$output" == *"helper.bash"* ]] || return 1
}

@test "a lib that INHERITS errexit+pipefail from its sourcer is in scope (Bugbot #763)" {
  # scripts/lib/*.sh set neither option -- install.sh does, and sources them. An
  # own-`set`-lines-only rule reads the entire installer as safe, so a reverted
  # `helm repo list | grep -q` stays green while the `if` misbranches. This is
  # the finding that made the wrapper necessary.
  mkdir -p "$WORK/scripts/lib" "$WORK/scripts/tests"
  cp "$SCANNER" "$WORK/scripts/tests/"
  cp "$GATE" "$WORK/scripts/tests/"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "${LIB_DIR}/thing.sh"\n' > "$WORK/scripts/main.sh"
  printf 'thing() {\n  helm repo list | grep -q tracebloc\n}\n' > "$WORK/scripts/lib/thing.sh"
  run bash "$WORK/scripts/tests/pipefail-early-close.sh" \
      "$WORK/scripts/main.sh" "$WORK/scripts/lib/thing.sh"
  [[ "$output" == *"thing.sh"* ]] || return 1
}

@test "a lib nobody hazardous sources is NOT dragged in (inheritance is not 'everything')" {
  mkdir -p "$WORK/scripts/lib" "$WORK/scripts/tests"
  cp "$SCANNER" "$WORK/scripts/tests/"
  cp "$GATE" "$WORK/scripts/tests/"
  printf '#!/usr/bin/env bash\nset -uo pipefail\nsource "${LIB_DIR}/lonely.sh"\n' > "$WORK/scripts/caller.sh"
  printf 'lonely() {\n  producer | grep -q needle\n}\n' > "$WORK/scripts/lib/lonely.sh"
  run bash "$WORK/scripts/tests/pipefail-early-close.sh" \
      "$WORK/scripts/caller.sh" "$WORK/scripts/lib/lonely.sh"
  [ -z "$output" ] || return 1
}

# ── the scanner is not vacuous ───────────────────────────────────────────────
# Every "spares X" test below is only meaningful if the scanner catches the
# equivalent unspared line. That is what this pair establishes.

@test "it FLAGS a pipe into head in an errexit+pipefail file" {
  local f; f="$(hazardous bad.sh '  local x; x="$(ls /tmp | head -1)"')"
  run scan "$f"
  [ -n "$output" ] || return 1
  [[ "$output" == *"bad.sh:3"* ]] || return 1
}

@test "it FLAGS a pipe into grep -q (the same early close, different reader)" {
  local f; f="$(hazardous badq.sh '  producer | grep -q needle')"
  run scan "$f"
  [ -n "$output" ] || return 1
}

@test "it FLAGS a pipe into grep -m N (closes after N matches — found in the wild here)" {
  # e2e-auto-upgrade.sh had `kubectl get deploy -o name | grep -m1 'jobs-manager'`
  # two lines below a -q instance. Same mechanism, and the first sweep of this
  # ticket missed it because the ticket's list only named `head`.
  local f; f="$(hazardous badm.sh '  kubectl get deploy -o name | grep -m1 needle')"
  run scan "$f"
  [ -n "$output" ] || return 1
}

@test "it does NOT flag a grep that reads to EOF (-m is the closer, not grep itself)" {
  # Discrimination: without -q/-m, grep consumes all input and never SIGPIPEs
  # the producer. Flagging every `| grep` would make the gate unusable noise.
  local f; f="$(hazardous plaingrep.sh '  producer | grep needle | sed s/a/b/')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares the here-string idiom the house uses instead" {
  local f; f="$(hazardous good.sh \
    '  out="$(producer || true)"' \
    '  head -25 <<<"$out"')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares capture-then-slice (pure-bash first line)" {
  local f; f="$(hazardous slice.sh \
    '  out="$(producer)"' \
    '  first="${out%%$'"'"'\n'"'"'*}"')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares a line whose status is already discarded with || true" {
  local f; f="$(hazardous ortrue.sh '  ver="$(tool --version | head -1 || true)"')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares comments — prose about the hazard is not the hazard" {
  # Seven files in this repo document the rule in exactly this shape. If the
  # scanner flagged them, the gate would be permanently red on its own docs.
  local f; f="$(hazardous comment.sh '  # NOT `producer | head -1`: head closes the pipe')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares a file that enables pipefail but NOT errexit" {
  # Both are required for the abort. pipefail alone returns 141 and nothing acts
  # on it. This is why check-drift.sh's `ls | head -1` is not a finding.
  local f="$WORK/nopipe.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n  x="$(ls /tmp | head -1)"\n' > "$f"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it spares a file that enables errexit but NOT pipefail" {
  local f="$WORK/noeo.sh"
  printf '#!/usr/bin/env bash\nset -eu\n  x="$(ls /tmp | head -1)"\n' > "$f"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "it sees options set inside a function, not just at the top" {
  # check-drift.sh puts `set -uo pipefail` inside main() so the file stays
  # side-effect-safe to source. A top-of-file-only check would miss that shape.
  local f="$WORK/infunc.sh"
  printf '#!/usr/bin/env bash\nmain() {\n  set -euo pipefail\n  x="$(ls /tmp | head -1)"\n}\n' > "$f"
  run scan "$f"
  [ -n "$output" ] || return 1
}

@test "the '# pipefail-guard: allow' marker opts a line out" {
  local f; f="$(hazardous allow.sh '  x="$(ls /tmp | head -1)"   # pipefail-guard: allow')"
  run scan "$f"
  [ -z "$output" ] || return 1
}

@test "state does not leak between files (a clean file after a dirty one stays clean)" {
  # The scanner buffers per file and flushes on transition. A leak here would
  # blame the wrong file, which is worse than missing it.
  local bad good
  bad="$(hazardous a-bad.sh '  x="$(ls /tmp | head -1)"')"
  good="$WORK/b-good.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n  x="$(ls /tmp | head -1)"\n' > "$good"
  run scan "$bad" "$good"
  [[ "$output" == *"a-bad.sh"* ]] || return 1
  [[ "$output" != *"b-good.sh"* ]] || return 1
}
