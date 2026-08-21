#!/usr/bin/env bash
#
#  k3s-components-agreement.sh — which k3s components the two installers switch
#  off at cluster-create time, and the one they must never switch off.
#
#  WHY THIS EXISTS
#  ---------------
#  Both installers pass k3s component disablements to `k3d cluster create`, and
#  the list is written out twice, in two languages:
#
#    1  scripts/lib/cluster.sh    `_create_new_cluster`  --k3s-arg "--disable=…"
#    2  scripts/install-k8s.ps1   `New-K3dCluster`       $k3dArgs
#
#  Before this guard, `traefik` and `servicelb` appeared NOWHERE in
#  scripts/tests/ — neither suite, on either installer. Dropping one is silent:
#  the install still succeeds, the cluster just carries an inbound component the
#  chart has no use for (it renders no Ingress and no LoadBalancer Service).
#  Nothing goes red, so nobody looks.
#
#  THE ONE THAT RUNS THE OTHER WAY: metrics-server is load-bearing and must never
#  be disabled. client/templates/resource-monitor-daemonset.yaml `lookup`s the
#  v1beta1.metrics.k8s.io APIService and `fail`s the release when it is absent, so
#  adding `--disable=metrics-server` as a footprint optimisation would abort the
#  install and every subsequent auto-upgrade tick, which re-renders the same
#  template. It is a plausible-looking edit next to the three legitimate ones, and
#  before this guard nothing on either installer stopped it.
#
#  THIS SCRIPT DERIVES, IT DOES NOT RESTATE. It parses the disable set out of each
#  installer and compares the two to each other; it holds no copy of the list. A
#  third hand-written copy would agree with itself while disagreeing with both
#  installers — the defect, not the fix (the lesson of backend#1729).
#
#  Per-mode conditionality (hostpath disables local-storage, node-local keeps it)
#  is behavioural and belongs with the unit suites, which invoke the real create
#  path: scripts/tests/cluster.bats and scripts/tests/install-k8s.Tests.ps1. This
#  script owns what neither of those can see — the two installers agreeing with
#  EACH OTHER, and the chart coupling that makes metrics-server load-bearing.
#
#  It lives in the `Source-of-truth drift` job for the reason that job's header
#  gives: it is REQUIRED on develop and on main, so a disagreement blocks the
#  merge. `Pester (windows-latest)`, where the PowerShell half would otherwise be
#  checked, is NOT a required context — a guard living only there could advise but
#  never block. bash only, ~1 s.
#
#  READ-ONLY. Exit 0 clean, 1 disagreement, 2 cannot tell (fail closed).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TB_K3S_AGREEMENT_ROOT exists so the guard's OWN test suite can point it at a
# fixture tree and drive the real script, rather than re-implementing the rule in
# the test -- an inline copy drifts from production and then proves that a regex
# nobody runs would have caught the bug. Unset in every real invocation.
root="${TB_K3S_AGREEMENT_ROOT:-$(cd "$here/../.." && pwd)}"

BASH_LIB="$root/scripts/lib/cluster.sh"
PS1_FILE="$root/scripts/install-k8s.ps1"
DAEMONSET="$root/client/templates/resource-monitor-daemonset.yaml"

fail_closed() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
for f in "$BASH_LIB" "$PS1_FILE" "$DAEMONSET"; do
  [ -r "$f" ] || fail_closed "cannot read ${f#"$root"/} -- refusing to report agreement between declarations one of which was not read"
done

findings=0
note() { findings=$((findings + 1)); printf '\nFINDING %d: %s\n' "$findings" "$1"; shift; for l in "$@"; do printf '  %s\n' "$l"; done; }

