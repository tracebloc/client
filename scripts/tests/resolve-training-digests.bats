#!/usr/bin/env bats
# resolve-training-digests.sh — the pin-writing step for images.training
# (RFC-1246 P2 / RFC-0067 D8, backend#3156). The registry is replaced by two
# seams so every refusal can be driven without a network:
#   TRAINING_REPOS_STUB    one repository name per line
#   TRAINING_RESOLVE_STUB  `ns/repo:tag<0x1f>digest` and `ns/repo@digest<0x1f>caps=<v>`
# A pin with NO caps line is UNREADABLE; `caps=` with nothing after it is a
# readable image that declares no label. The distinction is the point of half of
# these cases: unreadable refuses, unlabelled writes "".

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../resolve-training-digests.sh"
  TMP="$(mktemp -d)"
  SEP="$(printf '\037')"
  D_IC_CPU="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  D_IC_GPU="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  D_TC_CPU="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  D_TC_GPU="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  printf '%s\n' client-image_classification-cpu client-image_classification-gpu \
                client-tabular_classification-cpu client-tabular_classification-gpu \
                jobs-manager pods-monitor > "$TMP/repos"
  : > "$TMP/stub"
  digest_line "tracebloc/client-image_classification-cpu:prod" "$D_IC_CPU"
  digest_line "tracebloc/client-image_classification-gpu:prod" "$D_IC_GPU"
  digest_line "tracebloc/client-tabular_classification-cpu:prod" "$D_TC_CPU"
  digest_line "tracebloc/client-tabular_classification-gpu:prod" "$D_TC_GPU"
  caps_line "tracebloc/client-image_classification-gpu" "$D_IC_GPU" "ddp"
  caps_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" "ddp"
  values_fixture '""'
}
teardown() { rm -rf "$TMP"; }

digest_line() { printf '%s%s%s\n' "$1" "$SEP" "$2" >> "$TMP/stub"; }
caps_line()   { printf '%s@%s%scaps=%s\n' "$1" "$2" "$SEP" "$3" >> "$TMP/stub"; }
drop_caps()   { grep -v "^$1@" "$TMP/stub" > "$TMP/stub.new" && mv "$TMP/stub.new" "$TMP/stub"; }
inspect_line(){ printf '%s@%s%sinspect=%s\n' "$1" "$2" "$SEP" "$3" >> "$TMP/stub"; }
# A captured `{{json .Image}}` shape: one entry per manifest of the index, keyed by
# platform. $1..$n are `platform=caps` pairs; caps `-` means the config carries no
# Labels at all (what the attestation manifest looks like).
image_json() {
  local out="{" sep="" pair plat caps os arch
  for pair in "$@"; do
    plat="${pair%%=*}"; caps="${pair#*=}"; os="${plat%%/*}"; arch="${plat#*/}"
    out+="$sep\"$plat\": {\"architecture\": \"$arch\", \"os\": \"$os\", \"config\": {"
    [[ "$caps" == "-" ]] || out+="\"Labels\": {\"io.tracebloc.engine.capabilities\": \"$caps\"}"
    out+="}}"; sep=", "
  done
  printf '%s}\n' "$out"
}
values_fixture() {  # <pinned literal>
  cat > "$TMP/values.yaml" <<EOF
global:
  imageRegistry: ""
images:
  jobsManager:
    digest: ""
  # -- the training block, as the chart ships it
  training:
    pinned: $1
    digests: {}
    capabilities: ""
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: ""
resources:
  limits: {}
EOF
}
run_resolve() {
  TRAINING_REPOS_STUB="$TMP/repos" TRAINING_RESOLVE_STUB="$TMP/stub" CHART_VALUES="$TMP/values.yaml" run "$SCRIPT" "$@"
}

@test "a complete, agreeing set renders every task x arch and the derived capabilities" {
  run_resolve
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"STUBBED"* ]] || return 1
  [[ "$output" == *"      image_classification:"* ]] || return 1
  [[ "$output" == *"        cpu: \"$D_IC_CPU\""* ]] || return 1
  [[ "$output" == *"        gpu: \"$D_IC_GPU\""* ]] || return 1
  [[ "$output" == *"      tabular_classification:"* ]] || return 1
  [[ "$output" == *"    capabilities: \"ddp\""* ]] || return 1
  [[ "$output" == *"resolved 2 task(s) x 2 arch(es)"* ]] || return 1
}

@test "the repository list is derived: non-training repos in the namespace are ignored, not refused" {
  run_resolve
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"jobs-manager"* ]] || return 1
}

@test "a GPU image whose label cannot be read is REFUSED -- unreadable is not empty" {
  drop_caps "tracebloc/client-tabular_classification-gpu"
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"REFUSED"* ]] || return 1
  [[ "$output" == *"could not be read"* ]] || return 1
  [[ "$output" == *"Unreadable is not empty"* ]] || return 1
}

@test "a readable GPU image that declares NO label writes capabilities \"\" and says so" {
  drop_caps "tracebloc/client-image_classification-gpu"
  drop_caps "tracebloc/client-tabular_classification-gpu"
  caps_line "tracebloc/client-image_classification-gpu" "$D_IC_GPU" ""
  caps_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" ""
  run_resolve
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"    capabilities: \"\""* ]] || return 1
  [[ "$output" == *"declares none"* ]] || return 1
}

