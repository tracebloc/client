#!/usr/bin/env bats
# =============================================================================
#  e2e-proxy-probe.bats — the §A probe of e2e-proxy.sh must RIDE OUT the
#  cluster-DNS startup window, and must NOT ride out a real regression.
#
#  WHY THIS EXISTS (backend#2350). `E2E auth-proxy (squid)` failed twice in 30
#  develop runs, both times on the same named assertion:
#
#      ✖ App pod WITH the ingestion proxy env did NOT tunnel through the squid
#
#  The probe already carried retries meant to cover exactly that startup window,
#  and a comment above them asserted that `--retry-all-errors` covered the
#  "Could not resolve proxy" case. It did not. curl caches a FAILED name
#  resolution for the LIFE OF THE PROCESS, so a single curl's `--retry` re-uses
#  the failure instead of re-querying the resolver. Both failing runs show it —
#  nine attempts, eight of them answered from the cache:
#
#      * Could not resolve proxy: tb-egress-squid.default.svc.cluster.local
#      * Negative DNS entry
#      curl: (5) Could not resolve proxy: tb-egress-squid...
#
#  Confirmed A/B in curlimages/curl:latest (the image the pod runs), with the
#  proxy name made resolvable 4 s into the run: the one-process form failed all
#  9 attempts on the stale negative entry, while the fresh-process loop
#  re-resolved on the very next attempt. So the guard's documented protection
#  was inert and the whole check turned on a single resolver query issued about
#  a second after the pod started.
#
#  WHAT IS PINNED HERE. Not "the mutation" — the requirement, in both
#  directions (backend#1729 rule 6):
#    * a transient resolve failure must be re-attempted in a NEW process, and
#    * a call that SUCCEEDS WITHOUT TUNNELLING — the real #119 regression — must
#      end the probe on attempt 1, never be retried into a slow green.
#  The retried exit-code domain is written down here INDEPENDENTLY of the `case`
#  in the snippet, and both the retried and the not-retried codes are exercised
#  (rule 9 corollary: never test a list against itself).
#
#  These tests execute the SAME TEXT the pod runs — e2e_proxy_probe_snippet's
#  output — not a paraphrase of it (rule 9). `curl` is stubbed; nothing here
#  needs a cluster, a proxy or a network.
# =============================================================================

setup() {
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/lib/e2e-common.sh"
  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  : > "$STUB_DIR/calls"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# _stub_curl "<rc>:<yes|no>" …  — one spec per curl INVOCATION; the last spec
# repeats for every further invocation. `yes` makes that invocation print the
# line the real assertion greps for. Records one line per invocation, which is
# how these tests count PROCESSES rather than in-process retries.
_stub_curl() {
  printf '%s\n' "$@" > "$STUB_DIR/rcs"
  cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/sh
n=$(( $(wc -l < "$STUB_DIR/calls") + 1 ))
echo "invocation $n" >> "$STUB_DIR/calls"
total=$(wc -l < "$STUB_DIR/rcs")
pick=$n
[ "$pick" -gt "$total" ] && pick=$total
spec=$(sed -n "${pick}p" "$STUB_DIR/rcs")
[ "${spec##*:}" = yes ] && echo "* CONNECT tunnel established"
exit "${spec%%:*}"
STUB
  chmod +x "$STUB_DIR/curl"
}

_calls() { wc -l < "$STUB_DIR/calls" | tr -d ' '; }

_reset_stub() { : > "$STUB_DIR/calls"; }

# Run the REAL emitted snippet with the stub ahead of curl on PATH.
_run_probe() {   # <deadline_s> <delay_s>
  local snippet
  snippet="$(e2e_proxy_probe_snippet backend.example.test "$1" "$2")"
  PATH="$STUB_DIR:$PATH" run sh -c "$snippet"
}

@test "a transient resolve failure is re-attempted in a FRESH curl process until the tunnel appears" {
  _stub_curl "5:no" "5:no" "0:yes"
  _run_probe 30 0
  [ "$status" -eq 0 ] || return 1
  # Three separate curl PROCESSES is the whole point: curl caches a failed
  # resolve for the life of one process, so an in-process --retry cannot recover.
  [ "$(_calls)" = "3" ] || return 1
  [[ "$output" == *"CONNECT tunnel established"* ]] || return 1
  [[ "$output" == *"probe attempt 3 rc=0"* ]] || return 1
}

@test "a call that succeeds WITHOUT tunnelling ends the probe on attempt 1 (the #119 regression keeps its teeth)" {
  # Proxy env ignored: curl dials direct, succeeds, and no CONNECT is logged.
  # Retrying this would convert a real red into a slow green.
  _stub_curl "0:no"
  _run_probe 30 0
  [ "$(_calls)" = "1" ] || return 1
  [[ "$output" != *"CONNECT tunnel established"* ]] || return 1
  [[ "$output" == *"probe attempt 1 rc=0"* ]] || return 1
}

@test "exactly the startup-window exit codes are retried; every other curl outcome ends the probe" {
  # Written down here independently of the snippet's own `case`, and BOTH halves
  # of the domain are exercised — a list checked against itself proves nothing.
  local rc
  for rc in 5 6 7; do          # unresolvable proxy / host, refused connection
    _reset_stub
    _stub_curl "${rc}:no" "0:yes"
    _run_probe 30 0
    [ "$(_calls)" = "2" ] || { echo "curl exit $rc is a startup-window symptom and must be retried (calls=$(_calls))" >&2; return 1; }
  done
  for rc in 0 22 28 35 56 60; do   # success, HTTP error, timeout, TLS, recv, cert
    _reset_stub
    _stub_curl "${rc}:no" "0:yes"
    _run_probe 30 0
    [ "$(_calls)" = "1" ] || { echo "curl exit $rc is not a startup-window symptom and must NOT be retried (calls=$(_calls))" >&2; return 1; }
  done
}

@test "a proxy name that never resolves gives up at the deadline and says how long it waited" {
  # The old failure could not distinguish "did not tunnel" from "had not
  # tunnelled YET" — a negative satisfied by "not yet" as well as by "never".
  _stub_curl "5:no"
  _run_probe 2 1
  [[ "$output" == *"GAVE UP"* ]] || return 1
  [[ "$output" == *"elapsed="* ]] || return 1
  # It WAITED across several processes rather than sampling once.
  [ "$(_calls)" -ge 2 ] || return 1
  [[ "$output" != *"CONNECT tunnel established"* ]] || return 1
}

@test "the snippet refuses to render without a backend host, naming that reason" {
  # Fail closed: an empty host would probe https:/// and fail for a reason with
  # nothing to do with proxying — a red that means nothing.
  run e2e_proxy_probe_snippet ""
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"backend host is required"* ]] || return 1
}

