#!/usr/bin/env bats
# Installer parity — the bash half (client#772).
#
# Drives _resolve_training_size through every cluster state in
# fixtures/installer_parity.json (via the generated .bash table, since bats has
# no guaranteed JSON parser) and asserts the four verdicts the fixture declares:
# size, provenance, undersized, unschedulable.
#
# install-k8s.Tests.ps1's "Installer parity" Describe reads the SAME fixture and
# drives Get-TrainingResources / Get-TrainingProvenance through the same states.
# One table, two readers: a row added to the JSON forces both languages to answer
# it, which is what neither the golden vectors nor five rounds of review caught
# on their own.
#
# Why this exists rather than more per-twin tests: client#766 gave the installers
# a shared CONTRACT (envelope_contract.json) and that fixed arithmetic agreement.
# It did not give them shared CONTROL FLOW, and all five divergences in
# backend#2220 lived in the states that are not a clean measurement — an
# unparseable node, a failed values read, a remainder too small to request. Each
# was found one at a time, after the code shipped; one of them (the ps1 Int32
# overload) had silently disabled machine sizing on Windows entirely.

load test_helper

setup() {
  load_lib install-client-helm.sh
  source "${BATS_TEST_DIRNAME}/fixtures/installer_parity.bash"
  TB_NAMESPACE=tracebloc
}

# Build the kubectl/helm stubs a row's scenario calls for, then resolve.
#
# Deliberately stubs at the SAME boundary the ps1 suite mocks — the two external
# commands — rather than stubbing the installer's own helpers. Stubbing our own
# helpers would let the two suites diverge in what they actually exercise, which
# is the failure mode this file exists to close.
_drive_row() {
  local nodes="$1" carried="$2" carried_prov="$3" override="$4"

  if [[ -n "$override" ]]; then
    export TRACEBLOC_TRAINING_RESOURCES="$override"
  else
    unset TRACEBLOC_TRAINING_RESOURCES
  fi

  has() { return 0; }

  case "$carried" in
    none|read-fails)
      # No release to carry, or the values read fails outright. Same shape to
      # the caller; the fixture keeps them as separate rows because they are
      # different real-world causes.
      helm() { return 1; }
      ;;
    read-empty)
      helm() { printf ''; }
      ;;
    *)
      if [[ -n "$carried_prov" ]]; then
        helm() { printf 'env:\n  RESOURCE_LIMITS: %s\n  RESOURCE_PROVENANCE: %s\n' "$_TB_ROW_CARRIED" "$_TB_ROW_CARRIED_PROV"; }
      else
        helm() { printf 'env:\n  RESOURCE_LIMITS: %s\n' "$_TB_ROW_CARRIED"; }
      fi
      ;;
  esac

  kubectl() {
    case "$*" in
      *--request-timeout=10s*)
        # The node list, one "<cpu> <memory>" line each.
        printf '%s\n' "${_TB_ROW_NODES//;/$'\n'}"
        ;;
      *) return 0 ;;   # the namespace probe
    esac
  }

  _resolve_training_size
}

@test "installer parity: the fixture and its generated table agree" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  run "${BATS_TEST_DIRNAME}/../gen-installer-parity.sh" --check
  [ "$status" -eq 0 ] || return 1
}

@test "installer parity: the table is not empty" {
  # A silently-empty table would make every assertion below vacuous — the
  # disconnected-guard shape gen-manifest.sh warns about in its own surface check.
  [ "${#TB_PARITY_ROWS[@]}" -ge 10 ] || return 1
}

@test "installer parity: every cluster state produces the declared verdict" {
  local failures=""
  local row label nodes carried carried_prov override want_size want_prov want_under want_unsched want_limits

  for row in "${TB_PARITY_ROWS[@]}"; do
    IFS='|' read -r label nodes carried carried_prov override \
                    want_size want_prov want_under want_unsched want_limits <<< "$row"

    _TB_ROW_NODES="$nodes"
    _TB_ROW_CARRIED="$carried"
    _TB_ROW_CARRIED_PROV="$carried_prov"

    _drive_row "$nodes" "$carried" "$carried_prov" "$override"

    [ "$_TB_TRAINING_SIZE" = "$want_size" ] \
      || failures+="  ${label}: size want '${want_size}' got '${_TB_TRAINING_SIZE}'"$'\n'
    [ "$_TB_TRAINING_PROVENANCE" = "$want_prov" ] \
      || failures+="  ${label}: provenance want '${want_prov}' got '${_TB_TRAINING_PROVENANCE}'"$'\n'
    [ "${_TB_TRAINING_UNDERSIZED:-0}" = "$want_under" ] \
      || failures+="  ${label}: undersized want '${want_under}' got '${_TB_TRAINING_UNDERSIZED:-0}'"$'\n'
    [ "${_TB_TRAINING_UNSCHEDULABLE:-0}" = "$want_unsched" ] \
      || failures+="  ${label}: unschedulable want '${want_unsched}' got '${_TB_TRAINING_UNSCHEDULABLE:-0}'"$'\n'
    # schema_version 2 (backend#2418): the limits half is a SECOND shared
    # contract, and the twins already diverged on it once -- bash matched
    # `cpu=*` without trimming, so `cpu=7, memory=29Gi` kept the cpu limit here
    # while PowerShell's .Trim() dropped it. Asserting it per-row is what makes
    # that class of divergence fail rather than ship.
    local got_limits
    got_limits="$(_training_limits "$_TB_TRAINING_SIZE")"
    [ "$got_limits" = "$want_limits" ] \
      || failures+="  ${label}: limits want '${want_limits}' got '${got_limits}'"$'\n'
  done

  if [ -n "$failures" ]; then
    printf 'installer parity failures (bash side):\n%s' "$failures" >&2
    printf 'The ps1 twin is asserted against the SAME fixture — if only one side\n' >&2
    printf 'fails, the twins have diverged, which is what this file exists to catch.\n' >&2
    return 1
  fi
}

