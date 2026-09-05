#!/usr/bin/env bats
# workflow-bounded-docker-run.sh (#986): every `docker run` in installer-tests.yaml
# must be wrapped in `timeout`, so a mirror stall inside the container fails the
# step with a readable log instead of running to the job cap and reading as
# `cancelled`. These tests run the REAL guard: once against the live workflow, and
# once against a COPY with one wrapper removed, so the guard is proven to redden on
# the exact defect it was written for (rule 9: the mutation calls the code under
# test, not a re-implementation of it). Each refusal asserts its SPECIFIC message,
# never a bare non-zero exit (rule 10).
load test_helper

setup() {
  GUARD="${SCRIPTS_DIR}/tests/workflow-bounded-docker-run.sh"
  REAL="${SCRIPTS_DIR}/../.github/workflows/installer-tests.yaml"
  COPY="$BATS_TEST_TMPDIR/installer-tests.yaml"
  cp "$REAL" "$COPY"
}

@test "the live workflow has every docker run bounded" {
  run "$GUARD" "$REAL"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"docker run invocation(s) in installer-tests.yaml are bounded by timeout"* ]] || return 1
}

@test "the live workflow has more than one docker run to bound (the guard is not vacuous)" {
  # Two jobs carry a container run (Prereqs, PATH persist). If this ever reads 0
  # or 1, either a job was removed or the grep stopped seeing them - both are
  # worth a human look, not a silent pass.
  n="$(grep -cE '^[[:space:]]*timeout .*docker run' "$REAL")"
  [ "$n" -ge 2 ] || return 1
}

@test "removing one timeout wrapper reddens the guard and names the line" {
  # Mutate the COPY: strip the wrapper from the first bounded docker run only.
  # The mutation must actually apply - an inert mutation and good coverage look
  # identical in a log (rule 5).
  before="$(grep -cE '^[[:space:]]*timeout .*docker run' "$COPY")"
  # awk, not GNU sed's `0,/re/`: the same test must run on macOS bash/BSD sed.
  awk 'done==0 && /^[[:space:]]*timeout [^ ]+ [^ ]+ docker run/ { sub(/timeout [^ ]+ [^ ]+ docker run/, "docker run"); done=1 } { print }' \
    "$COPY" > "$COPY.mut" && mv "$COPY.mut" "$COPY"
  after="$(grep -cE '^[[:space:]]*timeout .*docker run' "$COPY")"
  [ "$after" -eq $((before - 1)) ] || return 1

  run "$GUARD" "$COPY"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"FAIL: unbounded docker run at"* ]] || return 1
  [[ "$output" == *"wrap it in \`timeout\`"* ]] || return 1
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