@test "the probe lands INSIDE the pod manifest's args — the rendered YAML parses and carries it" {
  # Renders the REAL egress-app manifest out of e2e-proxy.sh, using the script's
  # OWN interpolation line, and parses it. The snippet is spliced into a YAML
  # literal block scalar, so an indent that stops agreeing with the block either
  # breaks the parse or silently drops the probe out of `args` — a pod that then
  # runs something other than the probe. Nothing about the layout is written
  # down here; it is all read from the file and from the parse.
  local script line_no start end block rendered assign
  script="${BATS_TEST_DIRNAME}/e2e-proxy.sh"
  line_no="$(grep -n 'name: egress-app' "$script" | head -1 | cut -d: -f1)"
  [ -n "$line_no" ] || return 1
  start="$(awk -v n="$line_no" 'NR<n && /<<YAML$/ {l=NR} END{print l+0}' "$script")"
  end="$(awk -v n="$line_no" 'NR>n && /^YAML$/ {print NR; exit}' "$script")"
  [ "$start" -gt 0 ] && [ "$end" -gt "$start" ] || return 1
  block="$(sed -n "$((start+1)),$((end-1))p" "$script")"

  # Stand-ins for the values the live run computes from the cluster; the probe
  # interpolation itself is the script's real line, not a copy of it.
  local APISERVER_IP="10.43.0.1"
  local BACKEND_HOST="backend.example.test"
  local APP_PROXY_URL="http://tb-egress-squid.default.svc.cluster.local:3128"
  local APP_NO_PROXY="localhost,127.0.0.1"
  assign="$(grep -m1 '^APP_PROBE_SNIPPET=' "$script")"
  [ -n "$assign" ] || return 1
  eval "$assign"
  [ -n "$APP_PROBE_SNIPPET" ] || return 1

  rendered="$(eval "cat <<YAML
$block
YAML")"
  printf '%s\n' "$rendered" | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin.read())
args = doc["spec"]["containers"][0]["args"]
assert len(args) == 1, "expected one args entry, got %d" % len(args)
script = args[0]
for needle in (">>>>> SECTION_A_WITH_PROXY_ENV",
               "probe attempt",
               "GAVE UP",
               ">>>>> SECTION_B_PROXY_ENV_UNSET"):
    assert needle in script, "the pod script is missing %r — the probe did not land inside args" % needle
# The probe must be in section A, before the env-unset section, or it is not the
# call the tunnel assertion reads.
a = script.index(">>>>> SECTION_A_WITH_PROXY_ENV")
b = script.index(">>>>> SECTION_B_PROXY_ENV_UNSET")
assert a < script.index("probe attempt") < b, "the probe is not inside section A"
' || return 1
}
