#!/usr/bin/env bash
# =============================================================================
#  check-facts.sh — keep cross-OS installer FACTS in lockstep with the single
#                   source of truth, scripts/spec/facts.env (#435, RFC D3/D4).
#
#  The costliest drift class of the installer sweep was facts diverging between the
#  three OS implementations — the #410 incident (k3d/helm pins bumped in bash but not
#  PowerShell) failed a real customer install. facts.env is the authoritative spec; its
#  values are STAMPED into each consumer (bash common.sh, PowerShell install-k8s.ps1) so
#  the bootstrap stays a single verified file (R8) — nothing is sourced at runtime.
#
#  Usage:
#    scripts/check-facts.sh            # --write: stamp facts.env into every consumer
#    scripts/check-facts.sh --write    # (same)
#    scripts/check-facts.sh --check    # verify every consumer matches facts.env
#                                      #   (CI gate; non-zero on drift — the #410 guard)
#    scripts/check-facts.sh --check-published
#                                      # ask ghcr.io whether the GPU node image tag
#                                      #   both installers derive was actually PUBLISHED
#                                      #   (backend#3007). NETWORK; NOT in --check /
#                                      #   make drift — see that mode's block below.
#
#  --check and --write mirror gen-manifest.sh's write/check split and are hermetic
#  (no network, no secrets). --check-published is the one mode that reaches the
#  registry (an anonymous public read — still no secrets).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SPEC="scripts/spec/facts.env"
COMMON="scripts/lib/common.sh"
SUMMARY="scripts/lib/summary.sh"
HELM_LIB="scripts/lib/install-client-helm.sh"
PS1="scripts/install-k8s.ps1"
CLUSTER="scripts/lib/cluster.sh"
# #616: the GPU node image (docker/k3s-cuda) rebuilds the SAME pinned k3s, so its
# K3S_TAG in the Dockerfile ARG, build.sh, and the workflow input default must all
# equal facts.env's K8S_VERSION — else the build would produce, and the installer
# derive, DIFFERENT tags.
#
# This row set proves those four DECLARATIONS agree. It does NOT — and cannot —
# prove the agreed tag was ever PUBLISHED: it never asks the registry. backend#3007
# was exactly that gap. On 2026-08-24 the k3s pin moved to v1.36.3-k3s1, 17 days
# after the GPU image was last built (build-k3s-cuda is workflow_dispatch-only), so
# every GPU install derived a tag that 404s and SILENTLY fell back to CPU — while
# all four declarations agreed and this check stayed green. The four values moving
# in lockstep is what made it invisible. The publication half is the separate
# --check-published mode below (do not restate it here).
CUDA_DOCKERFILE="docker/k3s-cuda/Dockerfile"
CUDA_BUILD="docker/k3s-cuda/build.sh"
CUDA_WORKFLOW=".github/workflows/build-k3s-cuda.yaml"

MODE="write"
case "${1:-}" in
  --check) MODE="check" ;;
  --check-published) MODE="check-published" ;;
  --write | "") MODE="write" ;;
  *) echo "usage: $0 [--write|--check|--check-published]" >&2; exit 2 ;;
esac

[[ -f "$SPEC" ]] || { echo "check-facts: spec not found: $SPEC" >&2; exit 2; }

# Read a bare KEY=value from the spec (comments/blank lines ignored). Fails closed:
# a missing/empty key is a spec error, not a silent pass.
_spec_get() {
  local key="$1" all val
  # Capture whole, then take the first line with `%%$'\n'*` — NOT `… | head -1`.
  # Under `set -o pipefail` a duplicate key makes head close the pipe after line 1,
  # sed takes SIGPIPE, and the pipeline exits 141 — aborting the facts gate before
  # any drift message prints (a crash/fail-open on duplicate input).
  all="$(sed -n "s/^${key}=\(.*\)$/\1/p" "$SPEC")"
  val="${all%%$'\n'*}"
  [[ -n "$val" ]] || { echo "check-facts: '${key}' missing from ${SPEC}" >&2; exit 2; }
  printf '%s' "$val"
}

