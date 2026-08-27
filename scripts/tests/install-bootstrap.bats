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
  # The list is DERIVED from install.sh's own FILES array, not restated here.
  # It used to be written out twice in this setup, and both copies had to be
  # edited by hand whenever the installer gained a lib — so adding
  # scripts/lib/telemetry.sh (backend#1907) turned ten unrelated supply-chain
  # tests red for a reason that had nothing to do with them. gen-manifest.sh
  # already reads the array this way, and cross-checks it against its own; this
  # is the third reader of the same declaration and the first that used to
  # disagree with it silently.
  BOOT_FILES=()
  while IFS= read -r _bf; do
    [ -n "$_bf" ] && BOOT_FILES+=("$_bf")
  done < <(awk '/^FILES=\(/{f=1;next} /^\)/{f=0} f' "$SCRIPTS_DIR/install.sh" \
             | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  # Fail closed: an empty list would build an empty served tree AND an empty
  # manifest, which verify against each other perfectly while testing nothing.
  [ "${#BOOT_FILES[@]}" -ge 2 ] || {
    echo "install-bootstrap: parsed ${#BOOT_FILES[@]} entries out of install.sh's FILES array — the parse is inert" >&2
    return 1
  }
  # Each stub is trivial but real bash; install-k8s.sh is the privileged
  # entrypoint — it writes a sentinel so a test can prove it was (or was NOT)
  # reached.
  for rel in "${BOOT_FILES[@]}"; do
    mkdir -p "$SERVE/$(dirname "$rel")"
    printf '#!/usr/bin/env bash\n# stub %s\n' "$rel" > "$SERVE/$rel"
  done
  cat > "$SERVE/scripts/install-k8s.sh" <<EOF
#!/usr/bin/env bash
echo "INSTALL_K8S_RAN" > "$SBX/k8s-ran"
EOF

  # ---- Build a manifest.sha256 over exactly those files (real digests) -------
  ( cd "$SERVE" && for f in "${BOOT_FILES[@]}"; do
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
  *"/releases/download/"*/manifest.sha256.sig)    src="\$serve_rel/manifest.sha256.sig" ;;
  *"/releases/download/"*/manifest.sha256.cert)   src="\$serve_rel/manifest.sha256.cert" ;;
  *"/releases/download/"*/manifest.sha256.bundle) src="\$serve_rel/manifest.sha256.bundle" ;;
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

# Run hermetically: PATH=$BIN alone AND a sandboxed HOME. Needed when a test
# passes NO REF/BRANCH (so _tb_bail_ok stays 1) *and* provides no mock `tracebloc`
# of its own: the already-installed bail-out would then find the HOST's real CLI —
# on PATH, or in ~/.local/bin which the bootstrap re-prepends — run its
# `tracebloc doctor`, and on a healthy box exec it and exit 0 before reaching the
# gate under test. Tests that DO install their own mock into $BIN (the bail-out
# cases below) stay on plain run_boot; they are already hermetic by construction.
run_boot_hermetic() {
  HOME="$SBX" PATH="$BIN" run bash "$BOOT" "$@"
}

@test "mutable BRANCH ref fails closed without the opt-in" {
  REF="" BRANCH="develop" run_boot
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not an immutable release tag"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1            # never reached the privileged step
}

@test "path-traversal ref disguised as a tag fails closed without the opt-in" {
  # 'v1.2.3-../../heads/main' once passed the tag gate (trailer was ([.-].+)?),
  # so curl collapsed the '..' and fetched sub-scripts off the MUTABLE 'main'
  # branch — the immutable-tag pin bypassed with no opt-in (RFC-0001 R8). It must
  # now be REJECTED: exit non-zero, never fetch, never reach the privileged step.
  REF="v1.2.3-../../heads/main" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ] || return 1
  # Either the tag-shape gate or the path-separator belt rejects it; both name R8.
  [[ "$output" == *"not an immutable release tag"* \
     || "$output" == *"path separator or '..'"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1            # privileged step never reached
}

@test "tag with a bare path separator fails closed without the opt-in" {
  # A '/' in the ref (e.g. a heads/ ref dressed as a tag) is a traversal lever
  # into a mutable location; reject it like the '..' case above.
  REF="v1.2.3/heads/main" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not an immutable release tag"* \
     || "$output" == *"path separator or '..'"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "un-stamped DEFAULT_REF fails closed (placeholder still present)" {
  # The committed install.sh ships the __TRACEBLOC_RELEASE_REF__ placeholder;
  # running it directly (no REF/BRANCH) must refuse rather than guess. Hermetic:
  # with no REF/BRANCH set, a host tracebloc CLI would trip the healthy-bailout.
  run_boot_hermetic
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"wasn't stamped with a pinned release tag"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "happy path: immutable tag + valid manifest + good signature runs install-k8s.sh" {
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"files intact"* ]] || return 1   # first-run copy: "All N files intact — nothing was altered"
  [ -f "$SBX/k8s-ran" ] || return 1              # privileged step reached only after verify
}

