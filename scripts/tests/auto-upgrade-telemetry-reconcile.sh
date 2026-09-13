#!/usr/bin/env bash
#
#  auto-upgrade-telemetry-reconcile.sh — the hourly auto-upgrade tick must
#  re-render the deployed chart IN PLACE once the telemetry Collector's token
#  Secret exists, and must do so under exactly one condition (backend#3550).
#
#  WHY THIS EXISTS. The Collector's three-state rule (`telemetryCollector.enabled`
#  unset -> collect iff the token Secret exists, else record `skipped-no-token`)
#  is decided by a template `lookup`, which runs only inside a `helm upgrade`. The
#  tick used to upgrade only onto a NEWER published chart, so the Secret
#  appearing triggered nothing; the status record nevertheless promised the skip
#  "resolves itself". Measured: Secret present within minutes, three ticks, no
#  Collector, until a new chart happened to ship a day later.
#
#  WHAT IT ASSERTS, by DRIVING the rendered script (the exact bytes the fleet
#  runs) with a stub `helm` on PATH — never by reading it:
#
#    reconcile  iff  stored state == skipped-no-token
#                AND the stored manifest carries no Collector DaemonSet
#                AND a server-side dry-run of the DEPLOYED version resolves `enabled`
#                AND the repo actually serves that version
#    any other combination -> the tick behaves exactly as before (no upgrade)
#    unreadable state (manifest, dry-run, repo) -> NO upgrade, and the log says
#                so — "cannot tell" is a finding, never a silent pass
#
#  The condition lives in ONE function (`telemetry_reconcile_verdict`), so the
#  table below is ALSO driven against that function directly, extracted from the
#  same render — the test and its mutation (auto-upgrade-telemetry-reconcile-
#  mutations.sh) both call the real code, never a copy of it.
#
#  FIXTURES ARE RENDERED, NOT TYPED. Every stored manifest / dry-run body is a
#  real `helm template` of this chart, so the awk that locates the status record
#  and the DaemonSet is exercised against the shape helm actually emits. The
#  names the script matches on come from the rendered CronJob's own env, exactly
#  as in the pod.
#
#  Exit 0 all cases hold, 1 a case failed, 2 could not set the scenario up.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 2; }

echo "== auto-upgrade reconciles the telemetry Collector in place (backend#3550) =="

WORK="$(mktemp -d -t auto-upgrade-3550.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

KUBE_VERSION="${HELM_KUBE_VERSION:-1.28.0}"
render() { # $1 = --show-only template, rest = extra --set flags
  local tpl="$1"; shift
  helm template t client \
    --kube-version "$KUBE_VERSION" \
    --set clientId=x --set clientPassword=y --set storageClass.create=false \
    "$@" --show-only "$tpl"
}

# --- the script and its env, from the rendered CronJob --------------------------
render templates/auto-upgrade-cronjob.yaml >"$WORK/cronjob.yaml"
SCRIPT="$WORK/auto-upgrade.sh"
ENVFILE="$WORK/telemetry.env"
python3 - "$WORK/cronjob.yaml" "$SCRIPT" "$ENVFILE" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
src, out, envout = sys.argv[1], sys.argv[2], sys.argv[3]
script = env = None
for d in yaml.safe_load_all(open(src)):
    if not d:
        continue
    if d.get("kind") == "ConfigMap" and "auto-upgrade.sh" in (d.get("data") or {}):
        script = d["data"]["auto-upgrade.sh"]
    if d.get("kind") == "CronJob":
        c = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e.get("value", "") for e in c.get("env", [])}
if script is None:
    sys.exit("[ERROR] no ConfigMap carrying auto-upgrade.sh was rendered")
if env is None:
    sys.exit("[ERROR] no CronJob was rendered")
open(out, "w").write(script)
names = ["TELEMETRY_STATUS_NAME", "TELEMETRY_STATUS_ANNOTATION", "TELEMETRY_COLLECTOR_NAME"]
missing = [n for n in names if not env.get(n)]
if missing:
    sys.exit("[ERROR] the CronJob env does not carry %s — the script would have nothing to match on" % ", ".join(missing))
