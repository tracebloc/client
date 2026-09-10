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
#    7. THE NODE RESERVATION (backend#2460): the generated reservation block --
#       the platforms list, every per-platform kubeReserved / systemReserved
#       value and the eviction threshold -- is present in BOTH twins and equal,
#       field by field; every platform in the list has all three values; no
#       value exists for a platform NOT in the list (a stale entry is a
#       reservation the writer will never emit, i.e. a platform that LOOKS
#       measured to a reader of the file); every value is a positive whole
#       number (an empty one is `memory: Mi`, which the kubelet refuses to
#       start on); and the eviction threshold is not LOOSER than the kubelet's
#       own 100Mi default. The SET of reservation names is derived from the two
#       files (union), never listed here, so a name added to one twin and not
#       the other is caught rather than skipped.
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
# The kubelet's own default memory eviction threshold (evictionHard
# memory.available<100Mi). k3s ships NONE, which is part of what backend#2460
# fixes; a declared threshold below the upstream default would be looser than
# even a stock kubelet. A property of the kubelet, held here like the two above.
TB_KUBELET_DEFAULT_EVICTION_MEM_MIB=100

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
      "For the two THRESHOLDS an absent value is NOT a neutral default -- the node" \
      "keeps the kubelet's stock 85% high / 80% low image GC, which is the unbounded" \
      "image store backend#2634 is about. An absent node path means the mount and the" \
      "--kubelet-arg can no longer be held to the same string." \
      "imageMinimumGCAge is the exception and is called out so this note is not read" \
      "as claiming more than it can: 2m IS the kubelet default, so setting it changes" \
      "nothing on the node and its /configz row cannot distinguish 'read our file'" \
      "from 'took the default' the way the 75/60 rows can. It is held here for TWIN" \
      "AGREEMENT only -- the two installers must not disagree about a field either" \
      "of them writes (reviewer, client#912)."
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

# BOTH TWINS MUST CHECK AN EXISTING CLUSTER, not just create a new one
# (Bugbot, Medium, on client#912). The drop-in is a create-time bind mount, so an
# already-created edge keeps the stock 85/80 thresholds forever. The bash twin got
# that check and the PowerShell twin did not -- and WSL2 edges are a real part of
# exactly that population. The values agreed perfectly while the BEHAVIOUR did not,
# which is why value agreement alone was not enough to catch it.
#
# Derived, like everything above: each body is searched for its own idiom -- the
# bash function, and the ps1 reuse-branch inspection keyed on the shared node-path
# variable. No copy of either installer is held here.
# KEYED ON THE OPERATOR-VISIBLE MESSAGE, not on an internal identifier. Two
# reasons. It is what the finding was about -- an existing edge staying unbounded
# "with no operator-visible signal" -- so the message IS the behaviour. And an
# internal name is a weak key: `kubeletMounts` occurs three times in the ps1, so
# any single-line edit leaves the grep satisfied while the check is gone, which is
# exactly how the first version of this assertion went vacuous under its own
# mutation. The message appears once per twin.
REUSE_MSG='no kubelet config mount'
bsh_reuse=0
grep -qF "$REUSE_MSG" <<<"$bsh_body" && bsh_reuse=1
ps1_reuse=0
grep -qF "$REUSE_MSG" <<<"$ps1_body" && ps1_reuse=1

if [ "$bsh_reuse" -eq 0 ] || [ "$ps1_reuse" -eq 0 ]; then
  note "only one twin checks an EXISTING cluster for the image-GC bound (bash=$bsh_reuse ps1=$ps1_reuse)" \
    "The drop-in is a create-time bind mount, so every edge created before it keeps" \
    "the kubelet's stock 85% threshold. A twin that does not look leaves that whole" \
    "population unbounded with no operator-visible signal -- and the two twins agreed" \
    "on every VALUE while disagreeing on this, so the checks above cannot see it."
fi

