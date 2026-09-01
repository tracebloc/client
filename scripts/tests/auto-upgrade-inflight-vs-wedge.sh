#!/usr/bin/env bash
#
#  auto-upgrade-inflight-vs-wedge.sh — the hourly auto-upgrade CronJob must NOT
#  roll back an operator's IN-PROGRESS `helm upgrade` (tracebloc/client#2877).
#
#  WHY THIS EXISTS. #554 taught the CronJob to auto-recover a release stuck in
#  `pending-upgrade` — a wedge left by a killed upgrade — by rolling it back. But
#  `pending-upgrade` is ALSO the state of an upgrade that is CURRENTLY RUNNING.
#  The detector could not tell them apart, so the unattended hourly tick rolled
#  back a legitimate in-flight `helm upgrade`, silently reverting it and
#  discarding the operator's new values. Measured on a real prod-shaped fleet
#  turning a backend#1528 retirement into a fleet-breaking sequence.
#
#  The fix discriminates by AGE: a real wedge is old (>= autoUpgrade
#  .pendingWedgeMinAge), an in-flight upgrade is seconds/minutes old. This gate
#  DRIVES the rendered script — it does not read it — putting a stub `helm` on
#  PATH and asserting the rollback fires for an OLD pending-upgrade and NEVER for
#  a RECENT one (issue acceptance: "asserted by driving both concurrently, not by
#  reading the script"). It also exercises the RFC3339 zone-offset math (a naive
#  parser that ignored the offset would misclassify a recent upgrade stamped in a
#  negative-offset zone as an old wedge) and the fail-safe on an unparseable
#  timestamp (never clobber).
#
#  jq-free on purpose, mirroring the alpine/helm image the CronJob runs on.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== auto-upgrade discriminates in-flight from wedged (#2877) =="

WORK="$(mktemp -d -t auto-upgrade-2877.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- extract the rendered CronJob script (the exact bytes the fleet runs) ------
KUBE_VERSION="${HELM_KUBE_VERSION:-1.28.0}"
helm template t client \
  --kube-version "$KUBE_VERSION" \
  --set clientId=x --set clientPassword=y --set storageClass.create=false \
  --show-only templates/auto-upgrade-cronjob.yaml >"$WORK/rendered.yaml"

SCRIPT="$WORK/auto-upgrade.sh"
python3 - "$WORK/rendered.yaml" "$SCRIPT" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
src, out = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(src)):
    if d and d.get("kind") == "ConfigMap" and "auto-upgrade.sh" in (d.get("data") or {}):
        open(out, "w").write(d["data"]["auto-upgrade.sh"])
        break
else:
    sys.exit("[ERROR] no ConfigMap carrying auto-upgrade.sh was rendered")
PY
[ -s "$SCRIPT" ] || { echo "[ERROR] extracted script is empty" >&2; exit 1; }

# --- a stub `helm` that reports a configurable pending status ------------------
# It records rollback/upgrade so the assertions read outcomes, not logs.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/helm" <<'STUB'
#!/bin/sh
# Stub helm for the #2877 discrimination test. STUB_STATUS / STUB_STATUS_JSON
# are supplied by the harness; ROLLBACK_MARKER / UPGRADE_MARKER are touched so
# the harness can assert what the script actually did.
sub="$1"; shift 2>/dev/null || true
case "$sub" in
  repo) exit 0 ;;
  status)
    is_json=no
    for a in "$@"; do [ "$a" = json ] && is_json=yes; done
    if [ "$is_json" = yes ]; then
      printf '%s' "$STUB_STATUS_JSON"
    else
      printf 'NAME: %s\nLAST DEPLOYED: now\nSTATUS: %s\nREVISION: 5\n' "$1" "$STUB_STATUS"
    fi
    ;;
  rollback) : > "$ROLLBACK_MARKER"; echo "Rollback was a success! Happy Helming!" ;;
  upgrade)  : > "$UPGRADE_MARKER";  echo "upgraded" ;;
  # Make the release look already-at-latest so a genuine wedge recovery does not
  # fall through into a real upgrade attempt — keeps each case about the rollback.
  search) echo "version: 9.9.9" ;;
  list)   echo "chart: client-9.9.9" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/helm"

