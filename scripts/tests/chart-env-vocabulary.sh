#!/usr/bin/env bash
#
#  chart-env-vocabulary.sh — the CLIENT_ENV / channelTags vocabularies are CLOSED
#
#  WHY THIS IS A SHELL TEST AND NOT A helm-unittest SUITE.
#
#  helm-unittest cannot assert either half of this. It validates values against
#  the packaged values.schema.json (verified against plugin 0.5.2) and treats a
#  schema violation as a plugin-level ERROR, not as a template failure — so
#  `failedTemplate` cannot catch it, and the suite reports "1 errored" instead of
#  a pass. It also exposes no flag to skip schema validation, so the template's
#  `fail` backstop is equally unreachable from there: the schema rejects the
#  value before a template renders. Both gates are therefore only observable
#  from outside the plugin, which is what this script is for.
#
#  WHAT IT PROVES, in both directions. A rejection test that never rendered
#  anything for an unrelated reason (a missing required value, a typo in the
#  chart path) passes for free, so every reject case is paired with an accept
#  control on the SAME command line, and the reject is matched against the
#  specific error text rather than merely a non-zero exit.
#
#  Usage: bash scripts/tests/chart-env-vocabulary.sh
#
set -euo pipefail

CHART="${CHART:-./client}"
VALUES="${VALUES:-client/ci/bm-values.yaml}"

cd "$(dirname "$0")/../.."

if [[ ! -f "$CHART/Chart.yaml" ]]; then
  echo "FATAL: no chart at $CHART/Chart.yaml (run from the repo root)" >&2
  exit 1
fi
if [[ ! -f "$VALUES" ]]; then
  echo "FATAL: no values file at $VALUES" >&2
  exit 1
fi

fails=0
checks=0

render() { # $@ = extra helm args; prints combined output, returns helm's status
  # backend#2892: pin mysqlRootPassword so the dev renders below (dev turns
  # rotateMysqlRoot on via its ByEnv default) don't trip the fail-closed
  # root-rotation guard — `helm template` is cluster-less, so an unpinned dev
  # render refuses. The pin is tier 1 (bypasses the mint) and is inert to the env
  # vocabulary this script checks; a bad CLIENT_ENV / channelTags value is still
  # rejected by the schema regardless.
  helm template vocab "$CHART" -f "$VALUES" --set mysqlRootPassword=RotatedRootPw123 "$@" 2>&1
}

