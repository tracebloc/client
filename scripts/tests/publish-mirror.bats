#!/usr/bin/env bats
# scripts/publish-mirror.sh — the publish half of the mirror pipeline. The
# `tree` subcommand is driven against REAL bare repositories over file:// (so the
# clone / replace / commit / plain-push path is the production one); `release`
# is driven against a recording `gh` shim, since a real release needs GitHub.
#
# What is pinned: the refusals that keep a publish from landing in the wrong
# place (no mirror named, the mirror IS the source, a diverged remote), and that
# the mirror branch ends up holding EXACTLY the stage — files removed from the
# stage disappear from the mirror, and history is appended, never rewritten.
# For `release`: a tag already on the mirror is "already done" ONLY when its
# release is identical to what this run would create (tag commit, prerelease
# flag, assets by name, sha256 and upload state) — so a re-run of a publish that
# failed after the release step goes on to the index (Bugbot on #1060: "failed
# index blocks workflow re-run") — and refused, naming every difference,
# otherwise. Mutation: with the difference refusal removed, a tag at another
# commit passes as done; the refusal test catches it.

PUB=""
BARE=""
STAGE=""
SHIM=""

setup() {
  PUB="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/publish-mirror.sh"
  BARE="$BATS_TEST_TMPDIR/mirror.git"
  STAGE="$BATS_TEST_TMPDIR/stage"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$STAGE/docs" "$SHIM"
  printf 'readme\n' >"$STAGE/README.md"
  printf 'license\n' >"$STAGE/LICENSE"
  printf 'doc\n' >"$STAGE/docs/a.md"
  git init -q --bare "$BARE"
  # gh shim: records every argv line to GH_LOG; `release view` answers per
  # GH_VIEW_RC / GH_VIEW_ERR; `api repos/../releases/tags/..` prints
  # GH_RELEASE_JSON and `api repos/../commits/..` GH_TAG_SHA (both fail with
  # GH_API_RC); everything else succeeds.
  cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case "${1:-} ${2:-}" in
  "release view")
    printf '%s\n' "${GH_VIEW_ERR:-release not found}" >&2
    exit "${GH_VIEW_RC:-1}" ;;
  "api repos/"*"/releases/tags/"*)
    [ "${GH_API_RC:-0}" -eq 0 ] || { echo "HTTP 500: planted failure" >&2; exit "$GH_API_RC"; }
    printf '%s\n' "${GH_RELEASE_JSON:?}" ;;
  "api repos/"*"/commits/"*)
    [ "${GH_API_RC:-0}" -eq 0 ] || { echo "HTTP 500: planted failure" >&2; exit "$GH_API_RC"; }
    printf '%s\n' "${GH_TAG_SHA:?}" ;;
esac
exit 0
EOF
  chmod +x "$SHIM/gh"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
}

pub() { run bash "$PUB" "$@"; }
tree() { pub tree --stage "$STAGE" --repo tracebloc/mirror --branch main --message "Publish v1.0.0" --remote "file://$BARE" "$@"; }
mirror_files() { git -C "$BARE" ls-tree -r --name-only "$1" | sort | paste -sd' ' -; }

# ── target ────────────────────────────────────────────────────────────────────

@test "target: no mirror configured is refused — there is no default" {
  pub target --mirror '' --source-repo tracebloc/client
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"REFUSED — no mirror repository is configured (MIRROR_REPO is unset)"* ]] || return 1
}

@test "target: the source repository itself is refused, case-insensitively" {
  pub target --mirror client --source-repo tracebloc/client
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"REFUSED — mirror 'tracebloc/client' is this repository"* ]] || return 1
  pub target --mirror Client --source-repo tracebloc/client
  [ "$status" -eq 1 ] || return 1
}

@test "target: a name with characters a repository cannot have, or an OWNER/NAME, is refused" {
  pub target --mirror 'cli mirror' --source-repo tracebloc/client
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"contains characters a repository name cannot"* ]] || return 1
  pub target --mirror 'other/cli' --source-repo tracebloc/client
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"must be a bare repository name"* ]] || return 1
}

