#!/usr/bin/env bats
# wait-for-ingest-pod.bats — behavioural guard for
# docs/migration-tools/wait-for-ingest-pod.sh (backend#2881, client#924).
#
# The script gates a `DROP`: two of the readiness gate's criteria read the
# ingestion identity from a LIVE pod, so this wait must hand off ONLY once the
# real ingestion Job pod is Running — never on the file-staging pod, and never on
# a control-plane pod. Trap 1 (the stage pod) was once a WRITTEN guarantee that
# turned out to be name-dependent: a table named `ingest_test` yields
# `tracebloc-stage-ingest-test-<hex>`, which a `/ingest/` SUBSTRING matched, so the
# wait handed off to file-staging (LukasWodka, client#924). The picker now anchors
# on `^ingest-job-`; the negative case below — "must NOT fire on
# tracebloc-stage-ingest-*" — is the check that would have caught the original
# bug, kept machine-enforced rather than as prose (rule 7).

setup() {
  SUT="${BATS_TEST_DIRNAME}/../../docs/migration-tools/wait-for-ingest-pod.sh"
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  PODS="$TMP/pods"; : >"$PODS"                    # the poll's pod list (custom-columns view)
  NAMEOK="$TMP/nameok"; printf '9999\n' >"$NAMEOK" # how many `-o name` calls succeed
  NCALL="$TMP/ncall"; printf '0\n' >"$NCALL"

  # A fake kubectl driven entirely by the three files above, so a test controls
  # what it sees: the `-o name` view (preflight + timeout re-probe) succeeds for
  # the first $NAMEOK calls then fails; the custom-columns view (the poll itself)
  # prints whatever pods $PODS holds.
  cat >"$BIN/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in *" get pods "*) ;; *) exit 0 ;; esac
case " \$* " in
  *"-o name"*)
    n=\$(cat "$NCALL"); n=\$((n + 1)); printf '%s\n' "\$n" >"$NCALL"
    if [ "\$n" -le "\$(cat "$NAMEOK")" ]; then printf 'pod/x\n'; exit 0
    else printf 'error: You must be logged in to the server (Unauthorized)\n' >&2; exit 1; fi ;;
esac
cat "$PODS"
EOF
  chmod +x "$BIN/kubectl"
  PATH="$BIN:$PATH"
}

teardown() { rm -rf "$TMP"; }

# Run the SUT with a fast poll and a short fail-closed window.
wait_run() { run bash "$SUT" --context ctx --namespace ns --interval 0.05 --timeout 1 "$@"; }

@test "catches a Running ingestion Job pod (else every negative case below is vacuous)" {
  printf 'ingest-job-5a3907a66777-fc285 Running\n' >"$PODS"
  wait_run
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ingest-job-5a3907a66777-fc285"* ]] || return 1
}

@test "must NOT fire on the file-staging pod even when the table name contains 'ingest'" {
  # The exact hole: `tracebloc-stage-ingest-test-<hex>` is Running BEFORE any
  # ingest-job exists. A substring `/ingest/` matched it; `^ingest-job-` does not.
  {
    printf 'tracebloc-stage-ingest-test-a1b2c3d4 Running\n'
    printf 'tracebloc-jobs-manager-abc Running\n'
    printf 'mysql-0 Running\n'
  } >"$PODS"
  wait_run
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no Running ingestion pod"* ]] || return 1
  [[ "$output" != *"tracebloc-stage-ingest-test"* ]] || return 1
}

@test "must NOT fire on a control-plane pod on a release named '…ingest…'" {
  # On a release `tracebloc-ingest`, egress-proxy / telemetry-collector / … all
  # carry the substring and are permanently Running; anchoring excludes them.
  {
    printf 'tracebloc-ingest-egress-proxy-77d Running\n'
    printf 'tracebloc-ingest-telemetry-collector-99f Running\n'
  } >"$PODS"
  wait_run
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no Running ingestion pod"* ]] || return 1
}

@test "ignores a finished (Succeeded) ingest-job from an earlier cycle" {
  printf 'ingest-job-oldcycle-1111 Succeeded\n' >"$PODS"
  wait_run
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no Running ingestion pod"* ]] || return 1
}

@test "a flag given without its value dies WITH a message and exit 2, not a bare exit 1" {
  run bash "$SUT" --context ctx --namespace
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"--namespace needs a value"* ]] || return 1
}

@test "a broken context at preflight fails immediately, not after the timeout" {
  printf '0\n' >"$NAMEOK"   # even the first `-o name` (preflight) call fails
  wait_run
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"cannot list pods"* ]] || return 1
}

@test "kubectl breaking AFTER the preflight is reported as blind, not as 'never started'" {
  printf '1\n' >"$NAMEOK"   # preflight ok; the timeout re-probe fails
  : >"$PODS"                # no ingestion pod ever appears
  wait_run
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"went blind"* ]] || return 1
  [[ "$output" != *"was not started"* ]] || return 1
}

@test "--exec fuses in-process and propagates the handed-off command's exit code" {
  printf 'ingest-job-5a3907a66777-fc285 Running\n' >"$PODS"
  run bash "$SUT" --context ctx --namespace ns --interval 0.05 --timeout 1 --exec -- bash -c 'exit 7'
  [ "$status" -eq 7 ] || return 1
}

@test "--help prints the header and stops before code (no set -euo leaks)" {
  run bash "$SUT" --help
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"USAGE"* ]] || return 1
  [[ "$output" != *"set -euo pipefail"* ]] || return 1
}
