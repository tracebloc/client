#!/usr/bin/env bash
# =============================================================================
#  gen-manifest.sh — produce scripts/manifest.sha256 (RFC-0001 R8, backend#889)
#
#  The bootstrap (scripts/install.sh) verifies every sub-script it fetches
#  against this manifest before running the privileged steps. This script
#  regenerates the manifest from the exact set the bootstrap fetches, so the
#  two never drift.
#
#  The manifest is the *integrity surface*; its *authenticity* is established
#  separately by a cosign keyless signature over this file, produced by the
#  release workflow (see docs/SUPPLY_CHAIN.md). This script does NOT sign — it
#  only computes digests, so it needs no secrets and is safe to run anywhere
#  (locally to preview, in CI to publish).
#
#  Usage:
#    scripts/gen-manifest.sh            # write scripts/manifest.sha256
#    scripts/gen-manifest.sh --check    # verify the committed manifest is current
#                                       #   (CI gate; non-zero on drift)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The single source of truth for what the bootstrap fetches. Keep in lockstep
# with the FILES array in scripts/install.sh — the --check mode below fails CI
# if a file the bootstrap fetches is missing from this list (or vice versa).
FILES=(
  "scripts/install-k8s.sh"
  "scripts/lib/common.sh"
  "scripts/lib/telemetry.sh"
  "scripts/lib/preflight.sh"
  "scripts/lib/detect-gpu.sh"
  "scripts/lib/gpu-nvidia.sh"
  "scripts/lib/gpu-amd.sh"
  "scripts/lib/setup-macos.sh"
  "scripts/lib/setup-linux.sh"
  "scripts/lib/cluster.sh"
  "scripts/lib/gpu-plugins.sh"
  "scripts/lib/install-client-helm.sh"
  "scripts/lib/install-cli.sh"
  "scripts/lib/provision.sh"
  "scripts/lib/assess.sh"
  "scripts/lib/probe.sh"
  "scripts/lib/summary.sh"
  "scripts/lib/diagnose.sh"
)

# The Windows bootstrap (scripts/install.ps1) is a separate entrypoint with its
# own integrity surface: a single self-contained sub-script. It verifies against
# the SAME signed manifest, so its file(s) must be hashed here too. Kept in
# lockstep with the $Files array in scripts/install.ps1 (checked below).
WINDOWS_FILES=(
  "scripts/install-k8s.ps1"
)

# The full set the manifest covers = both bootstraps' surfaces. install.sh only
# looks up its own bash entries and install.ps1 only its .ps1 entry, so the extra
# cross-platform lines are harmless to each; a single manifest lets one cosign
# signature anchor both entrypoints.
# An EMPTY surface must be refused explicitly. Emptying FILES makes the manifest
# cover nothing, and `--check` would then compare an empty manifest against an
# empty regeneration and agree. Today that happens to die on `set -u`'s
# "FILES[@]: unbound variable" -- a failure by accident, whose message says
# nothing about the integrity surface it just lost. backend#1729: a guard that
# passes (or fails unintelligibly) because it was disconnected from what it
# claims to check.
if [[ -z "${FILES[*]-}" || -z "${WINDOWS_FILES[*]-}" ]]; then
  echo "[ERROR] the manifest's file surface is empty." >&2
  echo "        install.sh verifies every sub-script it fetches against this manifest" >&2
  echo "        before running privileged steps; an empty manifest verifies nothing." >&2
  exit 1
fi

ALL_FILES=("${FILES[@]}" "${WINDOWS_FILES[@]}")

MANIFEST="scripts/manifest.sha256"

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "[ERROR] no sha256sum / shasum on PATH" >&2
    exit 1
  fi
}

# Cross-check: the bootstrap's FILES array must match this one exactly, or the
# manifest will be missing an entry for something the bootstrap runs (or carry
# a stale one). Extract the array from install.sh and diff.
_check_bootstrap_in_sync() {
  local boot
  boot="$(awk '/^FILES=\(/{f=1;next} /^\)/{f=0} f' scripts/install.sh \
            | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  local here
  here="$(printf '%s\n' "${FILES[@]}")"
  if [[ "$boot" != "$here" ]]; then
    echo "[ERROR] scripts/install.sh FILES array and gen-manifest.sh FILES differ:" >&2
    diff <(printf '%s\n' "$here") <(printf '%s\n' "$boot") >&2 || true
    exit 1
  fi
}