# BOTH TWINS MUST TREAT AN UNREADABLE INSPECT AS SILENCE (Bugbot, Medium, on
# client#912). This is a THIRD parity axis, distinct from the two above: the values
# agreed, the presence-of-a-check agreed, and the EMPTY-INPUT BEHAVIOUR did not.
#
# The bash twin guards on `[[ -z "$mounts" ]]`. The ps1 twin received its job output
# through two Out-String hops without `.Trim()`, so a failed or empty `docker
# inspect` arrived as a lone newline -- truthy in PowerShell -- and the `-and`
# empty-guard passed, firing the recreate warning on a cluster nobody could read.
# Cannot-tell read as missing, on the twin, in the function written to avoid exactly
# that. Its own k3s sibling `Test-K3sVersionDrift` had the `.Trim()` all along.
# SCOPED TO THE FUNCTION, for the same reason as the bash side below: the k3s
# sibling Test-K3sVersionDrift has always had the .Trim(), so a whole-file grep is
# satisfied by IT while the kubelet function has none. Its own mutation proved that
# (rc=0, VACUOUS) before this shipped.
ps1_kubelet_fn="$(awk '/^function Test-ExistingClusterKubeletConfig \{/{f=1} f{print} f&&/^\}$/{exit}' "$PS1_FILE")"
if [ -z "$ps1_kubelet_fn" ]; then
  note "could not extract Test-ExistingClusterKubeletConfig's body from install-k8s.ps1" \
    "Refusing to report on an empty extraction -- zero lines satisfy every check."
elif ! grep -qE 'Receive-Job \$job[^|]*\| Out-String\)\.Trim\(\)' <<<"$ps1_kubelet_fn"; then
  note "the ps1 twin does not Trim() the received docker-inspect output" \
    "Two Out-String hops turn an empty or failed inspect into a lone newline, which" \
    "is TRUTHY -- so the empty-guard passes and the advisory fires on a cluster that" \
    "could not be read. The bash twin stays silent on the same input."
fi
# SCOPED TO THE FUNCTION'S OWN BODY, and that scoping is the assertion. Four sibling
# checks in cluster.sh carry the identical `[[ -z "$mounts" ]] && return 0` line, so a
# whole-file grep is satisfied by any of them: deleting the kubelet one leaves three
# and the check passes. Caught by its own mutation (ANCHOR MATCHED 4x) before this
# shipped -- the same "one guard, several call sites, reports on whichever it finds"
# shape as the finding it exists for.
bsh_kubelet_fn="$(awk '/^_check_existing_cluster_kubelet_config\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$BASH_LIB")"
if [ -z "$bsh_kubelet_fn" ]; then
  note "could not extract _check_existing_cluster_kubelet_config's body from cluster.sh" \
    "Refusing to report on an empty extraction -- zero lines satisfy every check below."
elif ! grep -qE '\[\[ -z "\$mounts" \]\] && return 0' <<<"$bsh_kubelet_fn"; then
  note "the bash twin no longer returns early on empty mounts" \
    "'Cannot tell' would then read as 'missing' and warn on an unreadable cluster."
fi

# And the bash check must be CALLED somewhere, not merely defined.
#
# THIS ASSERTION IS DELIBERATELY WEAK, AND SAYING SO IS THE POINT (@aptracebloc and
# @saadqbal on client#912). It counts occurrences, so it answers "is this wired at
# all" and NOT "is it wired on the path a healthy edge actually takes". That
# distinction is the whole finding on this PR: the advisory had one call site, in
# `_handle_existing_cluster`, which assess.sh's healthy hand-off and
# `upgrade_cli_only` both return before reaching -- so it was dead for the entire
# population it exists for while this check sat green.
#
# REACHABILITY IS GATED ELSEWHERE, and not duplicated here on purpose:
# `scripts/tests/assess-early-exit-drift.bats` derives the reuse-path advisory set
# from `_handle_existing_cluster` and the early-exit set from
# `assess_existing_install` + `upgrade_cli_only`, and fails on any advisory in the
# first that is in neither of the second (with an exemption list that is itself
# checked for staleness). It runs in the `Unit tests` job, which IS a required
# context on develop -- verified, not assumed. Re-deriving that rule in shell here
# would give two derivations of one invariant that can drift apart, which is worse
# than one gated derivation.
#
# So what this line is for: catching the cheap regression of the function being
# deleted or renamed away entirely, in the same pass that checks the values.
if [ "$bsh_reuse" -eq 1 ]; then
  n_bsh="$(grep -c '_check_existing_cluster_kubelet_config' <<<"$bsh_body")"
  if [ "$n_bsh" -lt 2 ]; then
    note "_check_existing_cluster_kubelet_config is defined but never called (occurrences: $n_bsh)" \
      "Defined-and-unwired reports clean here and does nothing on a real re-run." \
      "NOTE: whether the call sites are on a REACHED path is gated by" \
      "assess-early-exit-drift.bats, not by this line."
  fi