@test "bootstrap wires an explicit CA into cosign via SSL_CERT_FILE (#583)" {
  # cosign's Go HTTPS client reads SSL_CERT_FILE; behind a TLS-inspecting proxy the
  # bootstrap must set it from TRACEBLOC_CA_BUNDLE before running cosign, or the
  # signature check fails x509. Record what SSL_CERT_FILE cosign actually saw.
  # The export is Linux-only (Go reads the Keychain on macOS — next test), so pin
  # the platform: without the stub this test flips by whichever OS runs the suite.
  local ca="$SBX/corp-ca.pem"; printf 'PEM\n' > "$ca"
  rm -f "$BIN/uname"; printf '#!/usr/bin/env bash\necho Linux\n' > "$BIN/uname"; chmod +x "$BIN/uname"
  cat > "$BIN/cosign" <<EOF
#!/usr/bin/env bash
printf '%s' "\${SSL_CERT_FILE:-}" > "$SBX/cosign-ssl"
exit 0
EOF
  chmod +x "$BIN/cosign"
  REF="v9.9.9" TRACEBLOC_CA_BUNDLE="$ca" run_boot
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$SBX/cosign-ssl")" = "$ca" ] || return 1
}

@test "bootstrap on macOS does NOT export SSL_CERT_FILE (inert for Go, shrinks curl trust, Bugbot)" {
  # On Darwin, Go reads the Keychain — the export would help cosign not at all,
  # while OpenSSL curl honors SSL_CERT_FILE replace-not-augment, so a corp-root-only
  # bundle would cut download trust for zero gain. Validation still runs (next test
  # covers fail-fast); only the export is platform-gated.
  local ca="$SBX/corp-ca.pem"; printf 'PEM\n' > "$ca"
  rm -f "$BIN/uname"; cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
  chmod +x "$BIN/uname"
  cat > "$BIN/cosign" <<EOF
#!/usr/bin/env bash
printf '%s' "\${SSL_CERT_FILE:-}" > "$SBX/cosign-ssl"
exit 0
EOF
  chmod +x "$BIN/cosign"
  REF="v9.9.9" TRACEBLOC_CA_BUNDLE="$ca" run_boot
  [ "$status" -eq 0 ] || return 1
  [ -z "$(cat "$SBX/cosign-ssl")" ] || return 1
}

@test "bootstrap prefers the offline Sigstore bundle: verify-blob --bundle --offline (#584)" {
  # When a manifest.sha256.bundle is published, the bootstrap must verify it OFFLINE
  # (no live Rekor) and NOT fall back to the .sig/.cert online path — that's what makes
  # a fresh install work on a sigstore-blocked / TLS-inspecting network.
  printf 'BUNDLE\n' > "$SERVE_REL/manifest.sha256.bundle"
  cat > "$BIN/cosign" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SBX/cosign-args"
exit 0
EOF
  chmod +x "$BIN/cosign"
  REF="v9.9.9" run_boot
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SBX/k8s-ran" ] || return 1
  grep -q -- '--bundle' "$SBX/cosign-args" || return 1
  grep -q -- '--offline' "$SBX/cosign-args" || return 1
  # bundle verified => the online sig/cert path is NOT taken
  ! grep -q -- '--signature' "$SBX/cosign-args" || return 1
}