# =============================================================================
#  --check-published — the OTHER half of the GPU-image guard (backend#3007).
#
#  The fact table proves the four GPU-image declarations agree; this asks the
#  REGISTRY whether the tag they all derive was actually published. It derives the
#  ref the SAME way the installers do — from facts.env's K8S_VERSION and CUDA_TAG,
#  never a second copy of the tag — and HEADs the manifest on ghcr.io. THREE
#  outcomes, kept distinct on purpose (the original bug's sin was blaming the wrong
#  cause — a 404 reported as an access/creds/network problem, downgrading to CPU):
#    published, pin agrees -> exit 0
#    NOT published (404)   -> exit 1   a real, missing image (hard finding)
#    CANNOT TELL           -> exit 3   registry unreachable / anon token failed /
#                                      5xx / 429 / 401 — we could not look; this is
#                                      NOT a 404 and must never be reported as one.
#                                      ALSO: published but no readable digest header —
#                                      not knowing which digest a tag resolves to is
#                                      not evidence that the pin agrees.
#    pin DRIFTED           -> exit 4   published, but the tag resolves to a DIFFERENT
#                                      digest than facts.env's K3S_CUDA_DIGEST (backend#1867).
#                                      Distinct from 1 and 3 because the human action
#                                      differs: re-resolve the pin (or find out who
#                                      republished the tag), not "publish the image".
#
#  The digest half exists because backend#1867 made the DEFAULT install ref tag@digest. The
#  tag stays mutable, so the pin is a trust decision with a moving label pointing at
#  it — the same disease check-digest-drift.sh watches for the chart's images, and the
#  reason this check, not a second script, owns it: the ref is already derived here
#  from facts.env, once.
#
#  Network, but no secrets (anonymous pull token — a public read). Deliberately
#  NOT in --check / make drift: that gate is hermetic and REQUIRED on every PR,
#  and a K8S_VERSION bump legitimately lands on develop BEFORE the image is
#  published from staging (build-k3s-cuda's ref gate), so a 404 there is not yet a
#  fault. It runs out-of-band on a schedule (.github/workflows/k3s-cuda-published.yml),
#  the same shape as the digest-drift watch, where a persistent 404 IS the alarm.
# =============================================================================

# The GHCR ref both installers pull for a GPU node (cluster.sh _gpu_node_image /
# install-k8s.ps1 $K3S_CUDA_IMAGE): ghcr.io/tracebloc/k3s-cuda:<k3s>-cuda-<cuda>.
# Its VARIABLE halves come from facts.env so there is no third copy of the pins to
# drift; the structural literal is the one the #835 wiring guard already asserts is
# present verbatim in both installers, so the three cannot silently diverge.
_gpu_image_ref() {
  # Fail CLOSED on a missing pin, EXPLICITLY. Two subtleties, both load-bearing:
  #   1. do not inline the command subs into printf's args — a command sub in an
  #      argument list never trips errexit, so a missing pin would print a malformed
  #      ref (…:-cuda-…) that then 404s, reporting a spec error as a missing image
  #      (the "blame the wrong cause" sin this mode exists to avoid);
  #   2. `|| exit $?`, not bare assignment — under `set -e` a failing command-sub
  #      ASSIGNMENT does not reliably abort (measured: it did not, and printed the
  #      malformed ref), so lean on _spec_get's own exit rather than errexit.
  # _spec_get already prints "'<key>' missing from …" before it exits 2.
  local k8s cuda
  k8s="$(_spec_get K8S_VERSION)" || exit $?
  cuda="$(_spec_get CUDA_TAG)" || exit $?
  printf 'ghcr.io/tracebloc/k3s-cuda:%s-cuda-%s' "$k8s" "$cuda"
}