# Whole-comment lines dropped. EVERY check below reads this, never the raw file:
# both installers document the flags they pass — including, in cluster.sh, the one
# they must NOT pass and, in install-k8s.ps1, the very variable this script's
# tripwire watches for. A check that reads prose fires on its own documentation,
# which is not a finding about the code. (Learned the hard way: the tripwire in
# check 4 was written against the raw file and went red on the comment added to
# explain it.)
#
# Whole lines only, NOT `sed 's/#.*//'`: stripping from the first '#' anywhere
# would also cut a '#' inside a string literal, which could swallow a real
# `--disable=` and make this guard quietly under-report — the fail-OPEN direction.
# A trailing comment that names a flag therefore still trips a check. That is the
# right way to be wrong here, and it matches the rule the Pester copy applies, so
# the two halves of this guard classify identically. Both `#` forms are covered:
# bash and PowerShell use the same comment character.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

bsh_code="$(code_of "$BASH_LIB")"
ps1_code="$(code_of "$PS1_FILE")"

# The k3s components a body disables: one per line, sorted, deduped, the k3d node
# filter (`@server:*`) stripped.
disables_in() {
  grep -oE -- '--disable=[A-Za-z0-9_-]+' <<<"$1" \
    | sed 's/^--disable=//' \
    | sort -u
}

bsh="$(disables_in "$bsh_code")"
ps1="$(disables_in "$ps1_code")"

# Fail CLOSED. Zero parsed components compares equal to zero parsed components, so
# a stale parser would report perfect agreement between two empty sets — exactly
# the shape backend#1729 catalogued. A file that stopped disabling anything at all
# is itself a finding worth a human, not a silent pass.
[ -n "$bsh" ] || fail_closed "parsed NO --disable= components from scripts/lib/cluster.sh; either the installer stopped disabling k3s components or the parser is stale, and every comparison below would be vacuous"
[ -n "$ps1" ] || fail_closed "parsed NO --disable= components from scripts/install-k8s.ps1; same reasoning"

printf 'k3s components disabled at cluster-create time, as declared by each installer:\n'
printf '  scripts/lib/cluster.sh    %s\n' "$(echo "$bsh" | tr '\n' ' ')"
printf '  scripts/install-k8s.ps1   %s\n' "$(echo "$ps1" | tr '\n' ' ')"
printf '\n'

# --- 1. the two installers must disable the same components ---------------
if [ "$bsh" != "$ps1" ]; then
  note "the bash and PowerShell installers disable different k3s components" \
    "cluster.sh     : $(echo "$bsh" | tr '\n' ' ')" \
    "install-k8s.ps1: $(echo "$ps1" | tr '\n' ' ')" \
    "The two platforms would ship clusters with different components running," \
    "so a chart change validated on one silently does not hold on the other." \
    "Fix whichever list is wrong -- and if you are adding or removing a" \
    "component, do it in both."
fi

# --- 2. metrics-server must never be disabled, by either installer --------
for pair in "cluster.sh:$bsh" "install-k8s.ps1:$ps1"; do
  who="${pair%%:*}"
  if printf '%s\n' "${pair#*:}" | grep -qx 'metrics-server'; then
    note "$who disables metrics-server" \
      "resource-monitor needs it. client/templates/resource-monitor-daemonset.yaml" \
      "looks up the v1beta1.metrics.k8s.io APIService and calls \`fail\` when it is" \
      "absent, which aborts the whole helm release -- and every later auto-upgrade" \
      "tick, because each one re-renders this same template." \
      "This is not a footprint component. Remove the flag." \
      "If resource-monitor is genuinely not wanted, the supported switch is" \
      "resourceMonitor: false in values.yaml, not disabling the API it reads."
  fi
done