@test "target: a valid mirror prints OWNER/NAME in the source's organisation" {
  pub target --mirror client-public --source-repo tracebloc/client
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "tracebloc/client-public" ] || return 1
}

@test "target: a missing --source-repo is could-not-tell (the self-publish check needs it)" {
  pub target --mirror client-public
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"COULD NOT TELL — target: --source-repo is required"* ]] || return 1
}

# --output: the workflow runs the publisher DIRECTLY and reads results from a
# file, so a refusal's ::error:: line is on stdout where Actions annotates it —
# captured through $(...) it would be swallowed by set -e (Bugbot on the PR).

@test "target: --output writes repo= and name= for the workflow; stdout still names the mirror" {
  local out="$BATS_TEST_TMPDIR/out"
  pub target --mirror client-public --source-repo tracebloc/client --output "$out"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "tracebloc/client-public" ] || return 1
  [ "$(cat "$out")" = $'repo=tracebloc/client-public\nname=client-public' ] || { cat "$out"; return 1; }
}

@test "target: a refusal puts the ::error:: line on stdout and writes nothing to --output" {
  local out="$BATS_TEST_TMPDIR/out"
  pub target --mirror '' --source-repo tracebloc/client --output "$out"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == "::error::publish-mirror: REFUSED — no mirror repository is configured"* ]] || { echo "$output"; return 1; }
  [ ! -e "$out" ] || return 1
  pub target --mirror client --source-repo tracebloc/client --output "$out"
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$out" ] || return 1
}

# ── tree ──────────────────────────────────────────────────────────────────────

@test "tree: the first publish starts the branch and the mirror holds exactly the stage" {
  tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == pushed\ [0-9a-f]* ]] || return 1
  [ "$(mirror_files main)" = "LICENSE README.md docs/a.md" ] || return 1
  [ "$(git -C "$BARE" rev-list --count main)" -eq 1 ] || return 1
}

@test "tree: an identical stage is a no-op, reported as unchanged" {
  tree; [ "$status" -eq 0 ] || return 1
  tree
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == unchanged\ [0-9a-f]* ]] || return 1
  [ "$(git -C "$BARE" rev-list --count main)" -eq 1 ] || return 1
}

@test "tree: a later publish replaces the content — removed files vanish, history is appended" {
  tree; [ "$status" -eq 0 ] || return 1
  local first
  first="$(git -C "$BARE" rev-parse main)"
  rm "$STAGE/docs/a.md"; printf 'new\n' >"$STAGE/CHANGES.md"
  tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mirror_files main)" = "CHANGES.md LICENSE README.md" ] || return 1
  [ "$(git -C "$BARE" rev-list --count main)" -eq 2 ] || return 1
  [ "$(git -C "$BARE" rev-parse main^)" = "$first" ] || return 1   # appended, not rewritten
}

@test "tree: a mirror branch with prior content not from this pipeline is replaced on top, not force-pushed over" {
  local seed="$BATS_TEST_TMPDIR/seed"
  git clone -q "file://$BARE" "$seed" 2>/dev/null
  printf 'old\n' >"$seed/old.txt"
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid add old.txt
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
  git -C "$seed" push -q origin HEAD:refs/heads/main
  local seeded
  seeded="$(git -C "$BARE" rev-parse main)"
  tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mirror_files main)" = "LICENSE README.md docs/a.md" ] || return 1
  [ "$(git -C "$BARE" rev-parse main^)" = "$seeded" ] || return 1
}

@test "tree: a remote that does not answer is could-not-tell, not a fresh start" {
  pub tree --stage "$STAGE" --repo tracebloc/mirror --branch main --message m --remote "file://$BATS_TEST_TMPDIR/no-such.git"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — tree: the mirror remote did not answer"* ]] || return 1
}

@test "tree: an empty stage, or one that is a checkout, is could-not-tell" {
  rm -r "$STAGE"; mkdir -p "$STAGE"
  tree
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"holds no files"* ]] || return 1
  mkdir -p "$STAGE/.git"; printf 'x\n' >"$STAGE/README.md"
  tree
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"contains a .git entry"* ]] || return 1
}