# Echo the HTTP status of a manifest HEAD for the image ref $1, or 000 when the
# registry could not be reached at all (curl prints 000 on a DNS/connect/TLS
# failure). Anonymous pull token — a public read, no secret, so this watch can
# never silently stop when a credential rotates (the digest-drift rationale).
# Host, repo and tag are all parsed FROM the ref, so there is no second hard-coded
# copy of ghcr.io/tracebloc/k3s-cuda to drift from _gpu_image_ref.
#
# TB_REGISTRY_PROBE_STUB is the TEST SEAM (mirrors check-digest-drift.sh's
# DRIFT_RESOLVE_STUB): a file of  <ref><0x1f><status>  lines that REPLACES the
# network, so the bats suite can drive all three classifications offline — and
# prove the ref is derived correctly, since only the exact derived ref matches.
_manifest_probe() {
  local ref="$1"
  if [[ -n "${TB_REGISTRY_PROBE_STUB:-}" ]]; then
    [[ -r "$TB_REGISTRY_PROBE_STUB" ]] || { echo "check-facts: TB_REGISTRY_PROBE_STUB set but unreadable: $TB_REGISTRY_PROBE_STUB" >&2; exit 2; }
    # Capture whole, split with parameter expansion — same SIGPIPE-avoidance
    # discipline as _spec_get / _extract above.
    local all st dg
    all="$(awk -F"$(printf '\037')" -v want="$ref" '$1 == want { printf "%s\037%s", $2, $3; exit }' "$TB_REGISTRY_PROBE_STUB")"
    all="${all%%$'\n'*}"
    st="${all%%$'\037'*}"
    dg="${all#*$'\037'}"
    printf '%s\037%s' "${st:-000}" "$dg"
    return 0
  fi
  local host rest repo tag base token accept out status digest
  host="${ref%%/*}"          # ghcr.io
  rest="${ref#*/}"           # tracebloc/k3s-cuda:<tag>
  repo="${rest%:*}"          # tracebloc/k3s-cuda
  tag="${rest##*:}"          # <tag>
  base="https://${host}"
  accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  # Anonymous pull token for the public package. `|| true` keeps a network failure
  # here as an empty token -> 000 (cannot tell) rather than aborting under errexit.
  token="$(curl -fsS --tlsv1.2 --connect-timeout 15 --max-time 30 \
             "${base}/token?scope=repository:${repo}:pull" 2>/dev/null || true)"
  token="$(printf '%s' "$token" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [[ -n "$token" ]] || { printf '000\037'; return 0; }
  # A real HEAD (--head): a manifest existence check needs no body, and ghcr answers
  # HEAD with the same 200/404 as GET. NO --fail: a 404 is data, not an error.
  #
  # -D - dumps the response HEADERS to stdout (where the digest lives, as
  # Docker-Content-Digest) while -o /dev/null discards the body --head would otherwise
  # write there, and -w appends the status to the same capture. One request, both
  # answers: a separate digest prober would need its own copy of the parsing above and
  # of the token dance, and that second copy is the defect, not the fix.
  out="$(curl -sS --head -D - -o /dev/null -w '\ntb_http_code=%{http_code}\n' --tlsv1.2 --connect-timeout 15 --max-time 30 \
              -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
              "${base}/v2/${repo}/manifests/${tag}" 2>/dev/null || true)"
  # curl itself prints 000 on a connection failure, so "reached and got a code" and
  # "could not reach" collapse to one value the caller classifies.
  status="$(printf '%s' "$out" | sed -n 's/^tb_http_code=\([0-9][0-9]*\)$/\1/p')"
  status="${status%%$'\n'*}"
  # Header names are case-insensitive (RFC 9110) and registries differ in spelling, so
  # match both; the trailing .* absorbs the CR of the CRLF line ending. A header we
  # cannot read leaves this EMPTY, which the caller reports as CANNOT TELL — not
  # knowing the digest is not evidence that the pin agrees.
  digest="$(printf '%s' "$out" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*\(sha256:[0-9a-f]\{64\}\).*/\1/p')"
  digest="${digest%%$'\n'*}"
  printf '%s\037%s' "${status:-000}" "$digest"
}

