#!/usr/bin/env bash
#
#  kubelet-config-agreement.sh — the two installer twins must emit the SAME
#  kubelet config drop-in, and it must actually bound the image store.
#
#  WHY THIS EXISTS (backend#2634)
#  -----------------------------
#  Every edge ran on the kubelet's stock 85% high / 80% low image-GC defaults.
#  Task images are 2.7-11 GB across 32 task x arch variants, the base image IS
#  the image (`base:gpu` 7.88 GB vs `client-image_classification-gpu` 7.89 GB --
#  the task adds ~10 MB), and floating `:<CLIENT_ENV>` tags with
#  `imagePullPolicy: Always` leave the previous digest resident on every
#  republish. So nodes fill until GC and disk-pressure eviction begin DURING
#  customer training -- the symptom backend#2443 first saw misreported as
#  "CPU Overload".
#
#  The fix is a kubelet config drop-in, and it has to be written by BOTH twins
#  (`scripts/lib/cluster.sh`, `scripts/install-k8s.ps1`). That is two files
#  holding three numbers, which is a divergence waiting to happen: client#772
#  records five real divergences that landed in exactly this gap, one of which
#  left machine sizing silently DEAD on Windows with no test noticing.
#
#  THIS SCRIPT DERIVES, IT DOES NOT RESTATE (CLAUDE.md rules 1 and 9). It parses
#  the values out of each installer and compares them to each other. It holds no
#  copy of what they should be -- a hand-written third copy would agree with
#  itself while disagreeing with both twins, which is the defect and not the fix
#  (backend#1729). Retuning the thresholds is therefore a values change in two
#  files and NOT a change here.
#
#  WHAT IT ASSERTS, and why these and not the integers
#  --------------------------------------------------
#    1. all three settings are present in BOTH twins   (absent => stock 85/80)
#    2. the two twins agree, field by field
#    3. low < high                                     (equal or inverted: the
#       kubelet refuses to start, and k3s surfaces it as a node that never
#       becomes Ready)
#    4. high is not LOOSER than the stock 85 it replaces
#    5. the reclaim band is at least TB_MIN_GC_BAND points wide -- the whole
#       point of the ticket. A 5-point band on a 200 GB disk is 10 GB, which can
#       be less than ONE task image: GC then frees nothing useful and re-trips
#       immediately, while a pull is already failing.
#    6. the node mount path agrees with the --kubelet-arg path, in both twins --
#       a drop-in mounted somewhere the kubelet is not told to read is the
#       silent-no-op version of this whole change
#
#  Pinning the RELATIONSHIPS rather than the values is deliberate: a guard that
#  asserted `high == 75` would have to be edited by whoever retunes the numbers,
#  which is precisely the person whose reasoning it exists to check.
#
#  FAIL CLOSED. Exit 0 clean, 1 violation, 2 cannot tell. A file that will not
#  read, or a parse that yields nothing, is a finding -- zero parsed values pass
#  an agreement check vacuously, which is the shape backend#1729 catalogued.
#
#  Lives in the `Source-of-truth drift` job, REQUIRED on develop and main, for the
#  reason kubelet-arg-map-safety.sh gives: `Pester (windows-latest)` is not a
#  required context, so a guard living only there could advise but never block.
#  bash only, ~1 s.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TB_KUBELET_CFG_ROOT lets this guard's own suite point it at a fixture tree and
# drive the REAL script, rather than re-implementing the rule in the test -- an
# inline copy drifts from production and then proves a regex nobody runs would
# have caught the bug (CLAUDE.md rule 9). Unset in every real invocation.
root="${TB_KUBELET_CFG_ROOT:-$(cd "$here/../.." && pwd)}"

BASH_LIB="$root/scripts/lib/cluster.sh"
PS1_FILE="$root/scripts/install-k8s.ps1"