fi

# ── 7. THE NODE RESERVATION BLOCK (backend#2460) ──────────────────────────────
#
# Names are DERIVED: every `TB_KUBELET_RESERVATION_*`, `TB_KUBELET_KUBE_RESERVED_*`,
# `TB_KUBELET_SYSTEM_RESERVED_*` and `TB_KUBELET_EVICTION_*` assignment found in
# EITHER twin's code is compared in both. Holding the list here would let a name
# added to one twin sail past (rule 1); the union cannot.
reservation_names() {
  grep -oE -- '\$?TB_KUBELET_(RESERVATION|KUBE_RESERVED|SYSTEM_RESERVED|EVICTION)_[A-Z0-9_]+[[:space:]]*=' <<<"$1" \
    | sed -E 's/^\$?//; s/[[:space:]]*=$//' | sort -u
}
res_names="$( { reservation_names "$bsh_body"; reservation_names "$ps1_body"; } | sort -u )"
if [ -z "$res_names" ]; then
  note "neither installer declares a node reservation block (no TB_KUBELET_RESERVATION_/KUBE_RESERVED_/SYSTEM_RESERVED_/EVICTION_ assignment)" \
    "backend#2460 puts kubeReserved / systemReserved / evictionHard in the same drop-in." \
    "Without the block, allocatable == capacity on every node the installers create."
fi
printf '\nnode reservation block, as declared by each installer:\n'
# The platforms list is a quoted, possibly EMPTY, space-separated string, which
# value_of (one unquoted token) cannot read; parse it as the writer does.
platforms_of() {
  grep -oE -- "^[[:space:]]*\\\$?TB_KUBELET_RESERVATION_PLATFORMS[[:space:]]*=[[:space:]]*\"[^\"]*\"" <<<"$1" \
    | head -1 | sed -E 's/^[^"]*"//; s/"$//'
}
for name in $res_names; do
  if [ "$name" = "TB_KUBELET_RESERVATION_PLATFORMS" ]; then
    b="$(platforms_of "$bsh_body")"
    p="$(platforms_of "$ps1_body")"
    printf '  %-44s bash="%s"  ps1="%s"\n' "$name" "$b" "$p"
    grep -qE -- "^[[:space:]]*${name}[[:space:]]*=" <<<"$bsh_body" || note "$name is not assigned in cluster.sh"
    grep -qE -- "^[[:space:]]*\\\$${name}[[:space:]]*=" <<<"$ps1_body" || note "$name is not assigned in install-k8s.ps1"
    if [ "$b" != "$p" ]; then
      note "$name DIVERGES between the twins: bash='$b' ps1='$p'" \
        "A platform measured for one installer and not the other is a reservation half the fleet never gets."
    fi
    continue
  fi
  b="$(value_of "$bsh_body" "$name")"
  p="$(value_of "$ps1_body" "$name")"
  printf '  %-44s bash=%-20s ps1=%s\n' "$name" "${b:-<absent>}" "${p:-<absent>}"
  if [ -z "$b" ] || [ -z "$p" ]; then
    note "$name is not set by both installers (bash='${b:-<absent>}' ps1='${p:-<absent>}')" \
      "Every reservation value must exist in both twins: the writer reads it by name, and an" \
      "absent one is a \`memory: Mi\` the kubelet refuses to start on -- a node that never becomes Ready."
  elif [ "$b" != "$p" ]; then
    note "$name DIVERGES between the twins: bash='$b' ps1='$p'" \
      "Same platform, two different reservations. The block is GENERATED into both files by" \
      "scripts/gen-node-reservation-embed.sh; one of them was hand-edited or the generator ran on one."
  elif ! [[ "$b" =~ ^[1-9][0-9]*$ ]]; then
    note "$name is '$b', not a positive whole number" \
      "The writer interpolates it into a Kubernetes quantity (\`250m\`, \`700Mi\`); anything else is a" \
      "kubelet that refuses to start, or a 0 that keeps the node dishonest while looking configured."
  fi