@test "tree: --output writes result= and sha= (pushed, then unchanged); a refusal writes nothing and annotates stdout" {
  local out="$BATS_TEST_TMPDIR/out"
  tree --output "$out"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n 1p "$out")" = "result=pushed" ] || { cat "$out"; return 1; }
  [ "$(sed -n 2p "$out")" = "sha=$(git -C "$BARE" rev-parse main)" ] || { cat "$out"; return 1; }
  rm "$out"
  tree --output "$out"
  [ "$status" -eq 0 ] || return 1
  [ "$(sed -n 1p "$out")" = "result=unchanged" ] || { cat "$out"; return 1; }
  [ "$(sed -n 2p "$out")" = "sha=$(git -C "$BARE" rev-parse main)" ] || return 1
  rm "$out"
  pub tree --stage "$STAGE" --repo tracebloc/mirror --branch main --message m --remote "file://$BATS_TEST_TMPDIR/no-such.git" --output "$out"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == "::error::publish-mirror: COULD NOT TELL — tree: the mirror remote did not answer"* ]] || { echo "$output"; return 1; }
  [ ! -e "$out" ] || return 1
}

@test "tree: an unwritable --output is could-not-tell — a result the caller never receives is not a publish" {
  tree --output "$BATS_TEST_TMPDIR/no-such-dir/out"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — could not write results to"* ]] || return 1
}

@test "tree: the result is the ONLY line printed and the scratch directory is gone afterwards (the EXIT trap really runs)" {
  # The trap used to name a `local` of cmd_tree; at exit that variable was out
  # of scope, so `set -u` printed an unbound-variable line after the result and
  # the scratch checkout stayed behind. A caller reading the last line got the
  # error, not the result.
  local tmp="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$tmp"
  TMPDIR="$tmp" tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == pushed\ [0-9a-f]* ]] || return 1
  [[ "$output" != *"unbound variable"* ]] || return 1
  [ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'publish-mirror.*')" ] || { ls "$tmp"; return 1; }
}

@test "tree: the script never forces a push" {
  run grep -nE -- '--force|\+refs/|-f[[:space:]]' "$PUB"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# ── release ───────────────────────────────────────────────────────────────────

release() {
  PATH="$SHIM:$PATH" pub release --tag v1.0.0 --repo tracebloc/mirror --target 0123456789abcdef0123456789abcdef01234567 --assets "$STAGE" --notes "$BATS_TEST_TMPDIR/notes.md" "$@"
}

@test "release: creates the tag at the target with every asset, no generated notes" {
  printf 'Release notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  release
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == "released v1.0.0 on tracebloc/mirror at 0123456789abcdef0123456789abcdef01234567 with 2 asset(s)" ]] || return 1
  grep -q '^release view v1.0.0 --repo tracebloc/mirror$' "$GH_LOG" || return 1
  local create
  create="$(grep '^release create' "$GH_LOG")"
  [[ "$create" == "release create v1.0.0 --repo tracebloc/mirror --target 0123456789abcdef0123456789abcdef01234567 --title v1.0.0 --notes-file $BATS_TEST_TMPDIR/notes.md $STAGE/LICENSE $STAGE/README.md" ]] || { echo "$create"; return 1; }
  [[ "$create" != *"--generate-notes"* ]] || return 1
  [[ "$create" != *"--prerelease"* ]] || return 1
}

@test "release: --prerelease is passed through" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  release --prerelease
  [ "$status" -eq 0 ] || return 1
  grep -q '^release create .* --prerelease ' "$GH_LOG" || return 1
}

TARGET=0123456789abcdef0123456789abcdef01234567
OTHER=ffffffffffffffffffffffffffffffffffffffff