# The stock kubelet default this change exists to replace, and the minimum band
# that makes a GC pass useful. These are properties of the KUBELET and of the
# measured image sizes -- not of our chosen values -- so holding them here is not
# the restatement rule 1 forbids. The values under test are parsed, never held.
TB_STOCK_GC_HIGH=85
TB_MIN_GC_BAND=10

fail_closed() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
for f in "$BASH_LIB" "$PS1_FILE"; do
  [ -r "$f" ] || fail_closed "cannot read ${f#"$root"/} -- refusing to report agreement over a file that was not read"
done

findings=0
note() { findings=$((findings + 1)); printf '\nFINDING %d: %s\n' "$findings" "$1"; shift; for l in "$@"; do printf '  %s\n' "$l"; done; }

# Comment lines are dropped whole, for the reason kubelet-arg-map-safety.sh gives:
# both installers DOCUMENT these values in prose, and a check that reads its own
# documentation fires on the docs rather than the code. Whole lines only -- cutting
# from the first '#' anywhere would also cut inside a string literal and could
# swallow a real assignment, i.e. under-report, which is the fail-OPEN direction.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

# Assignment forms differ by language and that is the whole reason this parses
# rather than greps a shared file:
#   bash   TB_KUBELET_IMAGE_GC_HIGH_PERCENT=75
#   ps1    $TB_KUBELET_IMAGE_GC_HIGH_PERCENT = 75
# Quotes are stripped so `"2m"` and `2m` compare equal -- the values are compared
# as the kubelet would read them, not as each language happens to spell them.
value_of() {
  local body="$1" name="$2" v
  # `/` is in the class because one of these settings is a PATH. Without it the
  # path parsed as empty and read as "absent", which is the fail-CLOSED direction
  # and how this was caught -- but it would have hidden a real divergence too.
  v="$(grep -oE -- "\\\$?${name}[[:space:]]*=[[:space:]]*\"?[A-Za-z0-9._/-]+\"?" <<<"$body" \
        | head -1 | sed -E "s/^\\\$?${name}[[:space:]]*=[[:space:]]*//; s/^\"//; s/\"$//")"
  printf '%s' "$v"
}

SETTINGS="TB_KUBELET_IMAGE_GC_HIGH_PERCENT TB_KUBELET_IMAGE_GC_LOW_PERCENT TB_KUBELET_IMAGE_MIN_GC_AGE TB_KUBELET_CONFIG_NODE_PATH"

bsh_body="$(code_of "$BASH_LIB")"
ps1_body="$(code_of "$PS1_FILE")"

printf 'kubelet config drop-in, as declared by each installer:\n'
parsed_any=0
for name in $SETTINGS; do
  b="$(value_of "$bsh_body" "$name")"
  p="$(value_of "$ps1_body" "$name")"
  printf '  %-36s bash=%-28s ps1=%s\n' "$name" "${b:-<absent>}" "${p:-<absent>}"
  [ -n "$b" ] && parsed_any=1

  if [ -z "$b" ] || [ -z "$p" ]; then
    note "$name is not set by both installers (bash='${b:-<absent>}' ps1='${p:-<absent>}')" \
      "An absent threshold is NOT a neutral default -- the node keeps the kubelet's" \
      "stock 85% high / 80% low image GC, which is the unbounded image store" \
      "backend#2634 is about. An absent node path means the mount and the" \
      "--kubelet-arg can no longer be held to the same string."
  elif [ "$b" != "$p" ]; then
    note "$name DIVERGES between the twins: bash='$b' ps1='$p'" \
      "The two installers must configure the same node. client#772 records five" \
      "divergences that landed in exactly this gap; one left machine sizing dead" \
      "on Windows with no test noticing."
  fi
done

# Fail CLOSED on a parse that found nothing at all: an agreement check over zero
# parsed values is vacuous, and a stale parser reports a clean sweep.
[ "$parsed_any" -eq 1 ] || fail_closed "parsed NO kubelet config values from scripts/lib/cluster.sh; either the installer stopped writing a drop-in or this parser is stale, and every comparison above would be vacuous"

