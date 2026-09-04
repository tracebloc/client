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
  # The bundle's `docker info` is now bounded via _bounded, which runs
  # `timeout … docker info` as an EXTERNAL process when timeout is present — and
  # the collection test sets has(){ return 0; }. An external timeout can't see the
  # docker() shell-function mock, so shadow timeout/gtimeout with a passthrough
  # that drops the duration and still invokes the mock (the #741 trap; same fix as
  # probe.bats). Tests that need the real deadline can override these locally.
  timeout()  { shift; "$@"; }
  gtimeout() { shift; "$@"; }
}

# ── _redact_file (security) ─────────────────────────────────────────────────
@test "_redact_file: clientPassword redacted, clientId kept" {
  f="$BATS_TEST_TMPDIR/v.yaml"
  printf 'clientId: "abc-123"\nclientPassword: '\''S3cr3tP@ss'\''\n' > "$f"
  _redact_file "$f"
  ! grep -q 'S3cr3tP@ss' "$f" || return 1
  grep -q 'clientPassword: \[REDACTED\]' "$f"
  grep -q 'abc-123' "$f"
}

@test "_redact_file: proxy credentials redacted" {
  f="$BATS_TEST_TMPDIR/p.txt"
  echo 'HTTP_PROXY=http://user:s3cr3t@proxy.corp:8080' > "$f"
  _redact_file "$f"
  ! grep -q 's3cr3t' "$f" || return 1
  grep -q 'http://\[REDACTED\]@proxy.corp:8080' "$f"
}

@test "_redact_file: password= and token/secret redacted" {
  f="$BATS_TEST_TMPDIR/l.txt"
  printf 'POST password=hunter2&x=1\ntoken: ghp_SECRETTOKEN\n' > "$f"
  _redact_file "$f"
  ! grep -q 'hunter2' "$f" || return 1
  ! grep -q 'ghp_SECRETTOKEN' "$f" || return 1
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
  ! grep -q 'dckr_REGTOKEN' "$f" || return 1
  ! grep -q 'PROXYPW123' "$f" || return 1
  ! grep -q 'ROOTPW123' "$f" || return 1
}

@test "_redact_file: missing file is a no-op (no error)" {
  run _redact_file "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -eq 0 ] || return 1
}

# ── run_diagnose (end-to-end, the headline security proof) ──────────────────
@test "run_diagnose: produces a bundle, and a seeded secret does NOT survive in it" {
  echo "clientPassword: 'LEAKME123'" > "$HOST_DATA_DIR/values.yaml"
  echo "installer log line" > "$HOST_DATA_DIR/install-20260101-000000.log"
  has() { return 1; }                  # no kubectl/docker/helm -> best-effort path
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Diagnostics saved"* ]] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  # extract to stdout and confirm the secret was redacted before archiving
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'LEAKME123' || return 1
  # but the bundle still contains useful content (the host section)
  tar -tzf "$tgz" 2>/dev/null | grep -q '00-host.txt'
}

@test "run_diagnose: best-effort with no cluster (does not crash)" {
  has() { return 1; }
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Diagnostics saved"* ]] || return 1
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
  [ "$status" -eq 0 ] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  # the kubectl + helm + per-workload-log collection branches ran
  tar -tzf "$tgz" | grep -q '02-kubectl.txt'
  tar -tzf "$tgz" | grep -q '04-helm.txt'
  tar -tzf "$tgz" | grep -q 'logs/mysql-client.log'
  # Finding 2 (security review): `helm get manifest` (base64 Secrets) is NOT collected
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'get manifest' || return 1
}

# ── the k3d listing in the bundle is bounded, and says so (client#974) ───────
# The worst of #974's seven sites. The bundle is collected BECAUSE the machine is
# already broken, so a wedged Docker engine is the EXPECTED input here, not a
# hypothetical one — and `{ … } > 01-docker.txt` waits for the whole group, so one
# unbounded read meant no bundle at all from the one run where the bundle is the
# entire point. (Its PowerShell twin was a Bugbot High on client#917 for this.)
#
# Both bounds are driven, because `_bounded` alone is a NO-OP on a stock Mac (no
# timeout/gtimeout — both are GNU coreutils) and --diagnose is Darwin-reachable.

