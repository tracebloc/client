#!/usr/bin/env bash
# The metrics-server preflight must not lock anyone out -- operator or cron.
#
# backend#2469. `lookup` has three outcomes, not two: it sees the cluster, it
# returns empty (offline), or it RAISES on forbidden -- and helm cannot catch the
# third. Two distinct lockouts follow from that, and this guard exists because a
# fix for one of them created the other:
#
#   1. `APIService` is cluster-scoped and the built-in `admin` ClusterRole excludes
#      it, so an operator with only namespace-scoped admin could not `helm upgrade`
#      the chart AT ALL. The escape hatch is nodeAgents.metricsServerPreflight.
#
#   2. The first attempt at (1) probed a `metrics-server` Deployment first and
#      granted the auto-upgrade SA a matching read. THE TICK THAT WOULD APPLY THE
#      GRANT IS THE TICK THAT NEEDS IT -- the scoped SA renders before the
#      ClusterRole lands, 403s, `--atomic` rolls back, and every later hourly tick
#      fails identically. A permanent fleet-wide lockout. (Bugbot High.)
#
# So the invariant is: THE PREFLIGHT MAKES NO PRIVILEGED CALL THE CURRENT
# ServiceAccount CANNOT ALREADY MAKE, and its one privileged call is gated by a
# values flag.
#
# WHY A SOURCE CHECK. helm-unittest renders offline, where every `lookup` returns
# empty, so it never reaches any of these branches and cannot tell a gated lookup
# from an ungated one -- mutation-proved: removing the gate leaves the chart suite
# green. The structure is only observable in the template text.
#
# FAILS CLOSED: a missing file, or a guard shape it cannot recognise, is an ERROR.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tpl="$repo_root/client/templates/resource-monitor-daemonset.yaml"
rbac="$repo_root/client/templates/auto-upgrade-rbac.yaml"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "$tpl" ]  || fail "$tpl is missing -- cannot check, which is a finding"
[ -f "$rbac" ] || fail "$rbac is missing -- cannot check, which is a finding"

echo "== preflight locks nobody out =="

# BLANK the comment lines, do not delete them: the ordering checks below need the
# ORIGINAL line numbers, and deleting would shift them.
#
# Both delimiter forms, because this template uses both: `{{/*` and `{{- /*` to
# open, `*/}}` and `*/ -}}` to close. The first version of this stripper matched
# only the un-trimmed pair, so it either leaked prose into the greps or -- on a
# `*/ -}}` closer it could not see -- swallowed the rest of the file and passed on
# an empty parse. Both directions are silent. (Bugbot Medium on client#823.)
code="$(awk '
  {
    line = $0
    opens  = (line ~ /\{\{-?[[:space:]]*\/\*/)
    closes = (line ~ /\*\/[[:space:]]*-?\}\}/)
    if (inc) { print ""; if (closes) inc = 0; next }
    if (opens && closes) { print ""; next }
    if (opens) { inc = 1; print ""; next }
    print line
  }
  END { if (inc) exit 3 }
' "$tpl")" || fail \
"an unterminated helm comment block in $(basename "$tpl") -- the stripper reached EOF
   still inside one. Refusing to grep a file it cannot parse, because an over-eager
   strip leaves an empty parse that compares equal to anything."

[ -n "${code//[[:space:]]/}" ] || fail \
"stripping comments left no code at all in $(basename "$tpl"). That is a parse
   failure, not a clean template."