# sum FILE — the test's own sha256 of a stage file (an oracle independent of the
# script's helper: sha256sum where it exists, shasum otherwise).
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# existing_release DRAFT PRERELEASE [NAME<TAB>DIGEST<TAB>STATE]... — the REST
# payload of v1.0.0 on the mirror as `gh api repos/../releases/tags/..` prints
# it; an empty DIGEST is a `digest: null` asset.
existing_release() {
  local draft="$1" pre="$2" assets="" a n d st dj; shift 2
  for a in "$@"; do
    # Split on each tab (not `read`, which folds the two tabs of an empty digest).
    n="${a%%$'\t'*}"; a="${a#*$'\t'}"; d="${a%%$'\t'*}"; st="${a#*$'\t'}"
    dj=null; [ -z "$d" ] || dj="\"sha256:$d\""
    assets="${assets:+$assets,}{\"name\":\"$n\",\"digest\":$dj,\"state\":\"$st\"}"
  done
  printf '{"tag_name":"v1.0.0","draft":%s,"prerelease":%s,"assets":[%s]}' "$draft" "$pre" "$assets"
}
# identical_release — v1.0.0 on the mirror exactly as `release` would create it
# from the default stage (LICENSE, README.md; docs/ is not an asset).
identical_release() { existing_release false false "LICENSE	$(sum "$STAGE/LICENSE")	uploaded" "README.md	$(sum "$STAGE/README.md")	uploaded"; }

# mutant NAME REPLACEMENT — a copy of publish-mirror.sh with the line carrying
# `# mutation-anchor: NAME` replaced by REPLACEMENT; prints its path. Refuses
# unless the anchor was found exactly once, the copy differs and still parses.
mutant() {
  local name="$1" repl="$2" copy="$BATS_TEST_TMPDIR/mutant-$name.sh" n
  n="$(grep -c -- "# mutation-anchor: $name\$" "$PUB")"
  [ "$n" -eq 1 ] || { echo "anchor $name found $n time(s), need exactly 1"; return 1; }
  awk -v a="# mutation-anchor: $name" -v r="$repl" 'index($0, a) && substr($0, length($0) - length(a) + 1) == a { print r; next } { print }' "$PUB" >"$copy"
  cmp -s "$PUB" "$copy" && { echo "mutation $name did not change the script"; return 1; }
  bash -n "$copy" || { echo "mutant $name does not parse"; return 1; }
  printf '%s\n' "$copy"
}

@test "release: a re-run finds the tag already on the mirror and identical — already done, exit 0, nothing re-created" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  export GH_RELEASE_JSON GH_TAG_SHA="$TARGET"
  GH_RELEASE_JSON="$(identical_release)"
  GH_VIEW_RC=0 release
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == "already released v1.0.0 on tracebloc/mirror at $TARGET with 2 asset(s) — the mirror's release is identical to this one, nothing re-created"* ]] || { echo "$output"; return 1; }
  # What was compared: the release by tag and the commit the tag resolves to.
  grep -q '^api repos/tracebloc/mirror/releases/tags/v1.0.0$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  grep -q '^api repos/tracebloc/mirror/commits/v1.0.0 --jq .sha$' "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
}

@test "release: a tag already on the mirror whose release is NOT this one is refused, every difference named, never overwritten" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  export GH_RELEASE_JSON GH_TAG_SHA
  # The tag names another commit.
  GH_RELEASE_JSON="$(identical_release)"; GH_TAG_SHA="$OTHER"
  GH_VIEW_RC=0 release
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — release: 'v1.0.0' already exists on 'tracebloc/mirror' and is not what this run would publish — a mirrored release is never overwritten; its tag is at $OTHER, this run publishes $TARGET"* ]] || { echo "$output"; return 1; }
  # Other bytes under one name, one asset missing, one extra: all three named.
  GH_TAG_SHA="$TARGET"
  GH_RELEASE_JSON="$(existing_release false false "LICENSE	$(sum "$STAGE/docs/a.md")	uploaded" "installer.sh	0123	uploaded")"
  GH_VIEW_RC=0 release
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"asset 'LICENSE' hashes to $(sum "$STAGE/docs/a.md") on the mirror, $(sum "$STAGE/LICENSE") here"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"asset 'README.md' is not on the mirror's release"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"asset 'installer.sh' is on the mirror's release but not in --assets"* ]] || { echo "$output"; return 1; }
  # The prerelease flag disagrees; an upload that never finished.
  GH_RELEASE_JSON="$(existing_release false true "LICENSE	$(sum "$STAGE/LICENSE")	uploaded" "README.md	$(sum "$STAGE/README.md")	open")"
  GH_VIEW_RC=0 release
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"it is prerelease=true, this run publishes prerelease=false"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"asset 'README.md' is on the mirror's release in state 'open', not uploaded"* ]] || { echo "$output"; return 1; }
  # A draft under the tag.
  GH_RELEASE_JSON="$(existing_release true false "LICENSE	$(sum "$STAGE/LICENSE")	uploaded" "README.md	$(sum "$STAGE/README.md")	uploaded")"
  GH_VIEW_RC=0 release
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"; it is a draft"* ]] || { echo "$output"; return 1; }
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
}