_run_check_published() {
  local ref probe status digest pin attempt
  # `|| return $?` for the same reason _gpu_image_ref uses `|| exit $?`: propagate a
  # spec error (2) or an unreadable-stub error (2) instead of trusting errexit to
  # abort a failing command-sub assignment.
  ref="$(_gpu_image_ref)" || return $?
  # The pin is read the same way the ref is derived: from the spec, once. _spec_get
  # exits 2 on a missing key, so a spec without K3S_CUDA_DIGEST fails CLOSED here
  # rather than comparing against an empty string — which every digest differs from,
  # reporting drift when the real fault is the declaration.
  pin="$(_spec_get K3S_CUDA_DIGEST)" || return $?
  probe="$(_manifest_probe "$ref")" || return $?
  status="${probe%%$'\037'*}"; digest="${probe#*$'\037'}"
  # Retry ONLY a transient "cannot tell", never a clean 404/2xx, so a single ghcr
  # blip does not turn the daily watch red. The stub path is deterministic and is
  # skipped here, so tests never sleep or loop.
  if [[ -z "${TB_REGISTRY_PROBE_STUB:-}" ]]; then
    attempt=1
    while [[ "$status" != 2?? && "$status" != 404 && "$attempt" -lt 3 ]]; do
      sleep 2
      probe="$(_manifest_probe "$ref")"
      status="${probe%%$'\037'*}"; digest="${probe#*$'\037'}"
      attempt=$(( attempt + 1 ))
    done
  fi
  case "$status" in
    2??)
      # Published. Now the backend#1867 half: the DEFAULT install ref is tag@digest, so a tag
      # that resolves elsewhere means the pin no longer names what this tag builds.
      if [[ -z "$digest" ]]; then
        {
          echo "  ‼ CANNOT TELL which digest ${ref} resolves to (HTTP ${status}, but no readable Docker-Content-Digest)."
          echo ""
          echo "check-facts: the tag exists, but the registry returned no digest we could parse, so the"
          echo "             K3S_CUDA_DIGEST pin could not be compared. Reported as CANNOT TELL, NOT as"
          echo "             agreement and NOT as drift — an unreadable digest is evidence of neither"
          echo "             (backend#1867)."
        } >&2
        return 3
      fi
      if [[ "$digest" != "$pin" ]]; then
        {
          echo "  ✖ GPU node image DIGEST PIN DRIFTED for ${ref} (HTTP ${status})."
          echo "      tag now resolves to: ${digest}"
          echo "      facts.env pins:      ${pin}"
          echo ""
          echo "check-facts: the default GPU node ref is tag@digest, so a Linux GPU install pulls the"
          echo "             PINNED digest — which is no longer what this tag builds. Two causes, both"
          echo "             needing a human: the tag was republished (someone rebuilt it — re-verify"
          echo "             before re-pinning), or K8S_VERSION/CUDA_TAG were bumped without"
          echo "             re-resolving the pin, in which case installs pull an image built for the"
          echo "             OLD k3s. Re-resolve with:"
          echo "               docker buildx imagetools inspect ${ref} --format '{{json .Manifest.Digest}}'"
          echo "             then update K3S_CUDA_DIGEST in scripts/spec/facts.env and run --write."
        } >&2
        return 4
      fi
      echo "check-facts: GPU node image is published and the digest pin matches: ${ref}@${digest} (HTTP ${status})."
      return 0
      ;;
    404)
      {
        echo "  ✖ GPU node image NOT PUBLISHED: ${ref} (HTTP 404)."
        echo ""
        echo "check-facts: the tag both installers derive for a GPU node does not exist on ghcr.io."
        echo "             A GPU install pulls this by tag at cluster-create; a failed pull is treated"
        echo "             as a GPU-capability problem and the install SILENTLY falls back to CPU,"
        echo "             blaming access/creds/network (backend#3007). Publish it: dispatch"
        echo "             build-k3s-cuda.yaml (push=true) from staging or main."
      } >&2
      return 1
      ;;
    *)
      {
        echo "  ‼ CANNOT TELL whether ${ref} is published (HTTP ${status:-000})."
        echo ""
        echo "check-facts: the registry was unreachable, rate-limited, or the anonymous token failed."
        echo "             This is NOT a 404 — not being able to look is not the same as a missing"
        echo "             image (backend#3007). Reported distinctly so it is never mistaken for"
        echo "             either answer."
      } >&2
      return 3
      ;;
  esac
}

