#!/usr/bin/env bats
# Tests for scripts/lib/diagnose.sh — the --diagnose support bundle.
# The redaction tests are the SECURITY GATE: a known secret must never survive
# into the bundle the customer sends to support.
load test_helper

setup() {
  load_lib diagnose.sh
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/tb"
  CLUSTER_NAME=tracebloc
  mkdir -p "$HOST_DATA_DIR"
}

# ── _redact_file (security) ─────────────────────────────────────────────────
@test "_redact_file: clientPassword redacted, clientId kept" {
  f="$BATS_TEST_TMPDIR/v.yaml"
  printf 'clientId: "abc-123"\nclientPassword: '\''S3cr3tP@ss'\''\n' > "$f"
  _redact_file "$f"
  ! grep -q 'S3cr3tP@ss' "$f"
  grep -q 'clientPassword: \[REDACTED\]' "$f"
  grep -q 'abc-123' "$f"
}

@test "_redact_file: proxy credentials redacted" {
  f="$BATS_TEST_TMPDIR/p.txt"
  echo 'HTTP_PROXY=http://user:s3cr3t@proxy.corp:8080' > "$f"
  _redact_file "$f"
  ! grep -q 's3cr3t' "$f"
  grep -q 'http://\[REDACTED\]@proxy.corp:8080' "$f"
}

@test "_redact_file: password= and token/secret redacted" {
  f="$BATS_TEST_TMPDIR/l.txt"
  printf 'POST password=hunter2&x=1\ntoken: ghp_SECRETTOKEN\n' > "$f"
  _redact_file "$f"
  ! grep -q 'hunter2' "$f"
  ! grep -q 'ghp_SECRETTOKEN' "$f"
}

@test "_redact_file: non-secret content left intact" {
  f="$BATS_TEST_TMPDIR/n.txt"
  echo 'NO_PROXY=localhost,127.0.0.1,.svc' > "$f"
  _redact_file "$f"
  grep -q '127.0.0.1,.svc' "$f"
}

# Finding 1 (security review): any *password key must be redacted, not just
# clientPassword — covers dockerRegistry password, HTTP_PROXY_PASSWORD, caps.
@test "_redact_file: redacts dockerRegistry/proxy/db password keys (: and =, any case)" {
  f="$BATS_TEST_TMPDIR/g.yaml"
  printf 'dockerRegistry:\n  password: dckr_REGTOKEN\nHTTP_PROXY_PASSWORD: PROXYPW123\nMYSQL_ROOT_PASSWORD=ROOTPW123\n' > "$f"
  _redact_file "$f"
  ! grep -q 'dckr_REGTOKEN' "$f"
  ! grep -q 'PROXYPW123' "$f"
  ! grep -q 'ROOTPW123' "$f"
}

@test "_redact_file: missing file is a no-op (no error)" {
  run _redact_file "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -eq 0 ]
}

# ── run_diagnose (end-to-end, the headline security proof) ──────────────────
@test "run_diagnose: produces a bundle, and a seeded secret does NOT survive in it" {
  echo "clientPassword: 'LEAKME123'" > "$HOST_DATA_DIR/values.yaml"
  echo "installer log line" > "$HOST_DATA_DIR/install-20260101-000000.log"
  has() { return 1; }                  # no kubectl/docker/helm -> best-effort path
  run run_diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Diagnostics saved"* ]]
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ]
  # extract to stdout and confirm the secret was redacted before archiving
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'LEAKME123'
  # but the bundle still contains useful content (the host section)
  tar -tzf "$tgz" 2>/dev/null | grep -q '00-host.txt'
}

@test "run_diagnose: best-effort with no cluster (does not crash)" {
  has() { return 1; }
  run run_diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Diagnostics saved"* ]]
}

@test "run_diagnose: exercises the cluster-data collection when tools are present" {
  has() { return 0; }                       # kubectl/docker/helm "present"
  kubectl() {
    case "$*" in
      *"get pods -A"*) printf 'default   default-jobs-manager-abc   1/1   Running\n' ;;
      *)               printf 'kubectl %s\n' "$*" ;;
    esac
  }
  docker() { printf 'docker %s\n' "$*"; }
  helm()   { printf 'helm %s\n' "$*"; }
  run run_diagnose
  [ "$status" -eq 0 ]
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ]
  # the kubectl + helm + per-workload-log collection branches ran
  tar -tzf "$tgz" | grep -q '02-kubectl.txt'
  tar -tzf "$tgz" | grep -q '04-helm.txt'
  tar -tzf "$tgz" | grep -q 'logs/mysql-client.log'
  # Finding 2 (security review): `helm get manifest` (base64 Secrets) is NOT collected
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'get manifest'
}

@test "run_diagnose: surfaces + records the client version" {
  has() { case "$1" in helm) return 0 ;; *) return 1 ;; esac; }   # only helm present
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run run_diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"client version: 1.4.4"* ]]
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ]
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'CLIENT VERSION: 1.4.4'
}