high="$(value_of "$bsh_body" TB_KUBELET_IMAGE_GC_HIGH_PERCENT)"
low="$(value_of "$bsh_body" TB_KUBELET_IMAGE_GC_LOW_PERCENT)"

if [[ "$high" =~ ^[0-9]+$ && "$low" =~ ^[0-9]+$ ]]; then
  if [ "$low" -ge "$high" ]; then
    note "imageGCLowThresholdPercent ($low) is not below imageGCHighThresholdPercent ($high)" \
      "The kubelet refuses to start on this, and k3s surfaces the refusal as a node" \
      "that simply never becomes Ready -- so the install looks like a timeout."
  fi
  if [ "$high" -gt "$TB_STOCK_GC_HIGH" ]; then
    note "imageGCHighThresholdPercent ($high) is LOOSER than the stock default ($TB_STOCK_GC_HIGH)" \
      "Configuring it explicitly is the point of the ticket; configuring it to" \
      "reclaim later than the default inverts it."
  fi
  band=$((high - low))
  if [ "$band" -lt "$TB_MIN_GC_BAND" ]; then
    note "the reclaim band is $band points ($low..$high), narrower than $TB_MIN_GC_BAND" \
      "GC reclaims down to the LOW mark and stops. A band narrower than one task" \
      "image (2.7-11 GB) frees less than one image and re-trips immediately, while" \
      "a pull is already failing. That is the stock behaviour this ticket replaces."
  fi
else
  note "the image-GC thresholds did not parse as integers (high='$high' low='$low')" \
    "Cannot tell whether the band is usable, and 'cannot tell' is a finding."
fi

# The mount path and the --kubelet-arg path must be the same string, per twin. A
# drop-in mounted where the kubelet is not told to look is the silent-no-op
# version of this entire change: the install succeeds, /configz shows stock.
for pair in "cluster.sh:$bsh_body" "install-k8s.ps1:$ps1_body"; do
  fname="${pair%%:*}"; body="${pair#*:}"
  # BOTH PATHS ARE EXTRACTED AND COMPARED (Bugbot, Medium, on client#912). The
  # header claimed this compared them; it only asserted that SOME config= flag
  # existed and SOME -v line mentioned the variable, so a kubelet pointed at a
  # different path than the one mounted passed cleanly -- the exact silent no-op
  # this gate exists to block, missed by the assertion written to block it. A
  # docstring claiming a check that is not there teaches the bypass (rule 7).
  argpath="$(grep -oE -- '--kubelet-arg=config=[^"'"'"' ]+' <<<"$body" | head -1 | sed 's/.*--kubelet-arg=config=//; s/@all$//')"
  # The mount DESTINATION: after the last ':' and before any @node-filter.
  mountpath="$(grep -F 'TB_KUBELET_CONFIG_NODE_PATH' <<<"$body" \
    | grep -oE -- '[^"[:space:]]*:[^"[:space:]]*@all' | head -1 \
    | sed 's/@all$//; s/.*://')"
  if [ -z "$argpath" ]; then
    note "$fname passes no --kubelet-arg=config=, so nothing loads the drop-in" \
      "The file would be written and mounted, and the kubelet would never read it."
  elif [ -z "$mountpath" ]; then
    note "$fname points the kubelet at '$argpath' but mounts the config nowhere" \
      "The kubelet would be told to read a path that is not in the node."
  elif [ "$argpath" != "$mountpath" ]; then
    note "$fname mounts the config at '$mountpath' but points the kubelet at '$argpath'" \
      "Same install, two different paths: the kubelet reads nothing, the node keeps" \
      "the stock 85% threshold, and the install reports success. Silent no-op."
  fi
done

if [ "$findings" -gt 0 ]; then
  printf '\nkubelet-config-agreement: %d finding(s).\n' "$findings"
  exit 1
fi
printf '\nkubelet-config-agreement: clean -- both installers emit the same drop-in, the band is usable, and the kubelet is pointed at the file that is mounted.\n'
exit 0