@test "bootstrap falls back to sig+cert when the bundle is present but fails offline verify (#584, reviewer)" {
  # Exercise the bundle-present-but-verify-fails -> sig/cert fallback (not covered by
  # the exit-0 bundle tests). cosign REJECTS the --bundle call but ACCEPTS sig/cert.
  printf 'BUNDLE\n' > "$SERVE_REL/manifest.sha256.bundle"
  cat > "$BIN/cosign" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SBX/cosign-args"
for a in "\$@"; do [ "\$a" = "--bundle" ] && exit 1; done   # offline bundle verify fails
exit 0                                                        # online sig/cert verify passes
EOF
  chmod +x "$BIN/cosign"
  REF="v9.9.9" run_boot
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SBX/k8s-ran" ] || return 1
  grep -q -- '--bundle' "$SBX/cosign-args" || return 1       # bundle path WAS attempted
  grep -q -- '--signature' "$SBX/cosign-args" || return 1    # ...then fell back to sig/cert
}

@test "bootstrap fails closed when BOTH the bundle and sig/cert verify fail (#584, reviewer)" {
  # Bundle present, but every cosign verify fails -> must abort, never reach the
  # privileged step (no silent fall-through to running unverified scripts).
  printf 'BUNDLE\n' > "$SERVE_REL/manifest.sha256.bundle"
  COSIGN_RESULT=1 REF="v9.9.9" run_boot
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ ! -f "$SBX/k8s-ran" ] || return 1
  [[ "$output" == *"Couldn't confirm the installer download is authentic"* ]] || return 1
}

@test "bootstrap falls back to sig+cert when no bundle is published (older release) (#584)" {
  # No bundle asset (a release cut before #584): the bundle fetch 404s and the
  # bootstrap must fall through to the online .sig/.cert keyless verification.
  [ ! -f "$SERVE_REL/manifest.sha256.bundle" ] || return 1   # precondition: no bundle
  cat > "$BIN/cosign" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SBX/cosign-args"
exit 0
EOF
  chmod +x "$BIN/cosign"
  REF="v9.9.9" run_boot
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SBX/k8s-ran" ] || return 1
  grep -q -- '--signature' "$SBX/cosign-args" || return 1   # online path used
  ! grep -q -- '--bundle' "$SBX/cosign-args" || return 1     # bundle path not taken
}