# --- drive the script once per case -------------------------------------------
# $1 label  $2 rfc3339 last_deployed  $3 expect: "rollback" | "skip"
# $4 shape: "compact" (what helm actually emits) | "pretty" (defensive). Every
# case runs under BOTH shapes (see the loop below) so the REAL compact output and
# a hypothetical indented one are both pinned (backend#2896).
run_case() {
  label="$1"; ld="$2"; expect="$3"; shape="${4:-compact}"
  rb="$WORK/rollback.$$"; up="$WORK/upgrade.$$"
  rm -f "$rb" "$up"
  json="$(status_json "$shape" "$ld")"
  rc=0
  env PATH="$BIN:$PATH" \
    RELEASE_NAME=stg RELEASE_NAMESPACE=tracebloc \
    REPO_URL=https://example.invalid REPO_NAME=tracebloc CHART_NAME=client \
    UPGRADE_TIMEOUT=10m WEDGE_MIN_AGE_SECONDS=2700 \
    STUB_STATUS=pending-upgrade STUB_STATUS_JSON="$json" \
    ROLLBACK_MARKER="$rb" UPGRADE_MARKER="$up" \
    sh "$SCRIPT" >"$WORK/out.$$" 2>&1 || rc=$?

  rolled=no; [ -e "$rb" ] && rolled=yes
  if [ "$rc" -ne 0 ]; then
    echo "  [FAIL] $label: script exited $rc"; sed 's/^/      | /' "$WORK/out.$$"; return 1
  fi
  case "$expect" in
    rollback)
      if [ "$rolled" != yes ]; then
        echo "  [FAIL] $label: expected a rollback (old wedge), none happened"
        sed 's/^/      | /' "$WORK/out.$$"; return 1
      fi
      grep -q "WARNING" "$WORK/out.$$" \
        || { echo "  [FAIL] $label: wedge rollback surfaced no visible warning"; return 1; }
      # backend#2896: the loud warning MUST name the discarded revision (the
      # fixture's version 5). PENDING_REV must parse it under BOTH the compact
      # `"version":5` helm emits and a spaced `"version": 5`, so this pins the
      # `[ ]*` tolerance is present and correct under whichever shape is running.
      grep -q "(revision 5)" "$WORK/out.$$" \
        || { echo "  [FAIL] $label: warning omitted the discarded revision number (PENDING_REV parse, backend#2896)"; sed 's/^/      | /' "$WORK/out.$$"; return 1; }
      echo "  [OK]   $label: aged-out wedge rolled back, warning names the discarded revision" ;;
    skip)
      if [ "$rolled" = yes ]; then
        echo "  [FAIL] $label: in-flight upgrade was ROLLED BACK — the #2877 regression"
        sed 's/^/      | /' "$WORK/out.$$"; return 1
      fi
      grep -q "NOT rolling back" "$WORK/out.$$" \
        || { echo "  [FAIL] $label: recent pending was not explicitly skipped"; return 1; }
      echo "  [OK]   $label: in-flight upgrade left untouched, tick skipped" ;;
  esac
}

# RFC3339 timestamps relative to now, generated jq-free.
ts_utc()   { python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())" "$1"; }
ts_offset(){ python3 -c "import datetime,sys;tz=datetime.timezone(datetime.timedelta(hours=int(sys.argv[2])));print((datetime.datetime.now(tz)-datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())" "$1" "$2"; }