with open(envout, "w") as f:
    for n in names:
        f.write("%s=%s\n" % (n, env[n]))
PY
[ -s "$SCRIPT" ] || { echo "[ERROR] extracted script is empty" >&2; exit 2; }
# shellcheck disable=SC1090
. "$ENVFILE"
export TELEMETRY_STATUS_NAME TELEMETRY_STATUS_ANNOTATION TELEMETRY_COLLECTOR_NAME

# --- rendered fixtures ----------------------------------------------------------
# Offline, `lookup` is empty, so fleet mode resolves `enabled`; the states a live
# cluster produces are reached by rewriting ONLY the state token of a real render.
FULL_ON="$WORK/manifest-enabled.yaml"     # status enabled + Collector DaemonSet
FULL_OFF="$WORK/manifest-disabled.yaml"   # status disabled-by-operator, no DaemonSet
helm template t client --kube-version "$KUBE_VERSION" \
  --set clientId=x --set clientPassword=y --set storageClass.create=false \
  --set telemetryCollector.enabled=true  >"$FULL_ON"
helm template t client --kube-version "$KUBE_VERSION" \
  --set clientId=x --set clientPassword=y --set storageClass.create=false \
  --set telemetryCollector.enabled=false >"$FULL_OFF"
# The fixtures are only meaningful if the real render carries what we rewrite.
grep -q "^  name: ${TELEMETRY_STATUS_NAME}\$" "$FULL_ON" \
  || { echo "[ERROR] rendered chart carries no ConfigMap named $TELEMETRY_STATUS_NAME" >&2; exit 2; }
grep -q "^  name: ${TELEMETRY_COLLECTOR_NAME}\$" "$FULL_ON" \
  || { echo "[ERROR] enabled render carries no object named $TELEMETRY_COLLECTOR_NAME" >&2; exit 2; }
if grep -q "^  name: ${TELEMETRY_COLLECTOR_NAME}\$" "$FULL_OFF"; then
  echo "[ERROR] disabled render still carries $TELEMETRY_COLLECTOR_NAME — fixture premise broken" >&2; exit 2
fi
grep -q '"disabled-by-operator"' "$FULL_OFF" || { echo "[ERROR] disabled render lacks its state token" >&2; exit 2; }
grep -q '"enabled"' "$FULL_ON" || { echo "[ERROR] enabled render lacks its state token" >&2; exit 2; }

NO_TOKEN="$WORK/manifest-no-token.yaml"       # what a live cluster without the Secret stores
sed 's/"disabled-by-operator"/"skipped-no-token"/g' "$FULL_OFF" >"$NO_TOKEN"
INCOMPLETE="$WORK/manifest-incomplete.yaml"
sed 's/"disabled-by-operator"/"skipped-incomplete-values"/g' "$FULL_OFF" >"$INCOMPLETE"
CONTRADICTORY="$WORK/manifest-contradictory.yaml"  # record says skipped, DaemonSet present
sed 's/"enabled"/"skipped-no-token"/g' "$FULL_ON" >"$CONTRADICTORY"
NO_RECORD="$WORK/manifest-no-record.yaml"     # a release rendered before the record existed
python3 - "$FULL_OFF" "$NO_RECORD" "$TELEMETRY_STATUS_NAME" <<'PY'
import sys
src, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
docs = open(src).read().split("\n---\n")
kept = [d for d in docs if ("\n  name: %s\n" % name) not in d and not d.startswith("  name: %s\n" % name)]
if len(kept) != len(docs) - 1:
    sys.exit("[ERROR] expected to drop exactly one document (the status record), dropped %d" % (len(docs) - len(kept)))
open(out, "w").write("\n---\n".join(kept))
PY