@test "run_diagnose: a live k3d listing lands in the bundle (the happy path still collects)" {
  has() { return 0; }
  docker() { printf 'docker %s\n' "$*"; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { printf 'tracebloc 1/1 1/1 true\n'; }
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'tracebloc 1/1 1/1 true' || return 1
}

# THE GUARD FOR THE FINDING THAT RE-OPENED THIS (Bugbot High + LukasWodka,
# client#984). The first cut gated only the `k3d cluster list` — and left a bare
# `docker ps -a` as the FIRST command of the same `{ … } > 01-docker.txt` group,
# two lines above the gate. On the wedged daemon this section exists for, the
# group blocked at that line, never reached the gate, and the file was never
# written. The gate has to be on the GROUP, and the assertion has to be that NO
# daemon call is reached — not that one particular call is bounded.
@test "run_diagnose: a wedged daemon reaches NO docker call at all, and the bundle is still written" {
  has() { return 0; }
  _docker_answers_bounded() { return 124; }        # the daemon never answers
  # Any docker invocation at all is a finding: on a real wedged engine this mock
  # stands in for a call that would never return.
  docker() { echo "DOCKER-CALLED: $*" >> "$BATS_TEST_TMPDIR/docker-calls"; return 0; }
  k3d() { echo "k3d $*"; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -f "$BATS_TEST_TMPDIR/docker-calls" ] || {
    echo "reached a docker call past the liveness gate — on a real wedged engine that call never returns and the bundle is lost:"
    cat "$BATS_TEST_TMPDIR/docker-calls"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || { echo "no bundle written"; return 1; }
  # and BOTH groups that read the daemon are present, each saying why
  tar -tzf "$tgz" 2>/dev/null | grep -q '00-host.txt'   || return 1
  tar -tzf "$tgz" 2>/dev/null | grep -q '01-docker.txt' || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'NOT COLLECTED' || {
    echo "the bundle is silent about why the docker section is missing"; return 1; }
}

@test "run_diagnose: with NO docker installed the bundle says so, not 'the daemon did not answer'" {
  # A support bundle that claims a daemon timed out on a host with no Docker is a
  # false statement about the machine — the same class of defect as the silence
  # this fix replaced, just louder.
  has() { return 1; }                              # nothing installed
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'docker is not installed on this host' || {
    echo "did not say docker is absent"; return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'daemon did not answer' || {
    echo "claimed the daemon timed out on a host with no docker"; return 1; }
}

@test "run_diagnose: with a live daemon EVERY docker section is still collected (the gate is not a mute button)" {
  # The other half. Without this, the test above passes just as well against a
  # run_diagnose that never collects docker state at all.
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  # `docker info` is piped through a `grep -iE 'Server Version|…'` field filter, so
  # its mock has to emit a line that filter keeps — otherwise this test would pass
  # for the wrong reason on a run that collected nothing.
  docker() {
    case "$*" in
      info*) printf 'docker-said info\n Server Version: 27.0.0\n' ;;
      *)     printf 'docker-said %s\n' "$*" ;;
    esac
  }
  k3d() { echo "k3d $*"; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'docker-said version'   || { echo "00-host lost its docker version read"; return 1; }
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'Server Version: 27.0.0' || { echo "00-host lost its docker info read"; return 1; }
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'docker-said ps -a'     || { echo "01-docker lost its container listing"; return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'NOT COLLECTED'       || { echo "claimed nothing was collected on a LIVE daemon"; return 1; }
}

# The per-file half of check-style.sh rule 5, asserted against this file with a
# CENSUS, because rule 5 is a text scan over scripts/lib/ and a text scan that
# stops matching prints as clean as one that checked everything. Here the count is
# the point: this file is where an unbounded daemon read costs the whole artifact.
@test "every daemon read in diagnose.sh uses the CORE-UTILS-FREE reader, and there are as many as we think" {
  # The per-file half of check-style rule 5, with two things the rule cannot say.
  #
  # (a) THE CENSUS. Rule 5 is a text scan and a text scan that stops matching
  #     prints as clean as one that checked everything. Here the count is the
  #     point: this file is where an unbounded daemon read costs the whole
  #     artifact, not a stall.
  # (b) `_bounded` IS NOT ENOUGH IN THIS FILE. --diagnose is Darwin-reachable and
  #     `_bounded` is a documented no-op without coreutils, so every read here must
  #     go through `_bounded_capture`, whose deadline comes from the child PID
  #     (Bugbot High, client#984). Rule 5 accepts either, correctly — it governs
  #     the whole tree. This file is stricter.
  #
  # The invocation regex is DERIVED from check-style.sh's own rule 5 rather than
  # restated: a second copy would agree with itself while the rule drifted, and it
  # would also count this file's timeout NOTES as if they were calls.
  local f="$BATS_TEST_DIRNAME/../lib/diagnose.sh" cs="$BATS_TEST_DIRNAME/../check-style.sh"
  local re calls n bad
  re="$(grep -m1 '^docker_probe=' "$cs")" || return 1
  re="${re#docker_probe=\'}"; re="${re%\'}"
  [ -n "$re" ] || return 1
  calls="$(grep -nE "$re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  n="$(printf '%s\n' "$calls" | grep -c . || true)"
  [ "$n" -ge 5 ] || {
    echo "expected at least 5 docker reads in diagnose.sh, found $n — the scan or the file has changed shape:"
    printf '%s\n' "$calls"; return 1; }
  bad="$(printf '%s\n' "$calls" | grep -vE '_bounded_capture[[:space:]]+"[^"]*"[[:space:]]+"\$_cap"[[:space:]]+docker' || true)"
  [ -z "$bad" ] || {
    echo "daemon read(s) in diagnose.sh not routed through _bounded_capture — on a stock Mac these are unbounded, and one that never returns means no bundle at all:"
    printf '%s\n' "$bad"; return 1; }
}

@test "run_diagnose: a daemon that never answers SKIPS the k3d read, with a note, and still writes a bundle" {
  # The coreutils-free gate (_docker_answers_bounded, #744) — the half that holds
  # on a stock Mac. A non-answer must leave an attributable line, because silence
  # in this file reads as "the machine has no clusters".
  has() { return 0; }
  docker() { printf 'docker %s\n' "$*"; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  _docker_answers_bounded() { return 124; }
  # `cluster list` only: the bundle's other k3d call is `k3d version`, a local read
  # that never touches the engine and is deliberately outside #974's scope.
  k3d() { case "$*" in *"cluster list"*) echo "K3D-LIST-WAS-CALLED" ;; *) echo "k3d $*" ;; esac; }
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'would have hung this bundle' || return 1
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'K3D-LIST-WAS-CALLED' || return 1
}

@test "run_diagnose: a k3d read that times out leaves a named finding, not a blank section" {
  # The daemon answers `docker info` but the k3d listing still stalls — a reachable
  # state, because the gate's budget and this read's budget are different
  # (TB_DOCKER_PROBE_TIMEOUT 10s vs TB_K3D_LIST_TIMEOUT 15s). "did not complete" IS
  # the finding support needs; an empty section would read as "no clusters here".
  has() { return 0; }
  docker() { printf 'docker %s\n' "$*"; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  _docker_answers_bounded() { return 0; }
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    case "$*" in
      *"cluster list"*) : > "$out"; return 124 ;;      # the deadline fires
      *)                printf 'ok\n' > "$out"; return 0 ;;
    esac
  }
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'k3d cluster listing did not complete' || return 1
}

@test "run_diagnose: surfaces + records the client version" {
  has() { case "$1" in helm) return 0 ;; *) return 1 ;; esac; }   # only helm present
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run run_diagnose
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"client version: 1.4.4"* ]] || return 1
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'CLIENT VERSION: 1.4.4'
}