pass() { checks=$((checks + 1)); echo "  ok    $1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "  FAIL  $1"; }

# accepts <label> <helm args...> — must render, and must render the tag we expect
expect_render() {
  local label="$1" want="$2"; shift 2
  local out
  if ! out="$(render "$@")"; then
    fail "$label: expected a successful render, got: $(head -3 <<<"$out" | tr '\n' ' ')"
    return
  fi
  if grep -qF "$want" <<<"$out"; then
    pass "$label -> $want"
  else
    fail "$label: rendered, but '$want' is not in the output"
  fi
}

# expect_reject <label> <error substring> <helm args...>
expect_reject() {
  local label="$1" want="$2"; shift 2
  local out
  if out="$(render "$@")"; then
    fail "$label: expected a rejection, but the chart rendered"
    return
  fi
  if grep -qF "$want" <<<"$out"; then
    pass "$label (rejected: $want)"
  else
    fail "$label: rejected, but not for the expected reason. Got: $(head -3 <<<"$out" | tr '\n' ' ')"
  fi
}

SCHEMA_ERR="values don't meet the specifications of the schema"

echo "== env.CLIENT_ENV: the six accepted spellings plus empty all resolve =="
# The accept side is the control for every reject case below: it proves the
# command line, values file and chart path are good, so a rejection downstream
# is attributable to the value under test and nothing else.
expect_render "CLIENT_ENV unset"        "tracebloc/jobs-manager:prod"
expect_render "CLIENT_ENV=''"           "tracebloc/jobs-manager:prod" --set env.CLIENT_ENV=""
expect_render "CLIENT_ENV=dev"          "tracebloc/jobs-manager:dev"  --set env.CLIENT_ENV=dev
expect_render "CLIENT_ENV=stg"          "tracebloc/jobs-manager:stg"  --set env.CLIENT_ENV=stg
expect_render "CLIENT_ENV=prod"         "tracebloc/jobs-manager:prod" --set env.CLIENT_ENV=prod
expect_render "CLIENT_ENV=development"  "tracebloc/jobs-manager:dev"  --set env.CLIENT_ENV=development
expect_render "CLIENT_ENV=staging"      "tracebloc/jobs-manager:stg"  --set env.CLIENT_ENV=staging
expect_render "CLIENT_ENV=production"   "tracebloc/jobs-manager:prod" --set env.CLIENT_ENV=production

echo "== env.CLIENT_ENV: everything else is refused at install time =="
# `prd`, `Prod` and `develop` are the realistic ones — an abbreviation, a
# capitalisation, and an alias that is one letter off `development`. Each used
# to render `tracebloc/*:<the raw value>`, miss channelTags AND
# serviceDbAccountsByEnv, and drop the prod digest pin.
BAD_ENVS=(prd qa Prod PROD produktion develop stage test)
# Whitespace-only is its own case: it is NOT the empty string (which is legal and
# means "unset"), and a hand-edited values.yaml is where it comes from. Kept out
# of the array above so the tab survives being read back as a word.
BAD_ENVS+=($'\t')
for bad in "${BAD_ENVS[@]}"; do
  expect_reject "CLIENT_ENV=${bad//$'\t'/<tab>}" "$SCHEMA_ERR" --set env.CLIENT_ENV="$bad"
done

echo "== the template fail is a real backstop, not decoration =="
# The enum is only enforced where the packaged schema is read. Prove the helper
# refuses independently, by rendering with schema validation switched off.
# Gated on flag support: CI pins helm v3.15.4 and the flag landed in 3.16.
_helm_help="$(helm template --help 2>&1 || true)"
if grep -q -- '--skip-schema-validation' <<<"$_helm_help"; then
  expect_reject "CLIENT_ENV=prd with the schema skipped" \
    "is not a recognized environment" \
    --set env.CLIENT_ENV=prd --skip-schema-validation
  # Control: with the same flag, a valid value must still render. Without this,
  # the assertion above would also pass if --skip-schema-validation had broken
  # rendering outright.
  expect_render "CLIENT_ENV=staging with the schema skipped" \
    "tracebloc/jobs-manager:stg" \
    --set env.CLIENT_ENV=staging --skip-schema-validation
else
  echo "  skip  --skip-schema-validation unsupported by $(helm version --short) — helper backstop not exercised"
fi

echo "== env.TRACEBLOC_DDP / env.TRACEBLOC_AMP: the switch vocabulary is closed =="
# RFC-0067 D8 (backend#3149): the runtime reads 1|true|yes as ON and EVERYTHING
# ELSE as OFF, so a misspelling does not error there -- it silently disables the
# switch the operator believes is on. The schema is the only place the typo can
# be caught. `--set-string`, not `--set`: helm parses a bare 1 as an integer and
# the schema would refuse it for the wrong reason (type, not vocabulary).
for key in TRACEBLOC_DDP TRACEBLOC_AMP; do
  for good in 1 0 true false yes no TRUE False YES nO; do
    expect_render "$key=$good" "name: $key" --set-string "env.$key=$good"
  done
  # Whitespace-tolerant, as the runtime's .strip() is.
  expect_render "$key=' true '" "name: $key" --set-string "env.$key= true "
  # Empty is legal and means UNSET: the passthrough emits nothing for it.
  expect_render "$key=''" "tracebloc/jobs-manager:prod" --set-string "env.$key="
  for bad in ture on off enabled disabled 2 t y; do
    expect_reject "$key=$bad" "$SCHEMA_ERR" --set-string "env.$key=$bad"
  done
done

echo "== images.ingestor.channelTags: keys are closed =="
# The lookup is on the RESOLVED env, so only dev/stg/prod can ever match. An
# alias key validated fine and was then silently ignored: channelTags.staging
# on a staging edge rendered `stg` (from channelTags.stg), not the value written.
expect_render "channelTags.dev"     'value: "9.9"' --set env.CLIENT_ENV=dev  --set images.ingestor.channelTags.dev=9.9
expect_render "channelTags.stg"     'value: "9.9"' --set env.CLIENT_ENV=stg  --set images.ingestor.channelTags.stg=9.9
expect_render "channelTags.prod"    'value: "9.9"' --set env.CLIENT_ENV=prod --set images.ingestor.prodPin=false --set images.ingestor.channelTags.prod=9.9
for bad in staging development production dev-1 PROD totallyBogus; do
  expect_reject "channelTags.$bad" "$SCHEMA_ERR" --set "images.ingestor.channelTags.$bad=9.9"
done

echo "== RESOURCE_REQUESTS / RESOURCE_LIMITS: the dimension vocabulary is closed =="
# backend#2223 widened the grammar past cpu/memory to admit ephemeral-storage.
# The vocabulary stays CLOSED on purpose: client-runtime parses this env value
# with a bare `key, value = pair.split("=")` and NO allow-list, so an
# unrecognised key does not error there -- it lands in the pod spec as a
# silently wrong envelope. The schema is the only place a typo can be caught.
#
# Written through a VALUES FILE, not `--set`. `--set` splits on commas itself,
# so `--set env.RESOURCE_REQUESTS=cpu=2,` reaches the schema as `cpu=2` and a
# trailing-comma test passes for the wrong reason. That trap cost a false
# "accepted" while developing this.
resource_values_file() { # $1 = key, $2 = value -> path to a temp values file
  local f; f="$(mktemp)"
  printf 'env:\n  %s: "%s"\n' "$1" "$2" > "$f"
  echo "$f"
}

expect_resource_render() { # <label> <key> <value>
  local label="$1" key="$2" value="$3" f out
  f="$(resource_values_file "$key" "$value")"
  checks=$((checks + 1))
  if out="$(helm template vocab "$CHART" -f "$VALUES" -f "$f" 2>&1)"; then
    echo "  ok    $label"
  else
    fails=$((fails + 1))
    echo "  FAIL  $label: expected accept, got: $(head -3 <<<"$out" | tr '\n' ' ')"
  fi
  rm -f "$f"
}

expect_resource_reject() { # <label> <key> <value>
  local label="$1" key="$2" value="$3" f out
  f="$(resource_values_file "$key" "$value")"
  checks=$((checks + 1))
  if out="$(helm template vocab "$CHART" -f "$VALUES" -f "$f" 2>&1)"; then
    fails=$((fails + 1))
    echo "  FAIL  $label: expected a rejection, but the chart rendered"
  elif grep -qF "$SCHEMA_ERR" <<<"$out"; then
    echo "  ok    $label (rejected)"
  else
    fails=$((fails + 1))
    echo "  FAIL  $label: rejected for the wrong reason: $(head -3 <<<"$out" | tr '\n' ' ')"
  fi
  rm -f "$f"
}

for key in RESOURCE_REQUESTS RESOURCE_LIMITS; do
  # Accepted: the installer's fallback value (the contract floor since
  # backend#2254), the new dimension, any subset, any order.
  expect_resource_render "$key cpu+memory (installer's value)" "$key" "cpu=1,memory=2Gi"
  expect_resource_render "$key with ephemeral-storage"         "$key" "cpu=1,memory=2Gi,ephemeral-storage=20Gi"
  expect_resource_render "$key disk only"                      "$key" "ephemeral-storage=20Gi"
  # memory-only is the shape the L0.2 limits half emits (backend#2418): cpu is
  # dropped so the request can burst, leaving RESOURCE_LIMITS=memory=<X>. This
  # is the exact value the VM-ceiling sizing produced in client#836, where a
  # PRE-backend#2223 chart schema (`^(cpu=\S+,memory=\S+)?$`) rejected it at
  # `helm install`. Rendered here through the REAL schema so a re-tightening
  # that forbids the subset fails against helm itself, not just a proxy regex.
  expect_resource_render "$key memory only (L0.2 limits, client#836)"  "$key" "memory=12Gi"
  expect_resource_render "$key reordered"                      "$key" "memory=2Gi,cpu=1"
  expect_resource_render "$key empty (unset)"                  "$key" ""

  # Rejected: the typo is the whole reason the list is closed.
  expect_resource_reject "$key typo 'memroy'"                  "$key" "memroy=2Gi"
  expect_resource_reject "$key unknown dimension 'gpu'"        "$key" "cpu=1,memory=2Gi,gpu=1"
  expect_resource_reject "$key empty value"                    "$key" "cpu="
  expect_resource_reject "$key trailing comma"                 "$key" "cpu=1,"
  expect_resource_reject "$key space instead of ="             "$key" "cpu 1,memory=2Gi"
done

echo
if (( fails )); then
  echo "chart-env-vocabulary: $fails of $checks checks FAILED"
  exit 1
fi
echo "chart-env-vocabulary: all $checks checks passed"