if [[ "$MODE" == "check-published" ]]; then
  _run_check_published || exit $?
  exit 0
fi

# Each consumer fact: a stable NAME, the FILE, a sed EXTRACTOR that echoes the currently
# stamped value, and the spec KEY it must equal. Kept as parallel arrays (bash 3.2 — no
# associative arrays). To cover a new fact/consumer, add a row here.
FACT_NAMES=(
  "common.sh:K3D_VERSION"
  "common.sh:HELM_VERSION"
  "common.sh:K8S_VERSION"
  "common.sh:K8S_VERSION-help"
  "install-k8s.ps1:K3dVersion"
  "install-k8s.ps1:HelmVersion"
  "install-k8s.ps1:K8S_VERSION"
  "install-k8s.ps1:K8S_VERSION-help"
  "summary.sh:READY_TIMEOUT"
  "install-k8s.ps1:ReadyTimeout"
  "install-client-helm.sh:METRICS_WAIT_TIMEOUT"
  "install-k8s.ps1:MetricsWaitTimeout"
  "k3s-cuda/Dockerfile:K3S_TAG"
  "k3s-cuda/build.sh:K3S_TAG"
  "build-k3s-cuda.yaml:k3s_tag"
  "install-k8s.ps1:CUDA_BASE_TAG"
  "common.sh:CUDA_BASE_TAG"
  "k3s-cuda/Dockerfile:CUDA_TAG"
  "k3s-cuda/build.sh:CUDA_TAG"
  "build-k3s-cuda.yaml:cuda_tag"
  "common.sh:K3S_CUDA_DIGEST"
)
FACT_FILES=( "$COMMON" "$COMMON" "$COMMON" "$COMMON" "$PS1" "$PS1" "$PS1" "$PS1" "$SUMMARY" "$PS1" "$HELM_LIB" "$PS1" "$CUDA_DOCKERFILE" "$CUDA_BUILD" "$CUDA_WORKFLOW" "$PS1" "$COMMON" "$CUDA_DOCKERFILE" "$CUDA_BUILD" "$CUDA_WORKFLOW" "$COMMON" )
FACT_KEYS=( K3D_VERSION HELM_VERSION K8S_VERSION K8S_VERSION K3D_VERSION HELM_VERSION K8S_VERSION K8S_VERSION READY_TIMEOUT READY_TIMEOUT METRICS_WAIT_TIMEOUT METRICS_WAIT_TIMEOUT K8S_VERSION K8S_VERSION K8S_VERSION CUDA_TAG CUDA_TAG CUDA_TAG CUDA_TAG CUDA_TAG K3S_CUDA_DIGEST )
FACT_EXTRACT=(
  's/^K3D_VERSION="\${K3D_VERSION:-\(.*\)}".*/\1/p'
  's/^HELM_VERSION="\${HELM_VERSION:-\(.*\)}".*/\1/p'
  's/^K8S_VERSION="\${K8S_VERSION:-\(.*\)}".*/\1/p'
  's/^ *K8S_VERSION *k3s image tag *(default: \(.*\))$/\1/p'
  's/.*\$script:K3dVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$script:HelmVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$K8S_VERSION .*else { "\([^"]*\)" }.*/\1/p'
  's/^ *K8S_VERSION *k3s image tag *(default: \(.*\))$/\1/p'
  's/^READY_TIMEOUT="\${READY_TIMEOUT:-\(.*\)}".*/\1/p'
  's/.*\$ReadyTimeout .*else { "\([^"]*\)" }.*/\1/p'
  's/^METRICS_WAIT_TIMEOUT=\([0-9]*\)$/\1/p'
  's/.*\$script:MetricsWaitTimeout = \([0-9]*\).*/\1/p'
  's/^ARG K3S_TAG="\(.*\)".*/\1/p'
  's/^K3S_TAG="\${K3S_TAG:-\(.*\)}".*/\1/p'
  's/^ *default: "\(v[0-9][^"]*\)".*/\1/p'
  's/.*\$CUDA_BASE_TAG .*else { "\([^"]*\)" }.*/\1/p'
  's/^TB_CUDA_BASE_TAG="\${TRACEBLOC_CUDA_BASE_TAG:-\(.*\)}".*/\1/p'
  's/^ARG CUDA_TAG="\(.*\)".*/\1/p'
  's/^CUDA_TAG="\${CUDA_TAG:-\(.*\)}".*/\1/p'
  's/^ *default: "\([0-9][^"]*ubuntu[^"]*\)".*/\1/p'
  's/^TB_K3S_CUDA_DIGEST="\(.*\)"$/\1/p'
)
# For --write: an sed program that substitutes the OLD value with @@VAL@@ (replaced with
# the spec value below). Anchored the same way as the extractor so only the pinned token
# changes. \& / @@VAL@@ placeholder avoids re-escaping the value into a sed replacement.
FACT_REWRITE=(
  's|^\(K3D_VERSION="${K3D_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(HELM_VERSION="${HELM_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(K8S_VERSION="${K8S_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\( *K8S_VERSION *k3s image tag *(default: \)[^)]*\()\)|\1@@VAL@@\2|'
  's|\(\$script:K3dVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$script:HelmVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$K8S_VERSION .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\( *K8S_VERSION *k3s image tag *(default: \)[^)]*\()\)|\1@@VAL@@\2|'
  's|^\(READY_TIMEOUT="${READY_TIMEOUT:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(\$ReadyTimeout .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\(METRICS_WAIT_TIMEOUT=\)[0-9]*$|\1@@VAL@@|'
  's|\(\$script:MetricsWaitTimeout = \)[0-9]*|\1@@VAL@@|'
  's|^\(ARG K3S_TAG="\)[^"]*\("\)|\1@@VAL@@\2|'
  's|^\(K3S_TAG="${K3S_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(default: "\)v[0-9][^"]*\("\)|\1@@VAL@@\2|'
  's|\(\$CUDA_BASE_TAG .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\(TB_CUDA_BASE_TAG="${TRACEBLOC_CUDA_BASE_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(ARG CUDA_TAG="\)[^"]*\("\)|\1@@VAL@@\2|'
  's|^\(CUDA_TAG="${CUDA_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(default: "\)[0-9][^"]*ubuntu[^"]*\("\)|\1@@VAL@@\2|'
  's|^\(TB_K3S_CUDA_DIGEST="\)[^"]*\("\)|\1@@VAL@@\2|'
)