@test "release: a tag already on the mirror whose release cannot be read, or an asset the mirror has no digest for, is could-not-tell" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  export GH_RELEASE_JSON GH_TAG_SHA="$TARGET"
  GH_RELEASE_JSON="$(identical_release)"
  GH_VIEW_RC=0 GH_API_RC=1 release
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — release: 'v1.0.0' exists on 'tracebloc/mirror' but its release could not be read (gh exited 1: HTTP 500: planted failure)"* ]] || { echo "$output"; return 1; }
  GH_RELEASE_JSON="$(existing_release false false "LICENSE		uploaded" "README.md	$(sum "$STAGE/README.md")	uploaded")"
  GH_VIEW_RC=0 release
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — release: asset 'LICENSE' of 'v1.0.0' on 'tracebloc/mirror' has no digest — cannot tell whether it is this file"* ]] || { echo "$output"; return 1; }
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
}

@test "release mutation: with the difference refusal removed, a tag at another commit passes as already done — the refusal test catches it" {
  local m
  m="$(mutant release-existing-differs '  :')" || { echo "$m"; return 1; }
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  export GH_RELEASE_JSON GH_TAG_SHA="$OTHER"
  GH_RELEASE_JSON="$(identical_release)"
  GH_VIEW_RC=0 PATH="$SHIM:$PATH" run bash "$m" release --tag v1.0.0 --repo tracebloc/mirror --target "$TARGET" --assets "$STAGE" --notes "$BATS_TEST_TMPDIR/notes.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The mutant reports the differing release as done: the outcome the real test
  # refuses, so its assertion is live, not vacuous.
  [[ "$output" == "already released v1.0.0 on tracebloc/mirror at $TARGET"* ]] || { echo "$output"; return 1; }
}

@test "release: a view failure that is not 'not found' is could-not-tell" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  GH_VIEW_RC=1 GH_VIEW_ERR='HTTP 401: Bad credentials' release
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"COULD NOT TELL — release: could not read releases of 'tracebloc/mirror'"* ]] || return 1
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
}

@test "release: a malformed tag is refused; a short sha, empty notes or no assets are could-not-tell" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  PATH="$SHIM:$PATH" pub release --tag main --repo tracebloc/mirror --target 0123456789abcdef0123456789abcdef01234567 --assets "$STAGE" --notes "$BATS_TEST_TMPDIR/notes.md"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"'main' is not a release tag"* ]] || return 1
  PATH="$SHIM:$PATH" pub release --tag v1.0.0 --repo tracebloc/mirror --target abc123 --assets "$STAGE" --notes "$BATS_TEST_TMPDIR/notes.md"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"is not a full commit sha"* ]] || return 1
  : >"$BATS_TEST_TMPDIR/empty.md"
  PATH="$SHIM:$PATH" pub release --tag v1.0.0 --repo tracebloc/mirror --target 0123456789abcdef0123456789abcdef01234567 --assets "$STAGE" --notes "$BATS_TEST_TMPDIR/empty.md"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"notes file"*"is missing or empty"* ]] || return 1
  mkdir -p "$BATS_TEST_TMPDIR/none"
  PATH="$SHIM:$PATH" pub release --tag v1.0.0 --repo tracebloc/mirror --target 0123456789abcdef0123456789abcdef01234567 --assets "$BATS_TEST_TMPDIR/none" --notes "$BATS_TEST_TMPDIR/notes.md"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"holds no files"* ]] || return 1
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
}
