#!/usr/bin/env bats
# Tests for scripts/install.sh — the curl|bash BOOTSTRAP (RFC-0001 R8, backend#889).
#
# The load-bearing security properties:
#   1. It only trusts an IMMUTABLE release tag; a mutable BRANCH ref fails closed
#      unless TRACEBLOC_ALLOW_UNVERIFIED=1 is set explicitly.
#   2. Each sub-script is verified against a signed manifest; a tampered file or a
#      file missing from the manifest ABORTS before install-k8s.sh runs.
#   3. The manifest signature is verified with cosign; on the default path a
#      missing/failed signature fails closed (no degrade to same-channel sha256).
#
# install.sh is a standalone `curl | bash` entrypoint, not a lib of sourceable
# functions — so we exercise it as a subprocess with curl / cosign / sha-tools
# replaced by PATH shims, and a fake "repo" served from a temp dir. No network.
load test_helper

BOOT="${BATS_TEST_DIRNAME}/../install.sh"

# Build a sandbox: a fake bin/ on PATH (mock curl + cosign + sha256sum), and a
# "served" tree the mock curl maps URLs into. SERVE/<path> stands in for any
# URL ending in <path>; SERVE_REL/<name> for a release asset.
setup() {
  SBX="$(mktemp -d)"
  BIN="$SBX/bin"; SERVE="$SBX/serve"; SERVE_REL="$SBX/serve-rel"
  mkdir -p "$BIN" "$SERVE/scripts/lib" "$SERVE_REL"

  # ---- Populate the "repo" with stand-in sub-scripts the bootstrap fetches ----
  # Each is trivial but real bash; install-k8s.sh is the privileged entrypoint —
  # it writes a sentinel so a test can prove it was (or was NOT) reached.
  for rel in install-k8s.sh \
             lib/common.sh lib/preflight.sh lib/detect-gpu.sh lib/gpu-nvidia.sh \
             lib/gpu-amd.sh lib/setup-macos.sh lib/setup-linux.sh lib/cluster.sh \
             lib/gpu-plugins.sh lib/install-client-helm.sh lib/install-cli.sh \
             lib/provision.sh lib/summary.sh lib/diagnose.sh; do
    printf '#!/usr/bin/env bash\n# stub %s\n' "$rel" > "$SERVE/scripts/$rel"
  done
  cat > "$SERVE/scripts/install-k8s.sh" <<EOF
#!/usr/bin/env bash
echo "INSTALL_K8S_RAN" > "$SBX/k8s-ran"
EOF

  # ---- Build a manifest.sha256 over exactly those files (real digests) -------
  ( cd "$SERVE" && for f in \
      scripts/install-k8s.sh scripts/lib/common.sh scripts/lib/preflight.sh \
      scripts/lib/detect-gpu.sh scripts/lib/gpu-nvidia.sh scripts/lib/gpu-amd.sh \
      scripts/lib/setup-macos.sh scripts/lib/setup-linux.sh scripts/lib/cluster.sh \
      scripts/lib/gpu-plugins.sh scripts/lib/install-client-helm.sh \
      scripts/lib/install-cli.sh scripts/lib/provision.sh scripts/lib/summary.sh \
      scripts/lib/diagnose.sh; do
        printf '%s  %s\n' "$(_real_sha "$SERVE/$f")" "$f"
      done ) > "$SERVE_REL/manifest.sha256"
  printf 'FAKE-SIG\n'  > "$SERVE_REL/manifest.sha256.sig"
  printf 'FAKE-CERT\n' > "$SERVE_REL/manifest.sha256.cert"

  # ---- Mock curl: map any -o download from a known URL tail to the served file.
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;            # ignore -fsSL --tlsv1.2 etc.
    *)  url="\$1"; shift ;;
  esac
done
serve="$SERVE"; serve_rel="$SERVE_REL"
case "\$url" in
  *"/releases/download/"*/manifest.sha256)      src="\$serve_rel/manifest.sha256" ;;
  *"/releases/download/"*/manifest.sha256.sig)  src="\$serve_rel/manifest.sha256.sig" ;;
  *"/releases/download/"*/manifest.sha256.cert) src="\$serve_rel/manifest.sha256.cert" ;;
  *raw.githubusercontent.com/*/scripts/*)       src="\$serve/scripts/\${url#*/scripts/}" ;;
  *) echo "mock curl: unmapped \$url" >&2; exit 22 ;;