# --- a stub `helm` that answers from harness variables --------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/helm" <<'STUB'
#!/bin/sh
# Stub helm for the backend#3550 reconcile gate. Harness variables:
#   STUB_LATEST        newest version the repo lists (plain `helm search repo`)
#   STUB_SERVED        space-separated versions `helm search repo --version X` finds
#   STUB_CURRENT       deployed chart version (`helm list` -> chart: client-<v>)
#   STUB_MANIFEST_FILE body for `helm get manifest` (STUB_MANIFEST_FAIL=1 -> exit 1)
#   STUB_DRYRUN_FILE   body for `helm upgrade --dry-run=server` (STUB_DRYRUN_FAIL=1 -> exit 1)
#   UPGRADE_MARKER     touched by a REAL `helm upgrade`; its args land in UPGRADE_ARGS
#   DRYRUN_MARKER      touched by a dry-run upgrade
sub="$1"; shift 2>/dev/null || true
case "$sub" in
  repo) exit 0 ;;
  status) printf 'NAME: %s\nSTATUS: deployed\nREVISION: 3\n' "$1" ;;
  list) echo "chart: client-${STUB_CURRENT}" ;;
  search)
    want=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--version" ]; then want="$2"; shift; fi
      shift
    done
    # Real `helm search repo -o yaml` shape: a list item whose `version:` sits on
    # its own indented line — the script's awk keys on exactly that.
    if [ -z "$want" ]; then
      printf -- '- name: tracebloc/client\n  version: %s\n' "${STUB_LATEST}"
    else
      hit=no
      for v in ${STUB_SERVED}; do [ "$v" = "$want" ] && hit=yes; done
      if [ "$hit" = yes ]; then printf -- '- name: tracebloc/client\n  version: %s\n' "${want}"; else echo "[]"; fi
    fi
    ;;
  get)
    [ "$1" = manifest ] || { echo "stub: unexpected helm get $1" >&2; exit 1; }
    [ "${STUB_MANIFEST_FAIL:-0}" = 1 ] && { echo "Error: release: not found" >&2; exit 1; }
    cat "$STUB_MANIFEST_FILE"
    ;;
  upgrade)
    dry=no
    for a in "$@"; do [ "$a" = "--dry-run=server" ] && dry=yes; done
    if [ "$dry" = yes ]; then
      : >"$DRYRUN_MARKER"
      [ "${STUB_DRYRUN_FAIL:-0}" = 1 ] && { echo "Error: lookup forbidden" >&2; exit 1; }
      cat "$STUB_DRYRUN_FILE"
    else
      : >"$UPGRADE_MARKER"
      printf '%s\n' "$@" >"$UPGRADE_ARGS"
      echo "upgraded"
    fi
    ;;
  rollback) echo "stub: rollback should not be reached" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/helm"

fails=0
pass=0

# Common harness env for one run. Markers are reset per case.
setup_case() {
  UPGRADE_MARKER="$WORK/upgrade.marker"; DRYRUN_MARKER="$WORK/dryrun.marker"
  UPGRADE_ARGS="$WORK/upgrade.args"; OUT="$WORK/out.txt"
  rm -f "$UPGRADE_MARKER" "$DRYRUN_MARKER" "$UPGRADE_ARGS" "$OUT"
  export UPGRADE_MARKER DRYRUN_MARKER UPGRADE_ARGS
  export RELEASE_NAME=t RELEASE_NAMESPACE=tracebloc REPO_URL=https://example.invalid \
         REPO_NAME=tracebloc CHART_NAME=client UPGRADE_TIMEOUT=10m WEDGE_MIN_AGE_SECONDS=2700
}

