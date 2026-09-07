#!/usr/bin/env bats
# bounded-docker-run.sh (client#986): the one place the bound-and-report logic
# lives. These tests run the REAL wrapper against real child processes, so the
# exit-code contract -- 124 when the child honours SIGTERM, 137 when PID 1 ignores
# it and --kill-after escalates -- is proven at runtime, not read off source text.
# (@saqlainsyed007 on client#988: a `124`-only check silently lost the annotation
# on exactly the stall case the wrapper exists for.) Every assertion ends in
# `|| return 1` (bats-hygiene.bats).
load test_helper

setup() {
  WRAP="${SCRIPTS_DIR}/tests/bounded-docker-run.sh"
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    HAVE_TIMEOUT=1
  else
    HAVE_TIMEOUT=0
  fi
}

@test "a command that finishes in time passes its own exit status through, with no annotation" {
  [ "$HAVE_TIMEOUT" -eq 1 ] || skip "no GNU timeout on this host"
  run "$WRAP" 10s "a quick command" bash -c 'echo ran; exit 0'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ran"* ]] || return 1
  [[ "$output" != *"::error::"* ]] || return 1
  run "$WRAP" 10s "a failing command" bash -c 'exit 3'
  [ "$status" -eq 3 ] || { echo "rc=$status"; return 1; }
  [[ "$output" != *"::error::"* ]] || return 1
}

@test "a child that honours SIGTERM: exit 124 and the annotation names the label and the bound" {
  [ "$HAVE_TIMEOUT" -eq 1 ] || skip "no GNU timeout on this host"
  TB_KILL_AFTER=5s run "$WRAP" 1s "prerequisite install in test:distro" bash -c 'sleep 30'
  [ "$status" -eq 124 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"::error::prerequisite install in test:distro exceeded the 1s step bound (timeout exit 124)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"Re-run this job"* ]] || return 1
}

@test "a child that IGNORES SIGTERM (a PID-1 shell): --kill-after escalates, exit 137, and the annotation STILL fires" {
  [ "$HAVE_TIMEOUT" -eq 1 ] || skip "no GNU timeout on this host"
  # `trap '' TERM` is what a shell running as a container's PID 1 does implicitly:
  # the kernel discards SIGTERM for PID 1 with no handler, so `timeout` never gets
  # its clean 124 and must SIGKILL. This is the likely path for a real stall.
  TB_KILL_AFTER=1s run "$WRAP" 1s "PATH-persist check in test:distro" bash -c 'trap "" TERM; sleep 30'
  [ "$status" -eq 137 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"::error::PATH-persist check in test:distro exceeded the 1s step bound (timeout exit 137)"* ]] || { echo "$output"; return 1; }
}

@test "no timeout binary on PATH: refuses (exit 2) rather than running unbounded" {
  # An empty PATH with only a shim dir that lacks timeout/gtimeout; bash and
  # command are builtins so the wrapper itself still runs.
  local shim; shim="$(mktemp -d)"
  ln -s "$(command -v bash)" "$shim/bash"
  PATH="$shim" run bash "$WRAP" 1s "anything" bash -c 'exit 0'
  rm -rf "$shim"
  [ "$status" -eq 2 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"no GNU timeout binary on PATH"* ]] || { echo "$output"; return 1; }
}

@test "too few arguments is a usage error, not an unbounded run" {
  run "$WRAP" 1s "label-only"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"usage:"* ]] || return 1
}
