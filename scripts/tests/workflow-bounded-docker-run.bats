#!/usr/bin/env bats
# workflow-bounded-docker-run.sh (#986): every `docker run` in installer-tests.yaml
# must go through scripts/tests/bounded-docker-run.sh, so a mirror stall inside
# the container fails the step with a readable log instead of running to the job
# cap and reading as `cancelled`. These tests run the REAL guard: against the
# live workflow, and against COPIES with the wrapper removed -- once on a
# single-line invocation and once on a backslash-continued one -- so the guard is
# proven to redden on the exact defect it was written for and proven NOT to
# redden on a bounded run that merely spans lines (rule 9: the mutation calls the
# code under test; @saqlainsyed007 on client#988 for the formatting hazard). Each
# refusal asserts its SPECIFIC message, never a bare non-zero exit (rule 10).
# Every assertion ends in `|| return 1` (bats-hygiene.bats).
load test_helper

setup() {
  GUARD="${SCRIPTS_DIR}/tests/workflow-bounded-docker-run.sh"
  REAL="${SCRIPTS_DIR}/../.github/workflows/installer-tests.yaml"
  COPY="$BATS_TEST_TMPDIR/installer-tests.yaml"
  cp "$REAL" "$COPY"
}

# Strip the wrapper from the first LOGICAL line that carries one, whatever its
# argument count or line layout: drop everything from the wrapper token up to
# (not including) `docker run`, across a trailing continuation. Prints the number
# of wrapper tokens removed so callers can assert the mutation applied (rule 5).
unwrap_first() {   # $1 = file
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
pat = re.compile(r'bash scripts/tests/bounded-docker-run\.sh[^\n]*?(?:\\\n[^\n]*?)*?(?=docker run)')
new, n = pat.subn('', s, count=1)
open(p, 'w').write(new)
print(n)
PY
}

@test "the live workflow has every docker run bounded through the wrapper" {
  run "$GUARD" "$REAL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"docker run invocation(s) in installer-tests.yaml are bounded through bounded-docker-run.sh"* ]] || { echo "$output"; return 1; }
}

@test "the live workflow has more than one docker run to bound (the guard is not vacuous)" {
  # Two jobs carry a container run (Prereqs, PATH persist). If this ever reads 0
  # or 1, either a job was removed or the grep stopped seeing them - both are
  # worth a human look, not a silent pass.
  n="$(grep -c 'bounded-docker-run.sh' "$REAL")"
  [ "$n" -ge 2 ] || { echo "wrapper invocations: $n"; return 1; }
}

@test "removing the wrapper from a run reddens the guard and names the line" {
  removed="$(unwrap_first "$COPY")"
  [ "$removed" -eq 1 ] || { echo "mutation removed $removed wrappers (inert)"; return 1; }
  run "$GUARD" "$COPY"
  [ "$status" -eq 1 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"FAIL: unbounded docker run at"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"route it through scripts/tests/bounded-docker-run.sh"* ]] || { echo "$output"; return 1; }
}

@test "a bounded run split across continuation lines PASSES; the same run unwrapped FAILS" {
  # Independent fixture, written down here rather than derived from the live
  # workflow, so the continuation contract is tested on its own terms.
  cat > "$COPY" <<'YAML'
jobs:
  a:
    steps:
      # a comment mentioning docker run must not count
      - run: |
          bash scripts/tests/bounded-docker-run.sh 12m "x" \
            docker run --rm img \
              cmd
YAML
  run "$GUARD" "$COPY"
  [ "$status" -eq 0 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"1 docker run invocation(s)"* ]] || { echo "$output"; return 1; }
  cat > "$COPY" <<'YAML'
jobs:
  a:
    steps:
      - run: |
          env FOO=bar \
            docker run --rm img \
              cmd
YAML
  run "$GUARD" "$COPY"
  [ "$status" -eq 1 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"unbounded docker run at"*":5"* ]] || { echo "$output"; return 1; }
}

@test "a workflow with no docker run at all is a finding, not a pass" {
  sed -i.bak '/docker run/d' "$COPY"
  run "$GUARD" "$COPY"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no docker run found"* ]] || return 1
}

@test "an unreadable workflow path is a finding, not a pass" {
  run "$GUARD" "$BATS_TEST_TMPDIR/does-not-exist.yaml"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"cannot read"* ]] || return 1
}
