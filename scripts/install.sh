#!/usr/bin/env bash
# =============================================================================
#  Bootstrap installer — downloads the installer sub-scripts from GitHub and
#  runs install-k8s.sh.
#
#  SUPPLY-CHAIN HARDENING (RFC-0001 R8, backend#889)
#  -------------------------------------------------
#  This is the most privileged code in the whole product: the sub-scripts it
#  fetches mint the machine credential, write it to disk, and run Helm. So the
#  fetch is verified, not trusted:
#
#    1. Pin to an IMMUTABLE release tag (REF), not a mutable branch. Tag content
#       on GitHub is content-addressable and cannot be moved under us; a branch
#       ref can. The default REF below is bumped by the release pipeline on each
#       release (see docs/SUPPLY_CHAIN.md). `curl | bash` of THIS script from a
#       tag therefore transitively pins every sub-script to the same tag.
#    2. Fetch a signed manifest (manifest.sha256) listing the expected sha256 of
#       every sub-script, verify each file against it, and ABORT on any mismatch
#       or missing entry — BEFORE install-k8s.sh (and thus provision.sh / Helm)
#       runs.
#    3. Anchor the manifest's authenticity with a cosign keyless signature
#       (same Sigstore machinery the CLI binary already uses). On the default
#       path the signature is REQUIRED: if cosign is unavailable AND cannot be
#       bootstrapped, the install fails closed rather than silently degrading to
#       a checksum fetched over the same channel an on-path attacker controls.
#
#  Usage (macOS / Linux):
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/<TAG>/scripts/install.sh | bash
#    bash <(curl -fsSL https://tracebloc.io/i.sh)
#
#  Developer / unreleased-branch override (UNVERIFIED — not for customers):
#    curl -fsSL ... | BRANCH=develop TRACEBLOC_ALLOW_UNVERIFIED=1 bash
#
#  Windows (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
# =============================================================================
set -euo pipefail

# ── Platform gate ────────────────────────────────────────────────────────────
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "[ERROR] Windows detected. Use PowerShell instead:"
    echo "  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex"
    exit 1 ;;
esac

# ── Pinned, immutable release ref ──────────────────────────────────────────
# DEFAULT_REF is the immutable git tag this bootstrap fetches from. The release
# pipeline rewrites this line on every release so the published installer always
# pins itself to its own release (see docs/SUPPLY_CHAIN.md "Release pipeline").
# It MUST be a tag (vX.Y.Z), never a branch — a tag's bytes can't be moved.
DEFAULT_REF="__TRACEBLOC_RELEASE_REF__"

# Escape hatch for engineers iterating on an unreleased branch. This BYPASSES
# the immutable-tag guarantee and (combined with the unsigned-dev manifest path)
# the signature chain, so it is gated behind an explicit opt-in and shouts.
ALLOW_UNVERIFIED="${TRACEBLOC_ALLOW_UNVERIFIED:-0}"

# Resolve the ref to fetch from. Precedence: explicit REF env (pin a different
# release tag) > legacy BRANCH (dev only) > the pinned DEFAULT_REF. BRANCH is
# retained for backward compatibility (CI, dev docs) but now requires the
# unverified opt-in below.
if [[ -n "${REF:-}" ]]; then
  :                       # explicit pin — honored as-is
elif [[ -n "${BRANCH:-}" ]]; then
  REF="$BRANCH"
  USING_BRANCH=1
else
  REF="$DEFAULT_REF"
fi

# If the published installer wasn't stamped with a real tag (e.g. someone ran a
# raw checkout of scripts/install.sh off a branch instead of the released
# artifact), DEFAULT_REF is still the placeholder. Refuse rather than silently
# fetch from an unpinned location.
if [[ "$REF" == "__TRACEBLOC_RELEASE_REF__" ]]; then
  if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
    REF="main"
    USING_BRANCH=1
    echo "[WARN]  No pinned release ref baked into this installer; falling back to 'main' because TRACEBLOC_ALLOW_UNVERIFIED=1." >&2
  else
    echo "[ERROR] This installer wasn't stamped with a pinned release tag, so it can't verify what it fetches." >&2
    echo "        Install from a release URL:" >&2
    echo "          curl -fsSL https://raw.githubusercontent.com/tracebloc/client/<TAG>/scripts/install.sh | bash" >&2
    echo "        or, for local development only, re-run with TRACEBLOC_ALLOW_UNVERIFIED=1." >&2
    exit 1
  fi