@test "installer parity: the resolver never emits text (it would corrupt the value)" {
  # _training_resources is captured with $(...) by the values generation, so any
  # warn/log written from the resolution path lands inside RESOURCE_LIMITS. The
  # warning deliberately lives in the CALLER; this pins that it stayed there,
  # across every state in the table rather than one hand-picked case.
  local row label nodes carried carried_prov override rest captured
  for row in "${TB_PARITY_ROWS[@]}"; do
    IFS='|' read -r label nodes carried carried_prov override rest <<< "$row"
    _TB_ROW_NODES="$nodes"
    _TB_ROW_CARRIED="$carried"
    _TB_ROW_CARRIED_PROV="$carried_prov"

    if [[ -n "$override" ]]; then
      export TRACEBLOC_TRAINING_RESOURCES="$override"
    else
      unset TRACEBLOC_TRAINING_RESOURCES
    fi
    has() { return 0; }
    case "$carried" in
      none|read-fails) helm() { return 1; } ;;
      read-empty)      helm() { printf ''; } ;;
      *)               helm() { printf 'env:\n  RESOURCE_LIMITS: %s\n' "$_TB_ROW_CARRIED"; } ;;
    esac
    kubectl() {
      case "$*" in
        *--request-timeout=10s*) printf '%s\n' "${_TB_ROW_NODES//;/$'\n'}" ;;
        *) return 0 ;;
      esac
    }

    captured="$(_training_resources)"
    # Exactly the size, nothing else — no warning text, no log line.
    case "$captured" in
      cpu=*,memory=*) ;;
      *) echo "row ${label}: _training_resources emitted '${captured}'" >&2; return 1 ;;
    esac
  done
}

# ── the kubelet drop-in's reservation shape (backend#2460) ───────────────────
#
# Driven through the REAL writer with the platform overridden: once as the first
# platform in this twin's own measured list, once as the fixture's unmeasured
# probe. The Pester half does the same against Write-KubeletConfig. The keys a
# measured platform must emit, an unmeasured one must not, and neither may
# restate from k3s, come from the fixture -- one declaration, two writers.

_reservation_setup() {
  # common.sh is already loaded by setup() and declares readonly variables, so
  # only the cluster lib is sourced here.
  # shellcheck source=/dev/null
  source "${LIB_DIR}/cluster.sh"
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"
}

@test "parity: the fixture declares the reservation shape" {
  [ -n "$TB_PARITY_RESERVATION_PLATFORMS_VAR" ] || return 1
  [ -n "$TB_PARITY_RESERVATION_UNMEASURED_PROBE" ] || return 1
  [ "${#TB_PARITY_RESERVATION_EMITTED_MEASURED[@]}" -ge 4 ] || return 1
  [ "${#TB_PARITY_RESERVATION_NEVER_UNMEASURED[@]}" -ge 4 ] || return 1
  [ "${#TB_PARITY_RESERVATION_NEVER_RESTATED[@]}" -ge 2 ] || return 1
  [ "${#TB_PARITY_RESERVATION_ALWAYS[@]}" -ge 3 ] || return 1
}

@test "parity: a measured platform's drop-in carries every key the fixture names, and none it forbids" {
  _reservation_setup
  local plat; set -- ${!TB_PARITY_RESERVATION_PLATFORMS_VAR}; plat="${1:-}"
  [ -n "$plat" ] || skip "no platform has a measured record in this tree"
  _kubelet_reservation_platform() { printf '%s' "$plat"; }
  run _write_kubelet_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local yaml; yaml="$(cat "$output")"
  local k
  for k in "${TB_PARITY_RESERVATION_EMITTED_MEASURED[@]}" "${TB_PARITY_RESERVATION_ALWAYS[@]}"; do
    [[ "$yaml" == *"$k"* ]] || { echo "measured platform '$plat' did not emit '$k':"; echo "$yaml"; return 1; }
  done
  for k in "${TB_PARITY_RESERVATION_NEVER_RESTATED[@]}"; do
    [[ "$yaml" != *"$k"* ]] || { echo "restated k3s's '$k':"; echo "$yaml"; return 1; }
  done
}

@test "parity: an unmeasured platform's drop-in carries none of the reservation keys, and all of the always-keys" {
  _reservation_setup
  _kubelet_reservation_platform() { printf '%s' "$TB_PARITY_RESERVATION_UNMEASURED_PROBE"; }
  run _write_kubelet_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local yaml; yaml="$(cat "$output")"
  local k
  for k in "${TB_PARITY_RESERVATION_NEVER_UNMEASURED[@]}"; do
    [[ "$yaml" != *"$k"* ]] || { echo "unmeasured platform emitted '$k':"; echo "$yaml"; return 1; }
  done
  for k in "${TB_PARITY_RESERVATION_ALWAYS[@]}"; do
    [[ "$yaml" == *"$k"* ]] || { echo "unmeasured platform dropped '$k':"; echo "$yaml"; return 1; }
  done
}