# --- 3. the coupling in 2 must still be real ------------------------------
# A guard whose reason has quietly gone away is worse than no guard: it keeps
# passing and teaches the next reader that the coupling is still enforced. If the
# chart stops hard-failing on a missing metrics.k8s.io, that is a deliberate
# decision someone should make while looking at this file -- so say so loudly
# rather than going on guarding nothing.
# Strips BOTH `#` comments and `{{/* … */}}` template comment blocks. The block
# strip matters: that template's header comment explains the metrics.k8s.io
# requirement in prose, so scanning it would let the comment satisfy the check on
# behalf of the code it describes -- a check passing on its own documentation.
#
# The opener tolerates Helm's WHITESPACE-CHOMPING form, `{{- /*`. Matching only
# `{{/*` left every `{{- /*` block in ds_body, and this template already writes
# two of them -- so the strip was one legal, invisible edit away from letting
# prose stand in for the code (Bugbot, client#764). It was not reachable as
# written, because the surviving prose says `metrics.k8s.io` while check 1 greps
# the fully-qualified `v1beta1.metrics.k8s.io`; that is protection by wording,
# not by construction, which is not protection.
ds_body="$(awk '
  /\{\{-?[[:space:]]*\/\*/  { inc = 1 }
  inc                 { if (/\*\/-?\}\}/) inc = 0; next }
  /^[[:space:]]*#/    { next }
                      { print }
' "$DAEMONSET")"
if ! grep -q 'v1beta1\.metrics\.k8s\.io' <<<"$ds_body"; then
  note "resource-monitor-daemonset.yaml no longer looks up v1beta1.metrics.k8s.io" \
    "Check 2 above exists because the chart hard-fails without that APIService." \
    "If that requirement is gone, metrics-server may no longer be load-bearing" \
    "and check 2 is now guarding a coupling that does not exist. Re-decide it" \
    "here, deliberately -- do not leave this passing for the wrong reason."
elif ! grep -q 'fail ' <<<"$ds_body"; then
  note "resource-monitor-daemonset.yaml still looks up metrics.k8s.io but no longer \`fail\`s" \
    "The lookup without the fail is a probe with no consequence: a cluster missing" \
    "metrics-server would now install cleanly and lose node telemetry silently" \
    "(client-runtime's resource_monitor.py builds NodeUtilisation as the first" \
    "statement in its poll loop, and the loop handler logs and sleeps 5 s -- so the" \
    "pod stays Running and never reaches send_heartbeat)." \
    "Restore the fail, or re-decide check 2."
fi

# --- 4. Windows node-local tripwire --------------------------------------
# install-k8s.ps1 disables local-storage UNCONDITIONALLY, while cluster.sh makes it
# conditional on TB_STORAGE_MODE. That is correct only because node-local
# (RFC-0003 Option C) is a Linux/k3s prototype with no Windows path — the reason
# install-k8s.ps1's leftover-data guard gives for being hostpath-only. It is a
# divergence held in place by an absence, which nothing was watching.
#
# So: the day install-k8s.ps1's CODE learns about TB_STORAGE_MODE, this reddens. It
# is a tripwire, not a defect report — the fix is to make the local-storage disable
# conditional the way cluster.sh does, then update this check. Reads $ps1_code, so
# naming the variable in a comment (as that file now does, to explain this) is not
# mistaken for using it.
if grep -q 'TB_STORAGE_MODE' <<<"$ps1_code"; then
  note "install-k8s.ps1 now references TB_STORAGE_MODE, but still disables local-storage unconditionally" \
    "cluster.sh disables local-storage only in hostpath mode: node-local needs" \
    "k3s's local-path provisioner to survive, or every dataset PVC stays Pending" \
    "against a StorageClass that does not exist." \
    "install-k8s.ps1 could disable it unconditionally only while node-local had no" \
    "Windows path at all. If you are adding one, make the flag conditional there" \
    "too and then relax this check -- it is a tripwire for exactly this change."
fi

printf '\n'
if [ "$findings" -eq 0 ]; then
  echo "k3s components: both installers disable the same set, neither disables metrics-server,"
  echo "and the chart coupling that makes metrics-server load-bearing is still in place."
  exit 0
fi
echo "k3s components: $findings finding(s)."
echo "One component list, two installers. Fix the declaration that is wrong -- and if"
echo "you are changing what k3s runs, change it in both and say why."
exit 1
