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
# backend#3142: the flag flipping to `true` only changes the chart DEFAULT — it
# does not migrate the edges that stored `false` (plain --reuse-values, or an
# operator-pinned false), which keep authenticating as edgeuser and still need
# the fallback (docs/SECURITY.md §8.10). So the disarm must require a SECOND
# definite positive: no ackDrift hold declared on the prod pin. While the hold
# stands, resolving the float would pin past the ceiling and strand those edges.
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

# Same shape as seed_values, plus an ackDrift hold on the prod pin — the real
# chart's state during the edgeuser transition: prodDigest parked behind the
# channelTags.prod float across the data-ingestors#468 boundary, declared next to
# the pin (backend#2673). $1 = serviceDbAccountsByEnv.prod; $2 = ackDrift line.
# The reason carries a `#` and `--` on purpose (issue refs / flags), to prove the
# reader keys on `line:` and is never confused by the free-text reason.
seed_values_ack() {
  cat >"$BATS_TEST_TMPDIR/repo/client/values.yaml" <<YAML
images:
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: ""
    channelTags:
      dev: "dev"
      stg: "stg"
      prod: "0.8"
    ackDrift:
      line: "$2"
      reason: "held behind the 0.8 float across the data-ingestors#468 boundary; --reuse-values edges still need the fallback"
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

@test "guard disappears once prod is true AND no ackDrift hold stands" {
  # seed_values writes no ackDrift block — the post-transition state. With prod
  # true and no hold, --write flows. (The real chart still carries an ackDrift
  # hold; that case is covered below.)
  seed_values true
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to refresh"* ]] || return 1
  [ "$(pin)" = "sha256:2222222222222222222222222222222222222222222222222222222222222222" ] || return 1
}

@test "refuses --write while an ackDrift hold stands, even with prod true (backend#3142)" {
  seed_values_ack true "0.8"
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"refusing to refresh the prod pin"* ]] || return 1
  [[ "$output" == *"ackDrift"* ]] || return 1
}

@test "the ackDrift refusal fires BEFORE any registry round-trip, pin untouched" {
  seed_values_ack true "0.8"
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [ ! -s "$DOCKER_CALLS" ] || return 1
  [ "$(pin)" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ] || return 1
}

@test "the ackDrift refusal names its recourse: delete the block or the override" {
  seed_values_ack true "0.8"
  run bash "$RESOLVE_SH" --write
  [[ "$output" == *"delete the images.ingestor.ackDrift block"* ]] || return 1
  [[ "$output" == *"INGESTOR_PIN_ALLOW_PRE_FLAG=1"* ]] || return 1
}

@test "the ackDrift refusal surfaces the held line, not the free-text reason" {
  seed_values_ack true "0.8"
  run bash "$RESOLVE_SH" --write
  [[ "$output" == *'holds it behind'*'"0.8"'* ]] || return 1
}

@test "INGESTOR_PIN_ALLOW_PRE_FLAG=1 overrides the ackDrift hold too" {
  seed_values_ack true "0.8"
  run env INGESTOR_PIN_ALLOW_PRE_FLAG=1 bash "$RESOLVE_SH" --write
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to refresh"* ]] || return 1
  [ "$(pin)" = "sha256:2222222222222222222222222222222222222222222222222222222222222222" ] || return 1
}

@test "the flag refusal takes precedence when BOTH conditions fail" {
  # prod false AND an ackDrift hold present: the flag is the more fundamental
  # miss, so its message (not the ackDrift one) is what the operator sees.
  seed_values_ack false "0.8"
  run bash "$RESOLVE_SH" --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"serviceDbAccountsByEnv.prod is false"* ]] || return 1
  [ ! -s "$DOCKER_CALLS" ] || return 1
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
