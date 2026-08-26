#!/usr/bin/env bash
#
#  kubelet-arg-map-safety.sh — which kubelet settings may travel as a
#  `--kubelet-arg` CLI flag, and which must be authored in a config drop-in.
#
#  WHY THIS EXISTS
#  ---------------
#  `EvictionHard` is a MAP, and the kubelet replaces it WHOLESALE — it is not
#  merged key by key. k3s ships defaults for `imagefs.available` and
#  `nodefs.available`, so
#
#      --k3s-arg "--kubelet-arg=eviction-hard=memory.available<500Mi@all"
#
#  does not add a memory threshold to the existing set. It replaces the set, and
#  both disk thresholds are gone. The node then never evicts on a full disk —
#  which is exactly the failure backend#2223 and backend#2443 exist to prevent.
#  No error, no warning, no log line: the flag is valid, the install succeeds,
#  and the only symptom is a class of eviction that stops happening.
#
#  backend#2460 (P3) has to set absolute `kube-reserved`, `system-reserved` and
#  `eviction-hard` at install time so `allocatable` stops meaning "the whole
#  machine". Its ticket records this trap in prose. Prose does not block a merge,
#  and the tempting edit is a one-liner right next to a working precedent:
#  BOTH twins already pass `--kubelet-arg=fail-cgroupv1=false@all`
#  (`scripts/lib/cluster.sh`, `scripts/install-k8s.ps1`). Adding a second
#  `--kubelet-arg` beside it looks like following the local convention. This
#  guard is what makes the trap fail a build instead of a customer's cluster.
#
#  THE RULE, and why it is drawn where it is
#  -----------------------------------------
#  A kubelet setting may go through `--kubelet-arg` only if it is a SCALAR whose
#  value stands alone. `fail-cgroupv1=false` qualifies: one boolean, no defaults
#  to clobber, and the flag is the only sane way to pass it before a config file
#  exists.
#
#  Three settings are excluded, for two different reasons:
#
#    eviction-hard    a map with k3s-supplied defaults -> wholesale replacement
#                     silently drops the disk thresholds (the trap above).
#    kube-reserved    maps too. k3s ships no defaults for these, so nothing is
#    system-reserved  clobbered -- but the kubelet REFUSES a field set both on
#                     the CLI and in a config file, so admitting them here makes
#                     the drop-in that #2460 needs impossible to add later
#                     without first unpicking this. They belong with
#                     `eviction-hard` because the three are one reservation
#                     policy and are only reviewable when read together.
#
#  The allowlist is DELIBERATELY a list of what is permitted, not a denylist of
#  what is forbidden. A denylist passes anything nobody thought of, and the next
#  map-valued kubelet setting is exactly the thing nobody thought of.
#
#  Extending it is legitimate. Do it in ONE place (`SAFE_KUBELET_ARGS` below),
#  with a comment saying why the setting is scalar and has no defaults to
#  replace, and the change is visible in review — which is the whole point.
#
#  THIS SCRIPT DERIVES, IT DOES NOT RESTATE. It parses the kubelet args each
#  installer actually passes and checks them against the allowlist; it holds no
#  copy of what the installers do. A hand-written third copy would agree with
#  itself while disagreeing with both installers — the defect, not the fix
#  (backend#1729).
#
#  It lives in the `Source-of-truth drift` job, which is REQUIRED on develop and
#  on main, so a violation blocks the merge. `Pester (windows-latest)` — where
#  the PowerShell half would otherwise be checked — is NOT a required context, so
#  a guard living only there could advise but never block. bash only, ~1 s.
#
#  READ-ONLY. Exit 0 clean, 1 violation, 2 cannot tell (fail closed).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TB_KUBELET_ARG_ROOT exists so this guard's OWN test suite can point it at a
# fixture tree and drive the real script, rather than re-implementing the rule in
# the test -- an inline copy drifts from production and then proves that a regex
# nobody runs would have caught the bug. Unset in every real invocation.
root="${TB_KUBELET_ARG_ROOT:-$(cd "$here/../.." && pwd)}"

BASH_LIB="$root/scripts/lib/cluster.sh"
PS1_FILE="$root/scripts/install-k8s.ps1"

fail_closed() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
for f in "$BASH_LIB" "$PS1_FILE"; do
  [ -r "$f" ] || fail_closed "cannot read ${f#"$root"/} -- refusing to report a clean sweep over a file that was not read"
done

# Settings permitted as a `--kubelet-arg`. See the header for the rule; add here,
# with a reason, or not at all.
#
#   fail-cgroupv1  scalar boolean, no k3s default to replace, and it must be set
#                  at cluster-create time before any config file exists
#                  (backend#2422). Gated on kubelet >= 1.31 in both twins.
SAFE_KUBELET_ARGS="fail-cgroupv1"

findings=0
note() { findings=$((findings + 1)); printf '\nFINDING %d: %s\n' "$findings" "$1"; shift; for l in "$@"; do printf '  %s\n' "$l"; done; }

# Whole-comment lines dropped, for the reason k3s-components-agreement.sh gives at
# length: both installers DOCUMENT the flags they pass, and this file's own header
# names every forbidden setting. A check that reads prose fires on its own
# documentation, which is not a finding about the code.
#
# Whole lines only, NOT `sed 's/#.*//'`: cutting from the first '#' anywhere would
# also cut a '#' inside a string literal and could swallow a real
# `--kubelet-arg=`, i.e. under-report -- the fail-OPEN direction. A trailing
# comment naming a setting therefore still trips this guard. That is the right way
# to be wrong here. Both languages use '#'.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

