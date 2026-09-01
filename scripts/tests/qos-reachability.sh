#!/usr/bin/env bash
# qos-reachability.sh — is Guaranteed QoS REACHABLE through values, per pod?
#
# WHY THIS EXISTS, and it is this PR's own subject one turn deeper. The QoS
# goldens pin two things: each pod's CLASS, and the SET of init containers that
# carry no resources at all. Neither is reachability. So when #942 added
# `wait-for-mysql` -- unconditional, resourced, and unequal on BOTH dimensions --
# every QoS guard stayed green while two comments in the chart went false:
# `values.yaml` and `jobs-manager-deployment.yaml` both said equalising cpu buys
# Guaranteed for jobs-manager on a CSI cluster, and after #942 it buys Guaranteed
# nowhere. A claim with no assertion behind it went stale in silence, in the
# branch built to stop exactly that (backend#2872, review on client#922).
#
# WHAT IT ASSERTS. For each profile: equalise EVERY resources.* knob the chart
# exposes, render, and classify. A pod that is still not Guaranteed after that
# cannot be made Guaranteed through values by anyone, and the containers named as
# blockers are the reason. That verdict is compared against a golden.
#
# DERIVED, NOT RESTATED, in both directions:
#   * the knob list comes out of `client/values.schema.json`, so a resources key
#     added tomorrow is equalised tomorrow and this file holds no copy of it;
#   * the QoS rule is not reimplemented here -- `pod-qos-class.py` is called, so
#     there is one implementation of ComputePodQOS in the tree (workspace
#     CLAUDE.md rule 9: a check that re-implements the rule inline proves a copy);
#   * the golden is compared by SET EQUALITY both ways, so a pod that appears
#     fails until classified and a stale row fails rather than being satisfied by
#     nothing.
#
# WHAT IT CANNOT SEE, stated because a guard that overclaims is the thing being
# fixed here. It answers "reachable through VALUES", not "reachable at all": a
# chart edit (resourcing `wait-for-mysql`, or pod-level resources under
# KEP-2837) reaches Guaranteed and this guard will still say `blocked` -- which
# is correct for the claims it guards, since those are claims about what an
# operator can do. It also equalises to ONE value per dimension rather than
# searching the space; that is sufficient, because requests == limits is the
# whole of the Guaranteed condition and any equal pair satisfies it identically.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="$REPO_ROOT/client"
QOS="$REPO_ROOT/scripts/tests/pod-qos-class.py"
GOLDEN="$REPO_ROOT/scripts/tests/qos-reachability-expect.txt"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qos-reach.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
note() { printf '   %s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*" >&2; fail=$((fail + 1)); }

for t in helm python3; do
  command -v "$t" >/dev/null 2>&1 || { err "$t is not on PATH, so reachability was never evaluated"; exit 2; }
done
[ -f "$QOS" ]    || { err "pod-qos-class.py is missing; this guard classifies through it, not with its own copy of the rule"; exit 2; }
[ -f "$GOLDEN" ] || { err "$GOLDEN is missing, so there is nothing to compare against -- an absent golden is not agreement"; exit 2; }

# --- the knob list, derived from the schema ----------------------------------
# CPU 1000m / memory 1Gi satisfy the schema's own patterns (^[0-9]+m?$ and
# ^[0-9]+(Ki|Mi|Gi|Ti)$). `--set-string` is required: `--set` types a bare number
# as an int and the schema demands a string, which fails validation rather than
# rendering -- and a render that failed must never read as "no findings".
# NO `mapfile`, DELIBERATELY: it is bash 4+, this repo's dev machines run the
# macOS system bash 3.2, and no other guard in scripts/tests uses it -- so this
# file would have been the only one that could not run locally. Measured: on
# 3.2.57 it aborts with "SETS[@]: unbound variable".
python3 - "$CHART/values.schema.json" > "$TMP/knobs.txt" <<'SCHEMAPY'
import json, sys
schema = json.load(open(sys.argv[1]))
res = schema.get("properties", {}).get("resources", {}).get("properties", {})
VALUE = {"cpu": "1000m", "memory": "1Gi"}
out = []
for group, gspec in sorted(res.items()):
    props = gspec.get("properties", {})
    # Only groups exposing BOTH sides can be equalised; one-sided groups are
    # reported so a schema change cannot silently shrink the domain.
    if not ({"requests", "limits"} <= set(props)):
        print(f"#ONESIDED {group}")
        continue
    dims = set(props["requests"].get("properties", {})) & set(props["limits"].get("properties", {}))
    if not dims:
        print(f"#NODIMS {group}")
        continue
    for dim in sorted(dims):
        v = VALUE.get(dim)
        if v is None:
            print(f"#UNKNOWNDIM {group}.{dim}")
            continue
        out.append(f"resources.{group}.requests.{dim}={v}")
        out.append(f"resources.{group}.limits.{dim}={v}")
for line in out:
    print(line)
SCHEMAPY
if [ ! -s "$TMP/knobs.txt" ]; then
  err "the schema enumeration produced no output at all -- it did not run, so no verdict below would be evidence"
  exit 1
fi

KNOBS=(); NOTES=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "#"*) NOTES+=("$line") ;;
    *)    KNOBS+=(--set-string "$line") ;;
  esac
