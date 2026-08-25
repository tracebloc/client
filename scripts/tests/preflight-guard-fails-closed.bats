#!/usr/bin/env bats
# The preflight guard must FAIL when the thing it guards is broken.
#
# backend#2469. `preflight-not-privilege-gated.sh` is a REQUIRED check whose whole
# job is catching a silent regression, and it has now had THREE fail-open holes:
# an untrimmed match, a `pipefail` early-close, and a `line_of` result used without
# a non-empty check. Every one of them was the GUARD failing while the guarded
# thing was fine, and every one was found by reading rather than by running.
#
# So the mutations run here instead of by hand. Each case breaks the template or
# the RBAC in a specific way and asserts the guard exits NON-ZERO. A guard that
# cannot fail is not a gate, and "I checked carefully" is not evidence that it can.
# (@saadqbal on client#823.)

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="${BATS_TEST_DIRNAME}/preflight-not-privilege-gated.sh"
  TMP="$(mktemp -d)"
  # A throwaway copy of the repo's two relevant files, so a mutation cannot
  # escape into the working tree.
  mkdir -p "$TMP/client/templates" "$TMP/scripts/tests"
  cp "$REPO/client/templates/resource-monitor-daemonset.yaml" "$TMP/client/templates/"
  cp "$REPO/client/templates/auto-upgrade-rbac.yaml"          "$TMP/client/templates/"
  cp "$GUARD" "$TMP/scripts/tests/"
  TPL="$TMP/client/templates/resource-monitor-daemonset.yaml"
  RBAC="$TMP/client/templates/auto-upgrade-rbac.yaml"
  RUN="$TMP/scripts/tests/preflight-not-privilege-gated.sh"
}
teardown() { rm -rf "$TMP"; }

@test "the guard passes on the tree as it stands (else every case below is vacuous)" {
  run bash "$RUN" || return 1
  [ "$status" -eq 0 ] || return 1
}

@test "deleting the APIService lookup FAILS rather than reporting a pass" {
  # The exact hole Bugbot found: an unguarded empty line number made the ordering
  # comparisons lose quietly and the script print green.
  # REMOVED, not reworded. Rewording trips the "unrecognised lookup" check first,
  # which is also correct but exercises a different branch -- the hole was in the
  # path where the lookup is simply GONE and the line number comes back empty.
  python3 - "$TPL" <<'PYX' || return 1
import sys, re
p = sys.argv[1]; s = open(p).read()
m = re.search(r'^.*lookup "apiregistration\.k8s\.io/v1" "APIService".*\n', s, re.M)
assert m, "ANCHOR DID NOT APPLY: no APIService lookup to delete"
open(p, "w").write(s[:m.start()] + s[m.end():])
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
  # A phrase the message wrapping cannot split -- "Not knowing is a finding" spans
  # a line break in the real output, so asserting it would fail on a correct guard.
  [[ "$output" == *"could not locate the APIService lookup"* ]] || return 1
}

@test "hoisting the lookup above the gate FAILS — that is the original lockout" {
  python3 - "$TPL" <<'PYX' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
a = "{{- if $probe -}}\n"
assert s.count(a) == 1, "ANCHOR DID NOT APPLY"
hoist = a + '  {{- $early := lookup "apiregistration.k8s.io/v1" "APIService" "" "v1beta1.metrics.k8s.io" -}}\n'
open(p, "w").write(s.replace(a, hoist, 1))
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "deleting the values gate FAILS even when a comment still names the flag" {
  python3 - "$TPL" <<'PYX' || return 1
import sys, re
p = sys.argv[1]; s = open(p).read()
m = re.search(r'^\s*\{\{-?\s*if and \(hasKey.*metricsServerPreflight.*$', s, re.M)
assert m, "ANCHOR DID NOT APPLY"
open(p, "w").write(s[:m.start()] + "  {{- /* metricsServerPreflight is honoured here */ -}}\n  {{- if false -}}" + s[m.end():])
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "reintroducing the Deployment probe FAILS — a lookup the SA cannot already make" {
  python3 - "$TPL" <<'PYX' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
a = "{{- if $probe -}}\n"
assert s.count(a) == 1, "ANCHOR DID NOT APPLY"
probe = a + '  {{- if lookup "apps/v1" "Deployment" "kube-system" "metrics-server" -}}{{- end -}}\n'
open(p, "w").write(s.replace(a, probe, 1))
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "dropping the deciding-path annotation FAILS — a skip must not look like a pass" {
  python3 - "$TPL" <<'PYX' || return 1
import sys, re
p = sys.argv[1]; s = open(p).read()
m = re.search(r'^\s*tracebloc\.io/metrics-server-preflight:.*\n', s, re.M)
assert m, "ANCHOR DID NOT APPLY"
open(p, "w").write(s[:m.start()] + s[m.end():])
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "an unterminated helm comment FAILS rather than passing on an empty parse" {
  printf '\n{{- /* unterminated\n' >> "$TPL"
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "granting the auto-upgrade SA a deployments read FAILS — the fleet lockout" {
  python3 - "$RBAC" <<'PYX' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
a = '  - apiGroups: ["apiregistration.k8s.io"]'
assert s.count(a) >= 1, "ANCHOR DID NOT APPLY"
grant = '  - apiGroups: ["apps"]\n    resources: ["deployments"]\n    verbs: ["get"]\n'
open(p, "w").write(s.replace(a, grant + a, 1))
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}

@test "removing the apiservices grant FAILS — the one privileged call would 403" {
  python3 - "$RBAC" <<'PYX' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
a = '    resources: ["apiservices"]\n'
assert s.count(a) == 1, "ANCHOR DID NOT APPLY"
open(p, "w").write(s.replace(a, '    resources: ["configmaps"]\n', 1))
PYX
  run bash "$RUN" || return 1
  [ "$status" -ne 0 ] || return 1
}