# `helm status -o json` body fixtures, in the two shapes we pin (backend#2896):
#
#   compact — what the CronJob's alpine/helm:3.16.4 image ACTUALLY emits. helm's
#     `EncodeJSON` is `json.NewEncoder(out); enc.Encode(obj)` with no `SetIndent`,
#     so the output is single-line with NO space after colons (`"version":5`).
#     This is the real in-cluster shape; the deployed parser must handle it, so
#     it is the default and every case runs under it.
#   pretty — a defensive shape (indented, one field per line, `": "` after each
#     colon) that helm does NOT emit today but a future/indented build could. The
#     `tr -d '\n'` and `[ ]*` hardening exist so the parser survives it too; these
#     fixtures pin that. `json.dumps(..., indent=2)` reproduces it.
#
# NOTE: the backend#2896 Bugbot premise was that the image pretty-prints. It does
# not (verified from helm source + a real image run), so `pretty` is forward-cover,
# not the real shape — keep `compact` as the one that mirrors production.
compact_status_json() { # $1 = rfc3339 last_deployed
  python3 -c 'import json,sys; ld=sys.argv[1]; print(json.dumps({"name":"stg","info":{"first_deployed":ld,"last_deployed":ld,"status":"pending-upgrade"},"version":5,"namespace":"tracebloc"}, separators=(",", ":")))' "$1"
}
pretty_status_json() { # $1 = rfc3339 last_deployed
  python3 -c 'import json,sys; ld=sys.argv[1]; print(json.dumps({"name":"stg","info":{"first_deployed":ld,"last_deployed":ld,"status":"pending-upgrade"},"version":5,"namespace":"tracebloc"}, indent=2))' "$1"
}
status_json() { # $1 = shape (compact|pretty)  $2 = rfc3339 last_deployed
  case "$1" in
    compact) compact_status_json "$2" ;;
    pretty)  pretty_status_json  "$2" ;;
    *) echo "[ERROR] unknown status_json shape '$1'" >&2; return 1 ;;
  esac
}

fails=0

# --- unit assertion: the age parser returns a real age under BOTH shapes -------
# backend#2896 regression guard, aimed straight at the unit Bugbot flagged.
# `pending_age_seconds` must return a non-empty age from BOTH the compact status
# helm actually emits AND a pretty-printed one — the `tr`/`[ ]*` hardening is only
# meaningful if the pretty shape parses, and the compact shape is the production
# path that must never regress. Drive the ACTUAL rendered function (col-0
# definition through its col-0 closing brace) so this pins the shipped bytes.
FN="$WORK/pending_age_seconds.sh"
awk '/pending_age_seconds\(\) \{/{c=1} c{print} c && /^\}$/{exit}' "$SCRIPT" > "$FN"
grep -q 'pending_age_seconds()' "$FN" \
  || { echo "[ERROR] could not extract pending_age_seconds from the rendered script" >&2; exit 1; }
for shape in compact pretty; do
  age="$(sh -c '. "$0"; pending_age_seconds "$1"' "$FN" "$(status_json "$shape" "$(ts_utc 7200)")")"
  case "$age" in
    ''|*[!0-9]*)
      echo "  [FAIL] pending_age_seconds returned empty/non-numeric age '${age}' from $shape status (backend#2896)"
      fails=1 ;;
    *)
      echo "  [OK]   pending_age_seconds parsed a non-empty age (${age}s) from $shape helm output" ;;
  esac
done
# Every case runs under BOTH shapes: `compact` (what helm actually emits, the
# production path) and `pretty` (defensive forward-cover for an indented body).
for shape in compact pretty; do
  # In-flight: started ~2 min ago → must be left alone.
  run_case "[$shape] recent (120s, UTC)"        "$(ts_utc 120)"        skip     "$shape" || fails=1
  # In-flight but only just under the 45m threshold → still left alone.
  run_case "[$shape] recent (40m, UTC)"         "$(ts_utc 2400)"       skip     "$shape" || fails=1
  # In-flight, stamped in a -10:00 zone: the offset MUST be honoured, else the
  # wall-clock reads ~10h in the past and a naive parser would call it a wedge.
  run_case "[$shape] recent (120s, -10:00)"     "$(ts_offset 120 -10)" skip     "$shape" || fails=1
  # Genuine wedge: killed an hour+ ago → recovered.
  run_case "[$shape] wedged (2h, UTC)"          "$(ts_utc 7200)"       rollback "$shape" || fails=1
  # Just over the threshold → recovered.
  run_case "[$shape] wedged (50m, UTC)"         "$(ts_utc 3000)"       rollback "$shape" || fails=1
  # Unparseable timestamp → age indeterminate → fail safe (never clobber).
  run_case "[$shape] unparseable last_deployed" "not-a-timestamp"      skip     "$shape" || fails=1
done

if [ "$fails" -ne 0 ]; then
  echo "[ERROR] auto-upgrade in-flight/wedge discrimination is broken (#2877)" >&2
  exit 1
fi
echo "  [OK] all cases: in-flight upgrades survive, aged-out wedges recover"