@test "GPU images that DISAGREE on the label are REFUSED, naming each" {
  drop_caps "tracebloc/client-tabular_classification-gpu"
  caps_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" ""
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"DISAGREE"* ]] || return 1
  [[ "$output" == *"image_classification"*"ddp"* ]] || return 1
  [[ "$output" == *"tabular_classification"*"(no label)"* ]] || return 1
}

@test "an attestation manifest (unknown/unknown) is filtered out of the label, not read as a disagreement" {
  drop_caps "tracebloc/client-image_classification-gpu"
  drop_caps "tracebloc/client-tabular_classification-gpu"
  image_json "linux/amd64=ddp" "linux/arm64=ddp" "unknown/unknown=-" > "$TMP/ic.json"
  image_json "linux/amd64=ddp" "unknown/unknown=-" > "$TMP/tc.json"
  inspect_line "tracebloc/client-image_classification-gpu" "$D_IC_GPU" "$TMP/ic.json"
  inspect_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" "$TMP/tc.json"
  run_resolve
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"across its platforms"* ]] || return 1
  [[ "$output" == *"    capabilities: \"ddp\""* ]] || return 1
}

@test "the attestation filter does not swallow a REAL disagreement between platforms of one image" {
  # Both GPU images carry the SAME split (amd64 labelled, arm64 not), so the
  # cross-task agreement check passes and the intra-image refusal is what fires.
  drop_caps "tracebloc/client-image_classification-gpu"
  drop_caps "tracebloc/client-tabular_classification-gpu"
  image_json "linux/amd64=ddp" "linux/arm64=-" "unknown/unknown=-" > "$TMP/split.json"
  inspect_line "tracebloc/client-image_classification-gpu" "$D_IC_GPU" "$TMP/split.json"
  inspect_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" "$TMP/split.json"
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"REFUSED"* ]] || return 1
  [[ "$output" == *"across its platforms"* ]] || return 1
}

@test "a single-platform image (one config, no platform map) still reads its label" {
  drop_caps "tracebloc/client-tabular_classification-gpu"
  printf '{"architecture": "amd64", "os": "linux", "config": {"Labels": {"io.tracebloc.engine.capabilities": "ddp"}}}\n' > "$TMP/tc.json"
  inspect_line "tracebloc/client-tabular_classification-gpu" "$D_TC_GPU" "$TMP/tc.json"
  run_resolve
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"    capabilities: \"ddp\""* ]] || return 1
}

@test "a task with only one arch is REFUSED as a promotion bug" {
  grep -v '^client-tabular_classification-gpu$' "$TMP/repos" > "$TMP/repos.new" && mv "$TMP/repos.new" "$TMP/repos"
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"has no 'gpu' image"* ]] || return 1
  [[ "$output" == *"promotion bug"* ]] || return 1
}

@test "a float that does not resolve to a canonical digest is REFUSED" {
  grep -v '^tracebloc/client-image_classification-cpu:prod' "$TMP/stub" > "$TMP/stub.new" && mv "$TMP/stub.new" "$TMP/stub"
  digest_line "tracebloc/client-image_classification-cpu:prod" "sha256:abc"
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"could not resolve tracebloc/client-image_classification-cpu:prod"* ]] || return 1
}

@test "no training repositories at all is REFUSED, not an empty map" {
  printf 'jobs-manager\n' > "$TMP/repos"
  run_resolve
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no training image repositories found"* ]] || return 1
}

@test "--write replaces only the training block, preserves pinned, and leaves every other line byte-identical" {
  values_fixture '"false"'
  cp "$TMP/values.yaml" "$TMP/before.yaml"
  run_resolve --write
  [ "$status" -eq 0 ] || return 1
  grep -q '^    pinned: "false"$' "$TMP/values.yaml" || return 1
  grep -q "^        gpu: \"$D_TC_GPU\"$" "$TMP/values.yaml" || return 1
  grep -q '^    capabilities: "ddp"$' "$TMP/values.yaml" || return 1
  # Everything outside `  training:` and its 4+-space subtree is unchanged.
  strip() { awk '/^  training:/ { skip = 1; next } skip && /^    / { next } { skip = 0; print }' "$1"; }
  diff <(strip "$TMP/before.yaml") <(strip "$TMP/values.yaml") || return 1
}

@test "--write is idempotent" {
  run_resolve --write
  [ "$status" -eq 0 ] || return 1
  cp "$TMP/values.yaml" "$TMP/once.yaml"
  run_resolve --write
  [ "$status" -eq 0 ] || return 1
  diff "$TMP/once.yaml" "$TMP/values.yaml" || return 1
}

@test "--write refuses a chart that has no images.training block" {
  printf 'images:\n  jobsManager:\n    digest: ""\n' > "$TMP/values.yaml"
  run_resolve --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no 'images.training' block"* ]] || return 1
}

@test "a stubbed run is banner-marked so it can never pass as an audit" {
  run_resolve
  [[ "$output" == *"NOT a real resolution"* ]] || return 1
}

@test "--write does not mistake another 2-space training: key for images.training" {
  # networkPolicy.training exists in the real chart; a bare grep matched it.
  printf 'images:\n  jobsManager:\n    digest: ""\nnetworkPolicy:\n  training:\n    enabled: true\n' > "$TMP/values.yaml"
  run_resolve --write
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no 'images.training' block"* ]] || return 1
  grep -q '^    enabled: true$' "$TMP/values.yaml" || return 1
}

@test "--write reads the block back and reports success only when it landed" {
  run_resolve --write
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"read back and verified"* ]] || return 1
}