done < "$TMP/knobs.txt"
# bash 3.2 under `set -u` treats an EMPTY array as unbound, so this expansion is
# guarded by the count rather than attempted blindly.
if [ "${#NOTES[@]}" -gt 0 ]; then
  for n in "${NOTES[@]}"; do
    err "the schema exposes a resources group this guard cannot equalise ($n), so 'unreachable' below would not be evidence"
  done
fi
# FAIL CLOSED. Zero knobs equalises nothing, so every pod would report blocked
# and the guard would look like it was working hardest exactly when it was doing
# nothing at all.
[ "${#KNOBS[@]}" -gt 0 ] || { err "derived ZERO resources knobs from values.schema.json -- the enumeration is broken, and with nothing equalised every verdict below would be meaningless"; exit 1; }
note "equalising ${#KNOBS[@]} values setting(s) derived from values.schema.json"

# --- render + classify per profile -------------------------------------------
: > "$TMP/actual.txt"
for hp in true false; do
  out="$TMP/render-$hp.yaml"
  if ! helm template t "$CHART" \
        --set "hostPath.enabled=$hp" \
        --set storageClass.create=false \
        --set clientId=probe --set clientPassword=probe \
        "${KNOBS[@]}" > "$out" 2>"$out.err"; then
    err "helm template failed for hostPath=$hp, so reachability was not evaluated for it: $(tr '\n' ' ' < "$out.err" | cut -c1-300)"
    continue
  fi
  if ! rows=$(python3 "$QOS" "$out" 2>"$TMP/qos.err"); then
    err "pod-qos-class.py refused the hostPath=$hp render: $(tr '\n' ' ' < "$TMP/qos.err" | cut -c1-300)"
    continue
  fi
  while IFS=$'\t' read -r name cls why; do
    [ -n "${name:-}" ] || continue
    if [ "$cls" = "Guaranteed" ]; then
      printf '%s\thostPath=%s\treachable\t-\n' "$name" "$hp" >> "$TMP/actual.txt"
    else
      # THE BLOCKING CONTAINER NAMES, NOT THEIR NUMBERS. The first version pinned
      # the classifier's full reason string, which carries the actual quantities
      # -- so bumping squid's cpu limit, an edit with nothing to do with QoS,
      # would have reddened this guard and trained the next person to refresh the
      # golden without reading it. The property under test is WHICH containers
      # block Guaranteed: a new blocker appearing (what #942 did) changes the set,
      # a resource bump does not.
      blockers=$(printf '%s' "$why" | tr ';' '\n' | sed 's/^ *//; s/:.*$//' \
                   | grep -v '^$' | sort -u | paste -sd, -)
      printf '%s\thostPath=%s\tblocked\t%s\n' "$name" "$hp" "$blockers" >> "$TMP/actual.txt"
    fi
  done <<< "$rows"
done

[ -s "$TMP/actual.txt" ] || { err "classified ZERO pods across both profiles -- nothing was checked, which is not the same as nothing being wrong"; exit 1; }

# --- compare to the golden, both directions ---------------------------------
grep -vE '^\s*(#|$)' "$GOLDEN" | sort > "$TMP/want.txt"
sort "$TMP/actual.txt" > "$TMP/got.txt"

if ! diff -u "$TMP/want.txt" "$TMP/got.txt" > "$TMP/diff.txt"; then
  err "the reachability verdicts no longer match $GOLDEN:"
  sed 's/^/          /' "$TMP/diff.txt" >&2
  err "if this is an intended change, update the golden IN THIS PR and say which claim in the chart it makes true or false -- that is the step #942 skipped"
fi

if [ "$fail" -ne 0 ]; then
  printf '[FAIL] Guaranteed-QoS reachability disagrees with the recorded verdicts (%d finding(s)).\n' "$fail" >&2
  exit 1
fi
note "[OK] $(wc -l < "$TMP/got.txt" | tr -d ' ') pod/profile verdict(s) match the recorded Guaranteed-QoS reachability"