# run_tick LABEL EXPECT(reconcile|upgrade|none) EXPECT_LOG_SUBSTRING [ENV=VAL ...]
# `reconcile` = a real upgrade pinned to STUB_CURRENT; `upgrade` = a real upgrade
# to STUB_LATEST with NO dry-run consulted; `none` = no real upgrade at all.
run_tick() {
  local label="$1" expect="$2" want="$3"; shift 3
  setup_case
  local rc=0
  env PATH="$BIN:$PATH" "$@" sh "$SCRIPT" >"$OUT" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  [FAIL] $label: tick exited $rc (must exit 0 — a no-op is not a failure)"; sed 's/^/      | /' "$OUT"; fails=$((fails+1)); return
  fi
  local upgraded=no; [ -e "$UPGRADE_MARKER" ] && upgraded=yes
  local dry=no; [ -e "$DRYRUN_MARKER" ] && dry=yes
  case "$expect" in
    reconcile)
      if [ "$upgraded" != yes ]; then
        echo "  [FAIL] $label: expected a same-version reconcile, no upgrade ran"; sed 's/^/      | /' "$OUT"; fails=$((fails+1)); return
      fi
      if ! grep -qx -- "--version" "$UPGRADE_ARGS" || ! grep -qx -- "$STUB_CURRENT_FOR_ASSERT" "$UPGRADE_ARGS"; then
        echo "  [FAIL] $label: reconcile did not pin --version $STUB_CURRENT_FOR_ASSERT"; sed 's/^/      | /' "$UPGRADE_ARGS"; fails=$((fails+1)); return
      fi
      for flag in --reset-then-reuse-values --atomic --cleanup-on-fail; do
        grep -qx -- "$flag" "$UPGRADE_ARGS" || { echo "  [FAIL] $label: reconcile dropped $flag"; fails=$((fails+1)); return; }
      done
      ;;
    upgrade)
      if [ "$upgraded" != yes ]; then
        echo "  [FAIL] $label: expected the normal upgrade, none ran"; sed 's/^/      | /' "$OUT"; fails=$((fails+1)); return
      fi
      if [ "$dry" = yes ]; then
        echo "  [FAIL] $label: a newer chart was available yet the reconcile dry-run ran — the upgrade itself re-renders"; fails=$((fails+1)); return
      fi
      ;;
    none)
      if [ "$upgraded" = yes ]; then
        echo "  [FAIL] $label: an upgrade RAN where the condition does not hold"; sed 's/^/      | /' "$OUT"; fails=$((fails+1)); return
      fi
      ;;
    *) echo "[ERROR] bad expectation '$expect'" >&2; exit 2 ;;
  esac
  if ! grep -qF -- "$want" "$OUT"; then
    echo "  [FAIL] $label: log did not say '$want'"; sed 's/^/      | /' "$OUT"; fails=$((fails+1)); return
  fi
  echo "  [OK]   $label"
  pass=$((pass+1))
}

# Every script-level case pins the deployed version it expects a reconcile to name.
STUB_CURRENT_FOR_ASSERT=9.9.9
COMMON="STUB_LATEST=9.9.9 STUB_SERVED=9.9.9 STUB_CURRENT=9.9.9"

echo "-- the tick, end to end --"
# shellcheck disable=SC2086
run_tick "Secret arrived: stored skipped-no-token, no DaemonSet, dry-run enabled -> reconcile" reconcile \
  "reconcile: token Secret is now present" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "Secret still absent: dry-run still skipped-no-token -> no upgrade" none \
  "already at latest" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$NO_TOKEN"
# shellcheck disable=SC2086
run_tick "Collector already enabled -> no upgrade" none \
  "already at latest" $COMMON STUB_MANIFEST_FILE="$FULL_ON" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "operator opted out (disabled-by-operator) -> no upgrade" none \
  "already at latest" $COMMON STUB_MANIFEST_FILE="$FULL_OFF" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "skipped-incomplete-values is out of scope -> no upgrade" none \
  "already at latest" $COMMON STUB_MANIFEST_FILE="$INCOMPLETE" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "release predates the status record -> no upgrade" none \
  "already at latest" $COMMON STUB_MANIFEST_FILE="$NO_RECORD" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "contradictory: record says skipped but the DaemonSet is deployed -> no upgrade, said loudly" none \
  "contradictory" $COMMON STUB_MANIFEST_FILE="$CONTRADICTORY" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "unreadable manifest -> no upgrade, cannot tell is logged" none \
  "cannot tell" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_MANIFEST_FAIL=1 STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "dry-run fails -> no upgrade, cannot tell is logged" none \
  "cannot tell" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON" STUB_DRYRUN_FAIL=1
# shellcheck disable=SC2086
run_tick "dry-run body carries no record -> no upgrade, cannot tell is logged" none \
  "cannot tell" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$NO_RECORD"
run_tick "deployed AHEAD of the index (dev chart): repo cannot serve it -> no upgrade, named" none \
  "is not served by" STUB_LATEST=9.9.9 STUB_SERVED=9.9.9 STUB_CURRENT=9.9.10 \
  STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON"