# 1. The ONLY privileged lookup is the already-granted APIService one.
priv_kinds="$(grep -oE 'lookup "[^"]+" "[^"]+"' <<<"$code" | sort -u || true)"
while IFS= read -r call; do
  [ -n "$call" ] || continue
  case "$call" in
    'lookup "v1" "Namespace"') ;;                                  # any reader can
    'lookup "apiregistration.k8s.io/v1" "APIService"') ;;           # granted by backend#953
    *) fail "the preflight makes a lookup this guard does not recognise as safe: $call
   Any lookup of a resource the auto-upgrade ServiceAccount cannot ALREADY read is
   a permanent fleet-wide lockout -- the tick that would grant it is the tick that
   needs it. If this call is genuinely safe, grant it in auto-upgrade-rbac.yaml in
   an EARLIER release and add it here deliberately (backend#2469)." ;;
  esac
done <<<"$priv_kinds"

# 2. That one call is gated by the values flag -- asserted on CODE, not comments.
# ORDERING, not mere presence. Asking only "does some `if` mention the key"
# passes when the lookup sits ABOVE that `if` -- which is the original lockout,
# unchanged. The lookup has to be reachable only through the gate's else branch,
# so: gate < else < lookup, all on code lines. (Bugbot Medium on client#823.)
# FAIL-CLOSED BY CONSTRUCTION, not by remembering. The previous shape was a
# `line_of` that could return empty plus a separate `[ -n ... ] || fail` beside
# each call -- and one of the three calls did not get one. With that variable
# empty, `[ 98 -ge "" ]` prints "integer expression expected" and returns 2, but
# it is the condition of an `if`, so errexit is suppressed by design, the branch
# is simply not taken, `fail` is never reached, and the script runs on to print
# GREEN. A required guard reporting a pass for a check it did not perform.
#
# That is the THIRD fail-open hole in this one file (the untrimmed match, the
# pipefail early-close, this) and every one of them was the guard failing while
# the guarded thing was fine. So the helper now refuses on its own behalf: there
# is no way to call it and forget the check. (@saadqbal + Bugbot on client#823.)
require_line() {
  local pattern="$1" what="$2" all=""
  all="$(grep -nE "$pattern" <<<"$code")" || true
  all="${all%%$'\n'*}"
  all="${all%%:*}"
  case "$all" in
    ''|*[!0-9]*) fail "could not locate $what in $(basename "$tpl").
   Either the preflight was removed -- then delete this guard deliberately, in the
   same change -- or it changed shape and this check can no longer see it. Not
   knowing is a finding, not a pass." ;;
  esac
  printf '%s' "$all"
}

gate_line="$(require_line '^[[:space:]]*\{\{-?[[:space:]]*if .*metricsServerPreflight' \
  'the nodeAgents.metricsServerPreflight gate -- the only escape hatch for a caller who cannot read APIServices')"
else_line="$(require_line '^[[:space:]]*\{\{-?[[:space:]]*else[[:space:]]*-?\}\}' \
  "the gate's else branch, without which this guard cannot tell which side the APIService lookup is on")"
api_line="$(require_line 'lookup "apiregistration.k8s.io/v1" "APIService"' \
  'the APIService lookup')"

if [ "$gate_line" -ge "$api_line" ] || [ "$else_line" -ge "$api_line" ] || [ "$gate_line" -ge "$else_line" ]; then
  fail "the APIService lookup (line $api_line) is not reached through the
   metricsServerPreflight gate (line $gate_line) and its else (line $else_line).
   Expected gate < else < lookup. As ordered, setting the flag false does not skip
   the privileged call -- which is the lockout backend#2469 exists to fix, intact."
fi

# 3. A skipped check must not look like a passed one.
grep -q 'tracebloc.io/metrics-server-preflight' <<<"$code" || fail \
"the render does not record which preflight path decided. A skip indistinguishable
   from a pass is the failure this guard exists to prevent."

# 4. The auto-upgrade SA keeps the read the one privileged call needs.
grep -q 'resources: \["apiservices"\]' "$rbac" || fail \
"the auto-upgrade scoped role does not grant 'apiservices', so the preflight's one
   privileged call would 403 on every hourly tick (backend#953)."

# 5. ...and gained no NEW reads, which is how lockout (2) happened.
if grep -qE '^\s*resources: \["deployments"\]' "$rbac"; then
  fail "auto-upgrade-rbac.yaml grants 'deployments'. That was added to support a
   Deployment probe in the preflight and is a fleet-wide lockout: the first tick
   onto such a chart renders BEFORE the grant lands, 403s, and --atomic rolls it
   back forever. Remove both the probe and the grant (Bugbot High on client#823)."
fi

echo "  ok: the only privileged lookup is the already-granted APIService one"
echo "  ok: it is gated by nodeAgents.metricsServerPreflight (asserted on code, not comments)"
echo "  ok: the deciding path is recorded on the object"
echo "  ok: auto-upgrade keeps 'apiservices' and gained no new reads"
echo "preflight locks nobody out: green"