# Same cross-check for the Windows bootstrap: scripts/install.ps1's $Files array
# must match WINDOWS_FILES exactly, or the manifest would miss a digest for a
# script install.ps1 runs as Administrator (or carry a stale one). Extract the
# array (lines between `$Files = @(` and `)`) and diff.
_check_windows_bootstrap_in_sync() {
  local boot
  boot="$(awk '/^\$Files = @\($/{f=1;next} /^\)$/{f=0} f' scripts/install.ps1 \
            | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p')"
  local here
  here="$(printf '%s\n' "${WINDOWS_FILES[@]}")"
  if [[ "$boot" != "$here" ]]; then
    echo "[ERROR] scripts/install.ps1 \$Files array and gen-manifest.sh WINDOWS_FILES differ:" >&2
    diff <(printf '%s\n' "$here") <(printf '%s\n' "$boot") >&2 || true
    exit 1
  fi
}

# Cross-check 3: the DECLARATIONS above must match what install-k8s.sh actually
# SOURCES. The two checks above compare two declarations to each other; both can
# agree and both be wrong. A new scripts/lib/foo.sh that install-k8s.sh sources
# but that reaches neither array is then NEITHER fetched by the bootstrap NOR
# covered by the manifest — so at install time it is either absent (the installer
# breaks on a customer machine, after CI was green) or fetched by some other path
# and executed UNVERIFIED. That is a hole in the exact property R8 exists to
# provide. Found by @saadqbal reviewing client#755; backend#2205.
#
# DERIVED from the installer, never listed here — a fourth list would just be one
# more thing to drift. Only `${LIB_DIR}/…` sources count as repo libs: a naive
# `grep source` also matches `. /etc/os-release` (gpu-amd.sh, gpu-nvidia.sh) and
# `source "$cred_file"` (provision.sh), neither of which is in this repo.
#
# Non-transitive on purpose, and that purpose is asserted rather than assumed: no
# lib sources another lib today, so walking install-k8s.sh alone is complete. If
# that ever changes the derivation silently becomes partial, so the assumption is
# a machine check too (_check_no_lib_sources_lib below) rather than a comment
# claiming it cannot happen.
_check_sourced_libs_are_covered() {
  local sourced declared src
  # Read the file ONCE, then match the variable. The previous shape asked a
  # PIPELINE for the distinction and could not get it: under `pipefail` the status
  # is the RIGHTMOST non-zero, and the second `grep` exits 1 on empty stdin, which
  # masks the first's 2. So an unreadable installer reported "the derivation is
  # broken" and sent the reader to debug the pattern instead of the missing file.
  # The comment here used to claim that distinction worked. It did not (Asad, #770)
  # -- a comment asserting a property the code lacks is the defect this whole
  # family of guards exists to remove, so the split is now structural rather than
  # exit-code archaeology.
  src="$(cat scripts/install-k8s.sh)" || {
    echo "[ERROR] could not read scripts/install-k8s.sh to derive its sourced libs." >&2
    echo "        That is 'did not check', never 'nothing is sourced'." >&2
    exit 1
  }

  # `|| true` is safe HERE and was not safe on the old pipeline: the input is a
  # shell variable, so the only non-zero this can produce is grep's 1 for "matched
  # nothing" -- which is exactly what the guard below is for. No I/O can fail.
  # Line-ANCHORED select, then extract. `grep -oE` alone ignores what precedes the
  # match, so `#source "${LIB_DIR}/diagnose.sh"` counted as SOURCED -- a commented
  # source is not a source, and the over-fetched arm could therefore not be reached
  # by commenting one out. Anchoring also stops a mention inside a string or
  # heredoc reading as a real source.
  sourced="$(printf '%s\n' "$src" \
               | grep -E '^[[:space:]]*(source|\.)[[:space:]]+"\$\{LIB_DIR\}/[A-Za-z0-9_-]+\.sh"' \
               | grep -oE '/[A-Za-z0-9_-]+\.sh"' | tr -d '/"' | sed 's|^|scripts/lib/|' | sort -u)" || true

  # Fail closed: a derivation that finds nothing is broken, not permission to
  # pass. install-k8s.sh sources 17 libs; zero means the pattern stopped matching.
  if [[ -z "$sourced" ]]; then
    echo "[ERROR] derived ZERO sourced libs from scripts/install-k8s.sh — the derivation is broken." >&2
    echo "        Refusing to report the manifest covered on an empty derivation." >&2
    exit 1
  fi

  declared="$(printf '%s\n' "${FILES[@]}" | grep '^scripts/lib/' | sort -u)"

  if [[ "$sourced" != "$declared" ]]; then
    echo "[ERROR] scripts/install-k8s.sh sources a different set of libs than the manifest covers." >&2
    echo "        < declared in FILES only (over-fetched, or a removed lib left listed)" >&2
    echo "        > SOURCED BUT NOT COVERED — unverified at install time, and not fetched at all" >&2
    diff <(printf '%s\n' "$declared") <(printf '%s\n' "$sourced") >&2 || true
    exit 1
  fi
}