# The kubelet settings a body passes: one NAME per line, sorted, deduped, with the
# value and the k3d node filter (`@all`, `@server:*`) stripped.
#
# `[A-Za-z0-9._-]+` covers every kubelet flag spelling, dots included
# (`eviction-hard`, `system-reserved`, `feature-gates`, `node-status-max-images`).
kubelet_args_in() {
  grep -oE -- '--kubelet-arg=[A-Za-z0-9._-]+' <<<"$1" \
    | sed 's/^--kubelet-arg=//' \
    | sort -u
}

bsh="$(kubelet_args_in "$(code_of "$BASH_LIB")")"
ps1="$(kubelet_args_in "$(code_of "$PS1_FILE")")"

# Fail CLOSED on a parse that finds nothing. Zero parsed args pass an allowlist
# check vacuously, and a stale parser reports a clean sweep -- exactly the shape
# backend#1729 catalogued. Both twins pass `fail-cgroupv1` today, so an empty
# parse means the installer changed or this parser did, and either way a human
# should look before this reports green.
[ -n "$bsh" ] || fail_closed "parsed NO --kubelet-arg= settings from scripts/lib/cluster.sh; either the installer stopped passing kubelet args or the parser is stale, and the allowlist check below would be vacuous"
[ -n "$ps1" ] || fail_closed "parsed NO --kubelet-arg= settings from scripts/install-k8s.ps1; same reasoning"

printf 'kubelet settings passed as CLI args, as declared by each installer:\n'
printf '  scripts/lib/cluster.sh    %s\n' "$(echo "$bsh" | tr '\n' ' ')"
printf '  scripts/install-k8s.ps1   %s\n' "$(echo "$ps1" | tr '\n' ' ')"
printf 'allowed as a CLI arg:       %s\n\n' "$SAFE_KUBELET_ARGS"

is_safe() {
  local candidate="$1" safe
  for safe in $SAFE_KUBELET_ARGS; do
    [ "$candidate" = "$safe" ] && return 0
  done
  return 1
}

# --- 1. every kubelet arg either installer passes must be on the allowlist ---
#
# Reported per (installer, setting) rather than as one summary line, because the
# fix is per site: a reviewer needs to know which twin to open.
for twin in bash ps1; do
  case "$twin" in
    bash) args="$bsh"; label="scripts/lib/cluster.sh" ;;
    ps1)  args="$ps1"; label="scripts/install-k8s.ps1" ;;
  esac
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    is_safe "$arg" && continue
    case "$arg" in
      eviction-hard)
        note "$label passes eviction-hard as a --kubelet-arg" \
          "EvictionHard is a MAP and the kubelet replaces it WHOLESALE." \
          "k3s ships imagefs.available and nodefs.available defaults; this flag" \
          "DELETES both. The node then never evicts on a full disk, silently --" \
          "re-opening backend#2223 and backend#2443 with no error and no log." \
          "Write a kubelet config drop-in and point k3s at it, so the map is" \
          "authored whole. See backend#2460."
        ;;
      kube-reserved|system-reserved)
        note "$label passes $arg as a --kubelet-arg" \
          "$arg is map-valued, and the kubelet REFUSES a field set both on the" \
          "command line and in a config file -- so this blocks the drop-in that" \
          "backend#2460 needs, and it splits one reservation policy across two" \
          "places where no reviewer can read it whole." \
          "Put it in the drop-in beside eviction-hard. See backend#2460."
        ;;
      *)
        note "$label passes '$arg' as a --kubelet-arg, which is not on the allowlist" \
          "This guard admits a kubelet setting on the command line only when it" \
          "is a SCALAR with no defaults to replace (see SAFE_KUBELET_ARGS in" \
          "scripts/tests/kubelet-arg-map-safety.sh)." \
          "If '$arg' is such a setting, add it there WITH a reason and this goes" \
          "green. If it is map-valued -- or if the kubelet ships a default for" \
          "it -- put it in a config drop-in instead: passing half a map is a" \
          "silent config loss, which is the failure this guard exists to catch."
        ;;
    esac
  done <<<"$args"
done

# --- 2. the two installers must pass the SAME kubelet args ------------------
#
# Not a rewording of check 1: both twins can be individually allowlist-clean and
# still disagree, which ships two platforms with differently-configured kubelets.
# A behaviour validated on one then silently does not hold on the other, and the
# gate on this flag is version-dependent, so a drop on one side is easy to miss.
if [ "$bsh" != "$ps1" ]; then
  note "the bash and PowerShell installers pass different kubelet args" \
    "cluster.sh     : $(echo "$bsh" | tr '\n' ' ')" \
    "install-k8s.ps1: $(echo "$ps1" | tr '\n' ' ')" \
    "Whatever is missing on one side, add it there -- or remove it from both." \
    "scripts/tests/fixtures/installer_parity.json is the declared contract."
fi

if [ "$findings" -ne 0 ]; then
  printf '\nkubelet-arg-map-safety: %d finding(s).\n' "$findings"
  exit 1
fi
printf 'kubelet-arg-map-safety: clean -- every kubelet CLI arg is an allowlisted scalar, and both installers agree.\n'
