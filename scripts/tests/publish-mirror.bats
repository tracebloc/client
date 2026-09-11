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
  # GH_VIEW_RC / GH_VIEW_ERR; everything else succeeds.
  cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [ "${1:-}" = release ] && [ "${2:-}" = view ]; then
  printf '%s\n' "${GH_VIEW_ERR:-release not found}" >&2
  exit "${GH_VIEW_RC:-1}"
fi
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

@test "release: a tag that already exists on the mirror is refused, never overwritten" {
  printf 'notes\n' >"$BATS_TEST_TMPDIR/notes.md"
  GH_VIEW_RC=0 release
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"REFUSED — release: 'v1.0.0' already exists on 'tracebloc/mirror'"* ]] || return 1
  run grep -c '^release create' "$GH_LOG"
  [ "$output" = "0" ] || return 1
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