esac
[ -f "\$src" ] || { echo "mock curl: 404 \$url" >&2; exit 22; }
if [ -n "\$out" ]; then cp "\$src" "\$out"; else cat "\$src"; fi
EOF
  chmod +x "$BIN/curl"

  # ---- Mock cosign: succeed by default; flip via COSIGN_RESULT for the fail test.
  cat > "$BIN/cosign" <<'EOF'
#!/usr/bin/env bash
exit "${COSIGN_RESULT:-0}"
EOF
  chmod +x "$BIN/cosign"

  # Symlink the real shell utilities the bootstrap needs into $BIN, so a test
  # can run with PATH=$BIN ALONE — that's the only reliable way to make cosign
  # genuinely "absent" on a dev box that has a real /usr/local/bin/cosign (the
  # host's cosign would otherwise shadow a removed shim). bash is invoked by
  # path, but it re-resolves `command -v` against PATH, so the tools must be here.
  for tool in bash sh env mkdir mktemp cp cat awk grep sed head tr uname chmod mv rm ln sleep printf install dirname basename sha256sum shasum; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$BIN/$tool"
  done
}

teardown() { rm -rf "$SBX"; }

# A sha256 helper usable both in setup (host PATH) and assertions.
_real_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Run the bootstrap with our mock bin first on PATH, a stamped REF, and no real
# install-k8s.sh args. Keeps the real sha tools (we WANT genuine hashing).
run_boot() {
  PATH="$BIN:$PATH" run bash "$BOOT" "$@"
}

# Run with PATH=$BIN ALONE so the host's real cosign can't shadow a removed
# shim — the only reliable way to simulate "cosign genuinely absent". $BIN has
# the needed coreutils symlinked in setup(); the sha tools come along for free.
run_boot_no_cosign() {
  rm -f "$BIN/cosign"
  PATH="$BIN" run bash "$BOOT" "$@"
}

@test "mutable BRANCH ref fails closed without the opt-in" {
  REF="" BRANCH="develop" run_boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an immutable release tag"* ]]
  [ ! -f "$SBX/k8s-ran" ]            # never reached the privileged step
}

@test "un-stamped DEFAULT_REF fails closed (placeholder still present)" {
  # The committed install.sh ships the __TRACEBLOC_RELEASE_REF__ placeholder;
  # running it directly (no REF/BRANCH) must refuse rather than guess.
  run_boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"wasn't stamped with a pinned release tag"* ]]
  [ ! -f "$SBX/k8s-ran" ]
}

@test "happy path: immutable tag + valid manifest + good signature runs install-k8s.sh" {
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified against the signed manifest"* ]]
  [ -f "$SBX/k8s-ran" ]              # privileged step reached only after verify
}

@test "tampered sub-script aborts before the privileged step" {
  # Mutate a fetched file AFTER the manifest was built → digest mismatch.
  echo "rm -rf / # evil" >> "$SERVE/scripts/lib/provision.sh"
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"Integrity check FAILED"* ]]
  [[ "$output" == *"provision.sh"* ]]
  [ ! -f "$SBX/k8s-ran" ]
}

@test "a file missing from the manifest aborts" {
  # Drop provision.sh's line from the manifest → no expected digest for it.
  grep -v 'scripts/lib/provision.sh' "$SERVE_REL/manifest.sha256" > "$SERVE_REL/m.tmp"
  mv "$SERVE_REL/m.tmp" "$SERVE_REL/manifest.sha256"
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"no entry in manifest"* ]]
  [ ! -f "$SBX/k8s-ran" ]
}

@test "cosign signature failure aborts (no degrade to same-channel sha256)" {
  REF="v9.9.9" COSIGN_RESULT=1 run_boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature verification FAILED"* ]]
  [ ! -f "$SBX/k8s-ran" ]
}

@test "cosign absent on default path fails closed (can't bootstrap in sandbox)" {
  # cosign genuinely absent (PATH=$BIN only). The cosign download is unmapped in
  # mock curl (exit 22), so ensure_cosign fails → fail-closed on the default path.
  REF="v9.9.9" run_boot_no_cosign
  [ "$status" -ne 0 ]
  [[ "$output" == *"cosign is required"* ]]
  [ ! -f "$SBX/k8s-ran" ]
}

@test "unverified opt-in degrades gracefully when cosign is absent" {
  REF="v9.9.9" TRACEBLOC_ALLOW_UNVERIFIED=1 run_boot_no_cosign
  [ "$status" -eq 0 ]
  [[ "$output" == *"manifest signature NOT verified"* ]]
  [ -f "$SBX/k8s-ran" ]             # checksum integrity still enforced; runs
}