# The assumption cross-check 3 rests on: no lib sources another repo lib, so
# deriving from install-k8s.sh alone sees every lib. Asserted, because if it ever
# stops holding the derivation above goes quietly partial — the same
# "claim that should be a machine check" this whole family of guards exists for.
_check_no_lib_sources_lib() {
  local offenders rc=0 err
  err="$(mktemp)"
  # NOT `|| true`. That swallowed every failure, so the check PASSED on an
  # unreadable glob -- and this check is the assumption that makes the
  # non-transitive derivation above valid, so failing open here lets that
  # derivation go quietly partial (Asad, #770). grep -l: 1 is "no match" and is
  # the clean answer; >1 is operational and must never read as "no lib does this".
  offenders="$(grep -lE '(source|\.)[[:space:]]+"?\$\{?LIB_DIR' scripts/lib/*.sh 2>"$err")" || rc=$?
  if [[ "$rc" -gt 1 ]]; then
    echo "[ERROR] could not scan scripts/lib/*.sh for lib-to-lib sources (grep exited $rc)." >&2
    echo "        $(tr '\n' ' ' <"$err")" >&2
    echo "        Refusing to assume none: this check is what makes the non-transitive" >&2
    echo "        derivation in _check_sourced_libs_are_covered valid." >&2
    rm -f "$err"; exit 1
  fi
  rm -f "$err"
  if [[ -n "$offenders" ]]; then
    echo "[ERROR] a lib sources another lib, so deriving from install-k8s.sh alone is no longer complete:" >&2
    printf '          %s\n' $offenders >&2
    echo "        Make _check_sourced_libs_are_covered transitive before landing that." >&2
    exit 1
  fi
}

generate() {
  local f
  {
    for f in "${ALL_FILES[@]}"; do
      [[ -f "$f" ]] || { echo "[ERROR] missing file: $f" >&2; exit 1; }
      printf '%s  %s\n' "$(_sha256_of "$f")" "$f"
    done
  } > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
}

_check_bootstrap_in_sync
_check_windows_bootstrap_in_sync
_check_no_lib_sources_lib
_check_sourced_libs_are_covered

if [[ "${1:-}" == "--check" ]]; then
  generate_to="$(mktemp)"
  trap 'rm -f "$generate_to"' EXIT
  for f in "${ALL_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "[ERROR] missing file: $f" >&2; exit 1; }
    printf '%s  %s\n' "$(_sha256_of "$f")" "$f"
  done > "$generate_to"
  if ! diff -u "$MANIFEST" "$generate_to" >/dev/null 2>&1; then
    echo "[ERROR] $MANIFEST is out of date. Run scripts/gen-manifest.sh and commit." >&2
    diff -u "$MANIFEST" "$generate_to" >&2 || true
    exit 1
  fi
  echo "$MANIFEST is up to date."
  exit 0
fi

generate
echo "Wrote $MANIFEST:"
cat "$MANIFEST"