# Capture whole, then take the first line with `%%$'\n'*` — NOT `… | head -1`, which
# SIGPIPEs sed (exit 141) under `set -o pipefail` when a file has a second match.
_extract() { local all; all="$(sed -n "$2" "$1")"; printf '%s' "${all%%$'\n'*}"; }

drift=0
i=0
while [ "$i" -lt "${#FACT_NAMES[@]}" ]; do
  name="${FACT_NAMES[$i]}"; file="${FACT_FILES[$i]}"; key="${FACT_KEYS[$i]}"
  want="$(_spec_get "$key")"
  if [[ ! -f "$file" ]]; then
    echo "  ✖ ${name}: ${file} not found" >&2; drift=$(( drift + 1 )); i=$(( i + 1 )); continue
  fi
  got="$(_extract "$file" "${FACT_EXTRACT[$i]}")"
  if [[ -z "$got" ]]; then
    echo "  ✖ ${name}: no pinned value found in ${file} (pattern moved?)" >&2; drift=$(( drift + 1 )); i=$(( i + 1 )); continue
  fi
  if [[ "$MODE" == "check" ]]; then
    if [[ "$got" != "$want" ]]; then
      echo "  ✖ ${name} = ${got}  ≠  ${SPEC} (${key} = ${want})" >&2
      drift=$(( drift + 1 ))
    else
      echo "  ✔ ${name} = ${got}"
    fi
  else
    if [[ "$got" == "$want" ]]; then
      echo "  ✔ ${name} already ${want}"
    else
      prog="${FACT_REWRITE[$i]/@@VAL@@/$want}"
      tmp="$(mktemp)"
      sed "$prog" "$file" > "$tmp" && mv "$tmp" "$file"
      echo "  ↻ ${name}: ${got} → ${want}"
    fi
  fi
  i=$(( i + 1 ))