fi

# Validate the ref shape (defends the URL we build from it).
[[ "$REF" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo "[ERROR] Invalid ref: $REF"; exit 1; }

# A ref that isn't a vX.Y.Z tag is a mutable branch — the exact thing R8 closes.
# Allow it only under the explicit unverified opt-in, and say so loudly.
# The version-suffix class is restricted to [A-Za-z0-9.] (e.g. -rc1, .4): a looser
# trailer like ([.-].+)? admits '/' and '..', so a ref such as
# 'v1.2.3-../../heads/main' would pass this gate and then curl would collapse the
# '..' to fetch sub-scripts off the MUTABLE 'main' branch — the immutable-tag
# guarantee bypassed with no opt-in (RFC-0001 R8, backend#889).
if [[ "${USING_BRANCH:-0}" == "1" || ! "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]]; then
  if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
    echo "============================================================================" >&2
    echo "[WARN]  UNVERIFIED INSTALL: fetching from mutable ref '$REF', signature checks" >&2
    echo "        relaxed. This is for tracebloc development only — never for a customer" >&2
    echo "        or production box. A moved ref here can run arbitrary privileged code." >&2
    echo "============================================================================" >&2
  else
    echo "[ERROR] '$REF' is not an immutable release tag (expected vX.Y.Z)." >&2
    echo "        The bootstrap only trusts content-addressable release tags so a moved" >&2
    echo "        branch ref can't change what runs as root on your box." >&2
    echo "        Use a release tag, or for local dev set TRACEBLOC_ALLOW_UNVERIFIED=1." >&2
    exit 1
  fi
fi

# Belt-and-suspenders: even after the shape checks above, refuse a ref carrying a
# path separator or a parent-dir token before it is interpolated into a URL. A
# '/' or '..' here is a path-traversal lever (curl collapses '..', so the fetch
# could escape the pinned tag onto a mutable branch) — independent of which
# branch above let the ref through (RFC-0001 R8, backend#889).
case "$REF" in
  */*|*..*)
    echo "[ERROR] Ref '$REF' contains a path separator or '..' — refusing to build a" >&2
    echo "        fetch URL from it (path-traversal guard)." >&2
    exit 1 ;;
esac

REPO_RAW="https://raw.githubusercontent.com/tracebloc/client/${REF}"
# The signed manifest + its cosign sig/cert are published as RELEASE ASSETS
# (not committed into the tagged tree), because signing happens in CI *after*
# the tag is cut — the same pattern the CLI uses for SHA256SUMS. The sub-script
# *content* is still pinned to the immutable tag tree above; only the manifest's
# authenticity material is served from the release.
REPO_REL="https://github.com/tracebloc/client/releases/download/${REF}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "tracebloc client installer · $REF"

mkdir -p "$TMPDIR/lib"

# The sub-scripts to fetch. This list is the integrity surface — every entry
# must have a digest in manifest.sha256 (the manifest is generated from exactly
# this set at release time; see scripts/gen-manifest.sh). Keep it in sync.
FILES=(
  "scripts/install-k8s.sh"
  "scripts/lib/common.sh"
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
  "scripts/lib/summary.sh"
  "scripts/lib/diagnose.sh"
)

download_with_retry() {
  local url="$1" dest="$2"
  local attempt max_attempts=3 delay=5
  for attempt in 1 2 3; do
    # --tlsv1.2 floor; honor any proxy / custom-CA env the corporate-proxy
    # segment relies on (#172/#722) — curl picks up HTTPS_PROXY/NO_PROXY/
    # CURL_CA_BUNDLE from the environment automatically.
    if curl -fsSL --tlsv1.2 "$url" -o "$dest"; then return 0; fi
    if [[ $attempt -ge $max_attempts ]]; then
      echo "[ERROR] Failed to download $url after $max_attempts attempts."
      exit 1
    fi
    echo "[WARN]  Download failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
    sleep "$delay"
  done
}

# ── Fetch the sub-scripts ─────────────────────────────────────────────────
for f in "${FILES[@]}"; do
  dest="$TMPDIR/${f#scripts/}"
  download_with_retry "$REPO_RAW/$f" "$dest"
done

# ── Pick a sha256 tool (coreutils on Linux, shasum on macOS) ───────────────
_sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    return 1
  fi
}

# ── Verify each sub-script against the signed manifest ─────────────────────
# manifest.sha256 lines:  <sha256>␠␠scripts/<path>
# A missing manifest, a missing line, or a digest mismatch ABORTS — before any
# privileged sub-script (provision.sh mints+writes the credential; install-
# client-helm.sh runs Helm) is executed.
verify_against_manifest() {
  local manifest="$TMPDIR/manifest.sha256"

  echo ""
  echo "Verifying the installer is authentic before anything runs…"

  if ! _sha256_of "$TMPDIR/install-k8s.sh" >/dev/null 2>&1; then
    echo "[ERROR] No sha256 tool (sha256sum / shasum) on PATH — can't verify the" >&2
    echo "        installer's integrity. Install coreutils (Linux) or ensure" >&2
    echo "        /usr/bin/shasum is on PATH (macOS), then re-run." >&2
    exit 1
  fi

  if ! download_manifest "$manifest"; then
    if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
      echo "[WARN]  No manifest.sha256 at ref '$REF' — skipping integrity check (TRACEBLOC_ALLOW_UNVERIFIED=1)." >&2
      return 0
    fi
    echo "[ERROR] Couldn't fetch manifest.sha256 for ref '$REF' — refusing to run" >&2
    echo "        unverified installer scripts. If this ref pre-dates" >&2
    echo "        signed manifests, pin a newer release tag." >&2
    exit 1
  fi

  # Authenticate the manifest itself (cosign keyless) before trusting a single
  # digest in it. Fail-closed unless explicitly opted out.
  verify_manifest_signature "$manifest"

  local f rel expected actual
  for f in "${FILES[@]}"; do
    rel="$f"                              # manifest keys are repo-relative: scripts/...
    # Match the line whose LAST field is exactly this path (independent of how
    # many spaces the sha tool emits); take its first field as the digest.
    expected="$(awk -v p="$rel" '$NF == p {print $1; exit}' "$manifest")"
    if [[ -z "$expected" ]]; then
      echo "[ERROR] $rel has no entry in manifest.sha256 — refusing to run it." >&2
      exit 1
    fi
    actual="$(_sha256_of "$TMPDIR/${f#scripts/}")"
    if [[ "$actual" != "$expected" ]]; then
      echo "[ERROR] Integrity check FAILED for $rel" >&2
      echo "          expected: $expected" >&2
      echo "          actual:   $actual" >&2
      echo "        Someone may have tampered with the installer. Aborting before any" >&2
      echo "        privileged step runs." >&2
      exit 1
    fi
  done
  echo "  ✔ All ${#FILES[@]} installer files verified — none were altered"
}

download_manifest() {
  local dest="$1"
  # Authoritative source: the signed release asset. Fall back to the in-repo
  # copy in the tag tree only under the unverified dev opt-in (a branch checkout
  # has no release assets).
  if curl -fsSL --tlsv1.2 "$REPO_REL/manifest.sha256" -o "$dest" 2>/dev/null; then
    return 0
  fi
  if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
    curl -fsSL --tlsv1.2 "$REPO_RAW/scripts/manifest.sha256" -o "$dest" 2>/dev/null
    return $?
  fi
  return 1
}

# Verify manifest.sha256 with cosign keyless. The signing identity is the
# release workflow's OIDC certificate (same chain as the CLI binary). When
# cosign is missing we try to bootstrap a pinned one; if that fails we fail
# closed (never trust the manifest's digests without authenticating the
# manifest), unless the operator explicitly accepted the risk.
verify_manifest_signature() {
  local manifest="$1"
  local sig="$TMPDIR/manifest.sha256.sig"
  local cert="$TMPDIR/manifest.sha256.cert"

  if ! ensure_cosign; then
    if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
      echo "[WARN]  cosign unavailable — manifest signature NOT verified (TRACEBLOC_ALLOW_UNVERIFIED=1)." >&2
      echo "[WARN]  Proceeding on checksum-only integrity. Not for production." >&2
      return 0
    fi
    echo "[ERROR] cosign is required to verify the installer's signed manifest and" >&2
    echo "        couldn't be found or bootstrapped. Refusing to fall back to an" >&2
    echo "        unauthenticated, same-channel checksum." >&2
    echo "        Fix: install cosign (https://docs.sigstore.dev/cosign/installation/)" >&2
    echo "        and re-run, or for local development only set TRACEBLOC_ALLOW_UNVERIFIED=1." >&2
    exit 1
  fi

  if ! curl -fsSL --tlsv1.2 "$REPO_REL/manifest.sha256.sig"  -o "$sig"  2>/dev/null \
     || ! curl -fsSL --tlsv1.2 "$REPO_REL/manifest.sha256.cert" -o "$cert" 2>/dev/null; then
    if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
      echo "[WARN]  manifest signature/cert not published for ref '$REF' — not verified (TRACEBLOC_ALLOW_UNVERIFIED=1)." >&2
      return 0
    fi
    echo "[ERROR] manifest.sha256.sig / .cert not published for release '$REF' — can't" >&2
    echo "        authenticate the manifest. Pin a release tag that ships them." >&2
    exit 1
  fi

  if "$COSIGN_BIN" verify-blob \
        --certificate-identity-regexp \
          'https://github.com/tracebloc/client/\.github/workflows/.*@.*' \
        --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
        --certificate "$cert" \
        --signature "$sig" \
        "$manifest" >/dev/null 2>&1; then
    echo "  ✔ Signature verified — published by tracebloc (Sigstore keyless)"
  else
    echo "[ERROR] cosign signature verification FAILED for manifest.sha256 — refusing" >&2
    echo "        to install." >&2
    exit 1
  fi
}

# Resolve a usable cosign into $COSIGN_BIN. Prefer one already on PATH; else
# fetch the pinned release binary for this OS/arch from the cosign GitHub
# release and verify it against its published checksums before use (a cosign we
# can't vouch for is no better than no cosign).
COSIGN_BIN=""
COSIGN_VERSION="v2.4.1"   # keep in lockstep with cli release.yml's cosign-installer pin
ensure_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN="cosign"
    return 0
  fi

  local os arch
  case "$(uname -s)" in
    Linux)  os="linux"  ;;
    Darwin) os="darwin" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) return 1 ;;
  esac

  local base="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}"
  local asset="cosign-${os}-${arch}"
  local bin="$TMPDIR/cosign"
  local sums="$TMPDIR/cosign_checksums.txt"

  echo "  · Fetching the signature-verification tool (cosign)…"
  curl -fsSL --tlsv1.2 "$base/$asset"               -o "$bin"  2>/dev/null || return 1
  curl -fsSL --tlsv1.2 "$base/cosign_checksums.txt" -o "$sums" 2>/dev/null || return 1

  local want got
  want="$(grep " ${asset}\$" "$sums" | awk '{print $1}' | head -1)"
  [[ -n "$want" ]] || return 1
  got="$(_sha256_of "$bin")" || return 1
  if [[ "$want" != "$got" ]]; then
    echo "[ERROR] Bootstrapped cosign failed its own checksum — not using it." >&2
    return 1
  fi
  chmod +x "$bin"
  COSIGN_BIN="$bin"
  return 0
}

verify_against_manifest

chmod +x "$TMPDIR/install-k8s.sh"

bash "$TMPDIR/install-k8s.sh" "$@"