done

# Every platform in the list has all three values; no value belongs to a platform
# outside the list. Read from the bash body (the twins were just held equal).
platforms="$(platforms_of "$bsh_body")"
for plat in $platforms; do
  key="$(printf '%s' "$plat" | tr '[:lower:]' '[:upper:]')"
  for stem in KUBE_RESERVED_CPU_MILLI KUBE_RESERVED_MEM_MIB SYSTEM_RESERVED_MEM_MIB; do
    grep -qE -- "^[[:space:]]*TB_KUBELET_${stem}_${key}[[:space:]]*=" <<<"$bsh_body" \
      || note "platform '$plat' is listed as measured but TB_KUBELET_${stem}_${key} is not declared" \
           "The writer would emit the maps for it and read an empty value into a Kubernetes quantity."
  done
done
for name in $res_names; do
  case "$name" in
    TB_KUBELET_KUBE_RESERVED_*|TB_KUBELET_SYSTEM_RESERVED_*)
      key="${name##*_}"
      plat="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
      case " $platforms " in
        *" $plat "*) ;;
        *) note "$name is declared but '$plat' is NOT in TB_KUBELET_RESERVATION_PLATFORMS" \
             "A value the writer never emits: to a reader of the file the platform looks measured," \
             "and to the node it is not. Either list it or delete it." ;;
      esac ;;
  esac
done
if [ -n "$platforms" ]; then
  grep -qE -- '^[[:space:]]*TB_KUBELET_EVICTION_MEM_MIB[[:space:]]*=' <<<"$bsh_body" \
    || note "platforms are measured but TB_KUBELET_EVICTION_MEM_MIB is not declared" \
         "The eviction threshold is written for every measured platform."
fi
evict="$(value_of "$bsh_body" TB_KUBELET_EVICTION_MEM_MIB)"
if [[ "$evict" =~ ^[0-9]+$ ]] && [ "$evict" -lt "$TB_KUBELET_DEFAULT_EVICTION_MEM_MIB" ]; then
  note "evictionHard memory.available (${evict}Mi) is LOOSER than the kubelet's own default (${TB_KUBELET_DEFAULT_EVICTION_MEM_MIB}Mi)" \
    "Declaring a threshold is the point; declaring one below the upstream default inverts it."
fi

# The WRITER in each twin must actually EMIT the maps -- a declared table nothing
# reads is the silent no-op again. Keyed on the YAML keys the kubelet reads, and
# SCOPED TO THE WRITER FUNCTION'S OWN BODY: the existing-cluster advisory greps
# the same `kubeReserved:` key out of the file on disk, so a whole-file search
# was satisfied by the advisory while the writer emitted nothing. Its own mutation
# ("bash writer stops emitting kubeReserved") read VACUOUS before this scoping.
bsh_writer="$(awk '/^_write_kubelet_config\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$BASH_LIB")"
ps1_writer="$(awk '/^function Write-KubeletConfig/{f=1} f{print} f&&/^\}$/{exit}' "$PS1_FILE")"
[ -n "$bsh_writer" ] || note "could not extract _write_kubelet_config's body from cluster.sh" \
  "Refusing to report on an empty extraction -- zero lines satisfy every check below."
[ -n "$ps1_writer" ] || note "could not extract Write-KubeletConfig's body from install-k8s.ps1" \
  "Refusing to report on an empty extraction -- zero lines satisfy every check below."
for pair in "cluster.sh:$bsh_writer" "install-k8s.ps1:$ps1_writer"; do
  fname="${pair%%:*}"; body="${pair#*:}"
  [ -n "$body" ] || continue
  for yk in 'kubeReserved:' 'systemReserved:' 'evictionHard:' 'memory.available:'; do
    grep -qF -- "$yk" <<<"$body" \
      || note "$fname's writer never emits \`$yk\` into the drop-in" \
           "The reservation table is declared but the file the kubelet reads does not carry it."
  done
done

if [ "$findings" -gt 0 ]; then
  printf '\nkubelet-config-agreement: %d finding(s).\n' "$findings"
  exit 1
fi
printf '\nkubelet-config-agreement: clean -- both installers emit the same drop-in, the band is usable, the reservation block agrees, and the kubelet is pointed at the file that is mounted.\n'
exit 0