@test "bootstrap fails fast on a set-but-unreadable CA bundle (#583 Bugbot)" {
  # A bad CA path must fail here with a clear message, not silently no-op and surface
  # later as a generic cosign authenticity error.
  REF="v9.9.9" TRACEBLOC_CA_BUNDLE="/no/such/corporate-ca.pem" run_boot
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"can't be read"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "tampered sub-script aborts before the privileged step" {
  # Mutate a fetched file AFTER the manifest was built → digest mismatch.
  echo "rm -rf / # evil" >> "$SERVE/scripts/lib/provision.sh"
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Integrity check FAILED"* ]] || return 1
  [[ "$output" == *"provision.sh"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "a file missing from the manifest aborts" {
  # Drop provision.sh's line from the manifest → no expected digest for it.
  grep -v 'scripts/lib/provision.sh' "$SERVE_REL/manifest.sha256" > "$SERVE_REL/m.tmp"
  mv "$SERVE_REL/m.tmp" "$SERVE_REL/manifest.sha256"
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"isn't in the installer's signed checksum list"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "cosign signature failure aborts (no degrade to same-channel sha256)" {
  REF="v9.9.9" COSIGN_RESULT=1 run_boot
  [ "$status" -ne 0 ] || return 1
  # Message sanitized for #576 (no internal identifiers); behaviour coverage
  # (aborts + never degrades to a same-channel sha256) is unchanged.
  [[ "$output" == *"Couldn't confirm the installer download is authentic"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "cosign absent on default path fails closed (can't bootstrap in sandbox)" {
  # cosign genuinely absent (PATH=$BIN only). The cosign download is unmapped in
  # mock curl (exit 22), so ensure_cosign fails → fail-closed on the default path.
  REF="v9.9.9" run_boot_no_cosign
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"cosign is required"* ]] || return 1
  [ ! -f "$SBX/k8s-ran" ] || return 1
}

@test "unverified opt-in degrades gracefully when cosign is absent" {
  REF="v9.9.9" TRACEBLOC_ALLOW_UNVERIFIED=1 run_boot_no_cosign
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"the installer's signature NOT verified"* ]] || return 1
  [ -f "$SBX/k8s-ran" ] || return 1             # checksum integrity still enforced; runs
}

# ── Early bailout: already-healthy machine skips the whole download ──────────
# The bootstrap runs `tracebloc doctor` (bounded, exit-code gated) BEFORE any
# fetch. Healthy → print the healthy line + exec the home screen; unhealthy or
# --force → fall through to the normal (download + verify) flow. The bailout is
# skipped whenever REF/BRANCH is pinned, which is why every OTHER test here (they
# all set REF) is unaffected by it.

@test "early bailout: healthy tracebloc doctor -> execs home screen, no download" {
  # A tracebloc CLI that reports healthy; when exec'd with no args (home screen)
  # it drops a sentinel so we can prove the hand-off happened.
  cat > "$BIN/tracebloc" <<EOF
#!/usr/bin/env bash
[ "\$1" = "doctor" ] && exit 0
: > "$SBX/home-ran"
EOF
  chmod +x "$BIN/tracebloc"
  run_boot                                   # NO REF -> bailout is eligible
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Already set up and healthy"* ]] || return 1
  [ -f "$SBX/home-ran" ] || return 1                      # handed off to the home screen
  [ ! -f "$SBX/k8s-ran" ] || return 1                     # never downloaded / ran install-k8s.sh
}

@test "early bailout: unhealthy tracebloc doctor -> does NOT bail" {
  cat > "$BIN/tracebloc" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "doctor" ] && exit 3    # unhealthy
EOF
  chmod +x "$BIN/tracebloc"
  run_boot                                   # NO REF: proceeds past bailout, then
                                             # hits the un-stamped-ref refusal
  [[ "$output" != *"Already set up and healthy"* ]] || return 1
  [ ! -f "$SBX/home-ran" ] || return 1                    # no hand-off
}

@test "early bailout: --force skips the bailout even when healthy" {
  cat > "$BIN/tracebloc" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "doctor" ] && exit 0    # healthy, but --force must ignore it
EOF
  chmod +x "$BIN/tracebloc"
  run_boot --force
  [[ "$output" != *"Already set up and healthy"* ]] || return 1
  [ ! -f "$SBX/home-ran" ] || return 1
}

# ── Reinstall intent reaches install-k8s.sh's stop-and-check gate ────────────
# Skipping the bootstrap bailout is not enough: install-k8s.sh runs its OWN
# read-only assess gate that short-circuits a healthy machine and exits 0. So an
# explicit (re)install request must EXPORT TB_FORCE_REINSTALL, or a pinned-ref
# re-run downloads the new installer and then does nothing. The stub install-k8s.sh
# records the value it inherits so we can assert the propagation.
_capture_k8s_force() {
  cat > "$SERVE/scripts/install-k8s.sh" <<EOF
#!/usr/bin/env bash
echo "TB_FORCE_REINSTALL=\${TB_FORCE_REINSTALL:-unset}" > "$SBX/k8s-ran"
EOF
  # Rebuild the manifest digest for the rewritten sub-script (verify runs first).
  local newsha; newsha="$(_real_sha "$SERVE/scripts/install-k8s.sh")"
  awk -v s="$newsha" '$2 == "scripts/install-k8s.sh" { $1 = s } { print }' \
    "$SERVE_REL/manifest.sha256" > "$SERVE_REL/m.tmp"
  mv "$SERVE_REL/m.tmp" "$SERVE_REL/manifest.sha256"
}

@test "pinned REF exports TB_FORCE_REINSTALL so the assess gate can't short-circuit" {
  _capture_k8s_force
  REF="v9.9.9" COSIGN_RESULT=0 run_boot
  [ "$status" -eq 0 ] || return 1
  [ -f "$SBX/k8s-ran" ] || return 1
  [[ "$(cat "$SBX/k8s-ran")" == "TB_FORCE_REINSTALL=1" ]] || return 1
}

@test "--force also exports TB_FORCE_REINSTALL to install-k8s.sh" {
  _capture_k8s_force
  REF="v9.9.9" COSIGN_RESULT=0 run_boot --force
  [ "$status" -eq 0 ] || return 1
  [[ "$(cat "$SBX/k8s-ran")" == "TB_FORCE_REINSTALL=1" ]] || return 1
}

# prepare-host is useful precisely on a machine that is already set up (grant
# ANOTHER researcher docker-group access), so the healthy bailout must not eat
# it — but it is NOT a reinstall, so TB_FORCE_REINSTALL must stay unset or a
# stale sub-script without the prepare-host dispatch would treat the run as a
# forced full provision (Bugbot on #381). Can't pass REF here (env REF itself
# forces), so stamp DEFAULT_REF the way a release build does.
@test "prepare-host skips the healthy bailout but does NOT export TB_FORCE_REINSTALL (#381)" {
  _capture_k8s_force
  cat > "$BIN/tracebloc" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "doctor" ] && exit 0    # healthy — prepare-host must still proceed
EOF
  chmod +x "$BIN/tracebloc"
  # Rewrite only the ASSIGNMENT line (like the release pipeline) — a global
  # replace would also rewrite the placeholder-detection comparison and the
  # bootstrap would still see itself as unstamped.
  sed 's/^DEFAULT_REF=.*/DEFAULT_REF="v9.9.9"/' "$BOOT" > "$SBX/boot.stamped"
  PATH="$BIN:$PATH" run bash "$SBX/boot.stamped" prepare-host
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Already set up and healthy"* ]] || return 1
  [ -f "$SBX/k8s-ran" ] || return 1
  [[ "$(cat "$SBX/k8s-ran")" == "TB_FORCE_REINSTALL=unset" ]] || return 1
}

# backend#2253: `tracebloc upgrade` sets TB_UPGRADE_CLI=1. Like prepare-host it
# must skip the healthy bailout so install-k8s.sh's gate can update a CLI that is
# behind latest — but it is NOT a reinstall, so TB_FORCE_REINSTALL must stay
# unset (forcing it would drag a healthy box through a full re-provision instead
# of the small CLI-only download). And the flag itself must reach install-k8s.sh,
# whose gate keys on it. Records BOTH vars so a regression in either direction is
# caught. Stamp DEFAULT_REF like a release build (can't pass REF — env REF forces).
_capture_k8s_env() {
  cat > "$SERVE/scripts/install-k8s.sh" <<EOF
#!/usr/bin/env bash
echo "TB_FORCE_REINSTALL=\${TB_FORCE_REINSTALL:-unset} TB_UPGRADE_CLI=\${TB_UPGRADE_CLI:-unset}" > "$SBX/k8s-ran"
EOF
  local newsha; newsha="$(_real_sha "$SERVE/scripts/install-k8s.sh")"
  awk -v s="$newsha" '$2 == "scripts/install-k8s.sh" { $1 = s } { print }' \
    "$SERVE_REL/manifest.sha256" > "$SERVE_REL/m.tmp"
  mv "$SERVE_REL/m.tmp" "$SERVE_REL/manifest.sha256"
}

@test "TB_UPGRADE_CLI skips the healthy bailout, propagates the flag, and does NOT force a reinstall (backend#2253)" {
  _capture_k8s_env
  cat > "$BIN/tracebloc" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "doctor" ] && exit 0    # healthy — the bailout would otherwise fire
EOF
  chmod +x "$BIN/tracebloc"
  sed 's/^DEFAULT_REF=.*/DEFAULT_REF="v9.9.9"/' "$BOOT" > "$SBX/boot.stamped"
  TB_UPGRADE_CLI=1 PATH="$BIN:$PATH" run bash "$SBX/boot.stamped"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Already set up and healthy"* ]] || return 1   # bailout skipped
  [ -f "$SBX/k8s-ran" ] || return 1                                # reached install-k8s.sh
  [[ "$(cat "$SBX/k8s-ran")" == "TB_FORCE_REINSTALL=unset TB_UPGRADE_CLI=1" ]] || return 1
}
