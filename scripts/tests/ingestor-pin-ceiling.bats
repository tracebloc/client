#!/usr/bin/env bats
# Tests for the ordering ceiling in scripts/resolve-ingestor-digest.sh --write.
#
# backend#1528: while `serviceDbAccountsByEnv.prod` is false, prod still
# authenticates as the shared `edgeuser`, so its ingestor must be a release that
# still HAS the edgeuser fallback. data-ingestors#468 removed that fallback, and
# `channelTags.prod` floats past it — values.yaml pins prodDigest DELIBERATELY
# behind the float and says so in prose. The helper resolves that float and knew
# nothing about the ceiling, so following values.yaml's own "use the helper,
# never pin by hand" advice silently produced the wrong answer. client#490
# nearly shipped exactly that.
#
# The guard must also fail BEFORE the registry round-trip: refusing afterwards
# wastes the call and buries the reason under network output. The docker stub
# records every invocation so that ordering is asserted, not assumed.

RESOLVE_SH=""

setup() {
  cd "$BATS_TEST_TMPDIR" || return 1
  rm -rf repo && mkdir -p repo/scripts repo/client repo/bin || return 1
  cp "${BATS_TEST_DIRNAME}/../resolve-ingestor-digest.sh" repo/scripts/
  RESOLVE_SH="$BATS_TEST_TMPDIR/repo/scripts/resolve-ingestor-digest.sh"

  seed_values false
  seed_docker_stub
  PATH="$BATS_TEST_TMPDIR/repo/bin:$PATH"
}

# values.yaml shaped like the real chart: a floating channel tag for prod, a
# prodDigest deliberately behind it, and decoy `prod:` leaves that the reader
# must not mistake for serviceDbAccountsByEnv.prod.
seed_values() {
  cat >"$BATS_TEST_TMPDIR/repo/client/values.yaml" <<YAML
images:
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: ""
    channelTags:
      dev: "dev"
      stg: "stg"
      prod: "0.8"
    prodDigest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    prodPin: true

serviceDbAccountsByEnv:
  dev: true
  stg: true
  prod: $1
YAML
}

# Stub buildx so the non-refusing paths never touch the network, and so a test
# can prove whether the registry was contacted at all.
seed_docker_stub() {
  cat >"$BATS_TEST_TMPDIR/repo/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >>"$DOCKER_CALLS"
case "$*" in
  *imagetools*inspect*--raw*) echo '{"manifests":[]}' ;;
  *imagetools*inspect*)
    echo "Name:      ghcr.io/tracebloc/ingestor:0.8"
    echo "MediaType: application/vnd.oci.image.index.v1+json"
    echo "Digest:    sha256:2222222222222222222222222222222222222222222222222222222222222222"
    echo ""
    echo "Manifests:"
    echo "  Platform:  linux/amd64"
    echo "  Platform:  linux/arm64"
    ;;
esac
exit 0
SH
  chmod +x "$BATS_TEST_TMPDIR/repo/bin/docker"
  export DOCKER_CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : >"$DOCKER_CALLS"
}

pin() { grep -o 'sha256:[0-9a-f]\{64\}' "$BATS_TEST_TMPDIR/repo/client/values.yaml" | head -1; }

@test "refuses --write while serviceDbAccountsByEnv.prod is false" {
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"refusing to refresh the prod pin"* ]] || return 1
}

@test "the refusal names both escape hatches" {
  run bash "$RESOLVE_SH" --write
  [[ "$output" == *"serviceDbAccountsByEnv.prod to true"* ]] || return 1
  [[ "$output" == *"INGESTOR_PIN_ALLOW_PRE_FLAG=1"* ]] || return 1
}

@test "refusal leaves the existing pin untouched" {
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [ "$(pin)" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ] || return 1
}

@test "refusal happens BEFORE any registry round-trip" {
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [ ! -s "$DOCKER_CALLS" ] || return 1
}

@test "INGESTOR_PIN_ALLOW_PRE_FLAG=1 allows the refresh" {
  run env INGESTOR_PIN_ALLOW_PRE_FLAG=1 bash "$RESOLVE_SH" --write
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to refresh"* ]] || return 1
  [ "$(pin)" = "sha256:2222222222222222222222222222222222222222222222222222222222222222" ] || return 1
}

@test "guard disappears once prod flips to true" {
  seed_values true
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to refresh"* ]] || return 1
  [ "$(pin)" = "sha256:2222222222222222222222222222222222222222222222222222222222222222" ] || return 1
}

@test "read-only resolution is never blocked" {
  run bash "$RESOLVE_SH"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to refresh"* ]] || return 1
  # untouched: the read-only path must not write
  [ "$(pin)" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ] || return 1
}

@test "a sibling prod: leaf cannot be mistaken for the flag" {
  # channelTags.prod is "0.8" (not true/false) and dev/stg are true; if the
  # reader escaped its block it would read one of those and stop firing.
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"refusing to refresh the prod pin"* ]] || return 1
}

@test "fails closed when the flag key is absent entirely" {
  # Deleting the key must not disarm the guard: absence is not evidence the
  # ceiling lifted. Only a definite `true` unlocks the write.
  cat >"$BATS_TEST_TMPDIR/repo/client/values.yaml" <<'YAML'
images:
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: "0.8"
    prodDigest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    prodPin: true
YAML
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"could not read serviceDbAccountsByEnv.prod"* ]] || return 1
  [ ! -s "$DOCKER_CALLS" ] || return 1
}

@test "fails closed on an unparseable flag value" {
  seed_values "maybe"
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"refusing to refresh the prod pin"* ]] || return 1
}