run_tick "a newer chart exists -> the normal upgrade runs and the reconcile is not consulted" upgrade \
  "upgrading 9.9.8 -> 9.9.9" STUB_LATEST=9.9.9 STUB_SERVED="9.9.8 9.9.9" STUB_CURRENT=9.9.8 \
  STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_tick "names missing from env -> no upgrade, cannot tell is logged (fails closed)" none \
  "inputs missing" $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON" \
  TELEMETRY_STATUS_NAME= TELEMETRY_COLLECTOR_NAME=

# --- the condition function itself, extracted from the same render --------------
# Everything between the begin/end markers, so the helpers it calls come with it.
FN="$WORK/reconcile-block.sh"
awk '/telemetry Collector same-version reconcile: begin/{c=1} c{print} c && /telemetry Collector same-version reconcile: end/{exit}' "$SCRIPT" >"$FN"
grep -q 'telemetry_reconcile_verdict()' "$FN" \
  || { echo "[ERROR] could not extract telemetry_reconcile_verdict from the rendered script" >&2; exit 2; }

# run_fn LABEL EXPECT_RC EXPECT_SUBSTRING [ENV=VAL ...]
run_fn() {
  local label="$1" want_rc="$2" want="$3"; shift 3
  setup_case
  local rc=0 out
  out="$(env PATH="$BIN:$PATH" CURRENT=9.9.9 LATEST=9.9.9 "$@" \
        sh -c '. "$0"; telemetry_reconcile_verdict' "$FN" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "  [FAIL] $label: verdict rc $rc, wanted $want_rc ($out)"; fails=$((fails+1)); return
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    echo "  [FAIL] $label: rc $rc as wanted but the reason did not say '$want': $out"; fails=$((fails+1)); return
  fi
  echo "  [OK]   $label (rc $rc)"
  pass=$((pass+1))
}

echo "-- telemetry_reconcile_verdict, the one condition --"
# shellcheck disable=SC2086
run_fn "0: skipped-no-token + no DaemonSet + dry-run enabled" 0 "token Secret is now present" \
  $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "1: dry-run still skipped-no-token" 1 "would still decide 'skipped-no-token'" \
  $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$NO_TOKEN"
# shellcheck disable=SC2086
run_fn "1: stored enabled" 1 "state is 'enabled'" $COMMON STUB_MANIFEST_FILE="$FULL_ON" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "1: stored disabled-by-operator" 1 "state is 'disabled-by-operator'" \
  $COMMON STUB_MANIFEST_FILE="$FULL_OFF" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "1: no record" 1 "no telemetry status record" $COMMON STUB_MANIFEST_FILE="$NO_RECORD" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "2: contradictory record vs DaemonSet" 2 "contradictory" \
  $COMMON STUB_MANIFEST_FILE="$CONTRADICTORY" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "2: manifest unreadable" 2 "cannot read the deployed manifest" \
  $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_MANIFEST_FAIL=1 STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "2: dry-run failed" 2 "dry-run of 9.9.9 failed" \
  $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON" STUB_DRYRUN_FAIL=1
run_fn "2: repo does not serve the deployed version" 2 "is not served by" \
  STUB_LATEST=9.9.8 STUB_SERVED=9.9.8 STUB_CURRENT=9.9.9 STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON"
# shellcheck disable=SC2086
run_fn "2: env names missing" 2 "inputs missing" \
  $COMMON STUB_MANIFEST_FILE="$NO_TOKEN" STUB_DRYRUN_FILE="$FULL_ON" TELEMETRY_STATUS_ANNOTATION=

if [ "$fails" -ne 0 ]; then
  echo "[ERROR] $fails case(s) failed, $pass passed: the same-version reconcile condition is broken (backend#3550)" >&2
  exit 1
fi
[ "$pass" -gt 0 ] || { echo "[ERROR] zero cases ran — refusing to report green" >&2; exit 2; }
echo "  [OK] all $pass cases: the tick re-renders exactly when the Secret has arrived, and never on 'cannot tell'"