done

# Structural guard (#547 / F4): the fact table above only compares the pinned
# VERSION STRINGS — it does NOT verify the create command actually WIRES the k3s
# pin into the cluster. #547 drifted precisely because `--image rancher/k3s:<ver>`
# can be dropped/gated while the version string stays correct and CI stays green.
# Assert the create-time wiring is present in both installers so a refactor can't
# silently unpin k3s. Fixed-string (grep -F): these are literal shell/PS tokens.
_check_wiring() {  # name  file  literal
  if [[ ! -f "$2" ]]; then
    echo "  ✖ ${1}: ${2} not found" >&2; return 1
  fi
  if grep -qF "$3" "$2"; then
    echo "  ✔ ${1}: k3s --image pin present in ${2}"; return 0
  fi
  echo "  ✖ ${1}: create-time '${3}' not found in ${2} — k3s could float (#547)" >&2; return 1
}
# Wiring failures are tracked SEPARATELY from version drift: `--write` restamps
# version strings but CANNOT restore create-time wiring, so a wiring gap must not
# emit the "run --write" hint (Bugbot #565) — it needs a hand-fix.
wiring_fail=0
if [[ "$MODE" == "check" ]]; then
  _check_wiring "cluster.sh:k3s-image-pin"      "$CLUSTER" 'rancher/k3s:${K8S_VERSION}' || wiring_fail=$(( wiring_fail + 1 ))
  _check_wiring "install-k8s.ps1:k3s-image-pin" "$PS1"     'rancher/k3s:$K8S_VERSION'    || wiring_fail=$(( wiring_fail + 1 ))
  # GPU node image (client#835): the create path must derive the k3s-cuda tag from
  # BOTH pins, or a GPU cluster would pull a stale/never-built image after a bump.
  # Each shell spells the derivation its own way (braces vs none).
  _check_wiring "cluster.sh:gpu-image-pin"      "$CLUSTER" 'tracebloc/k3s-cuda:${K8S_VERSION}-cuda-${TB_CUDA_BASE_TAG}' || wiring_fail=$(( wiring_fail + 1 ))
  _check_wiring "install-k8s.ps1:gpu-image-pin" "$PS1"     'tracebloc/k3s-cuda:$K8S_VERSION-cuda-$CUDA_BASE_TAG'        || wiring_fail=$(( wiring_fail + 1 ))
fi

if [[ "$MODE" == "check" ]]; then
  rc=0
  if [[ "$drift" -ne 0 ]]; then
    echo "" >&2
    echo "check-facts: ${drift} fact(s) drifted from ${SPEC}. Run 'scripts/check-facts.sh --write' and commit." >&2
    rc=1
  fi
  if [[ "$wiring_fail" -ne 0 ]]; then
    echo "" >&2
    echo "check-facts: the k3s / GPU --image pin is missing from the create path in ${wiring_fail} file(s) (see ✖ above)." >&2
    echo "check-facts: this is a WIRING gap, not a version bump — '--write' cannot fix it. Restore the create-time" >&2
    echo "             --image pin by hand using the EXACT literal each ✖ line above shows — the two shells differ:" >&2
    echo "             bash cluster.sh uses '\${K8S_VERSION}' (braces); PowerShell install-k8s.ps1 uses" >&2
    echo "             '\$K8S_VERSION' (no braces). So k3s (and the GPU node image) can't float (#547/#835)." >&2
    rc=1
  fi
  [[ "$rc" -eq 0 ]] || exit 1
  echo "check-facts: all installer facts match ${SPEC}."
else
  [[ "$drift" -eq 0 ]] || { echo "check-facts: ${drift} consumer(s) could not be stamped (see above)." >&2; exit 1; }
  echo "check-facts: ${SPEC} stamped into all consumers."
fi
