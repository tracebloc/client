#!/usr/bin/env bash
# =============================================================================
#  publish-mirror.sh — the publish half of the mirror pipeline: push what
#  scripts/publish-guard.sh staged and cleared to the public mirror repository.
#
#  Four subcommands, each one step of the workflow, each refusing on its own:
#
#    target   --mirror NAME --source-repo OWNER/REPO [--owner OWNER]
#             [--output FILE]
#             Validate the mirror name and print OWNER/NAME. Refuses an empty
#             name (the mirror is unset until it exists — there is no default),
#             a name with characters GitHub does not allow, and a target equal
#             to the source repository: publishing onto the source would
#             replace the default branch of the repo you are standing in.
#             --output appends `repo=OWNER/NAME` and `name=NAME` to FILE (the
#             workflow passes $GITHUB_OUTPUT).
#
#    tree     --stage DIR --repo OWNER/NAME --branch NAME --message TEXT
#             [--remote URL] [--output FILE]
#             Clone the mirror branch (or start it when the mirror has none),
#             replace its content with DIR, commit, PLAIN push. A diverged
#             remote rejects the push; nothing here ever forces. Prints
#             `pushed <sha>` or `unchanged <sha>`; --output appends
#             `result=pushed|unchanged` and `sha=<sha>` to FILE.
#
#  Results go to --output, refusals go to stdout: a caller that captured stdout
#  with `$(...)` to read the result would swallow the `::error::` line of a
#  refusal, so the workflow runs these commands directly and reads the file.
#  Nothing is written to --output on a refusal.
#
#    release  --tag TAG --repo OWNER/NAME --target SHA --assets DIR
#             --notes FILE [--prerelease]
#             Create TAG on the mirror at SHA with every file in DIR attached.
#             When TAG already exists on the mirror and its release IS this one
#             — the tag names SHA, published (not a draft) with the same
#             prerelease flag, its assets exactly DIR's files by name and
#             sha256, every one uploaded — it is already done: exit 0, nothing
#             re-created, so a re-run of a publish that failed AFTER this step
#             (dates, helm, index, the gh-pages push) goes on to rebuild the
#             index. Any other existing TAG is refused: a published release is
#             never overwritten, and a differing one is a human decision.
#
#    index    --repo OWNER/NAME --source-releases FILE --out DIR
#             [--remote URL] [--forbidden FILE] [--extra-forbidden FILE]...
#             [--strict] [--helm BIN] [--allow-empty] [--output FILE]
#             Rebuild the Helm repository index the mirror's gh-pages serves
#             from the chart tarballs on the MIRROR's own releases — never from
#             the source repository's Pages branch, whose URLs name the source.
#             Every stable release of the mirror is read (drafts and
#             prereleases are left out, as the chart workflow leaves them out
#             of the source's index); each `<chart>-<version>.tgz` is
#             downloaded from the mirror, verified against the mirror's asset
#             digest and against what `helm show chart` reads inside it, and
#             placed once, under the OLDEST release that carries it, at
#             charts/<tag>/<file> — `helm repo index --url
#             https://github.com/OWNER/NAME/releases/download` then yields each
#             chart's own release-asset URL. `created` is set to the ORIGINAL
#             publish date of that release, read from --source-releases (the
#             source repository's release list as `gh api --paginate
#             repos/OWNER/REPO/releases` prints it — the caller reads it, because
#             a token scoped to the mirror cannot), so the same mirror yields the
#             same index bytes on every run. The mirror's current gh-pages is
#             fetched from --remote (default https://github.com/OWNER/NAME.git);
#             every other file on it is kept and staged again, index.yaml is
#             replaced only when it differs apart from `generated:`. The staged
#             branch goes through scripts/publish-guard.sh — the index as text,
#             the tarballs already on the branch as opaque binaries — with
#             --forbidden (default: this repo's .publish-forbidden), every
#             --extra-forbidden list and --strict, like every other uploaded
#             text asset. Nothing is pushed: the caller pushes DIR/stage with
#             `tree --branch gh-pages` when `changed=true`.
#             Writes to --output: charts=N stable_releases=N changed=true|false
#             pages_existed=true|false download_base=URL stage=DIR/stage
#             index=DIR/index.yaml. Refuses (1) a mirror with no chart tarball
#             on any stable release unless --allow-empty (then charts=0,
#             changed=false, exit 0 — a dry run before the first release), and
#             a guard refusal. Could-not-tell (2): helm or gh missing, a mirror
#             read that fails, a tarball whose bytes are not the mirror's digest
#             or not the chart its name says, a mirror release the source list
#             has no date for, a guard that could not tell.
#
#  Exit 0 done; 1 refused (the message says why); 2 could not tell (an input
#  missing or unreadable, a remote that did not answer). "Cannot tell" never
#  publishes.
#
#  Authentication is the caller's: git reads its credential helper, `gh` reads
#  GH_TOKEN. Nothing here takes a token argument, so no token can land on a
#  command line. Commits are authored as PUBLISH_MIRROR_GIT_NAME /
#  PUBLISH_MIRROR_GIT_EMAIL (default: github-actions[bot]).
# =============================================================================
set -uo pipefail

die1() { echo "::error::publish-mirror: REFUSED — $1"; exit 1; }
die2() { echo "::error::publish-mirror: COULD NOT TELL — $1 (never publishes)"; exit 2; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
NAME_RE='^[A-Za-z0-9_.-]+$'
# <chart>-<version>.tgz: the chart name, then a semver (with an optional
# prerelease suffix). Both parts are read off the file name and, under `index`,
# checked against what `helm show chart` reads inside the tarball.
CHART_FILE_RE='^([A-Za-z0-9_.-]+)-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)\.tgz$'

# sha256_of FILE — the hex digest, with whichever of sha256sum / shasum is here
# (`release` and `index` both check one is before any read of the mirror).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# emit_output FILE KEY=VALUE... — append results for the caller (the workflow's
# $GITHUB_OUTPUT). An unwritable file is "could not tell": a result the caller
# never receives is a publish it cannot finish or account for.
emit_output() {
  local file="$1"; shift
  [ -n "$file" ] || return 0
  printf '%s\n' "$@" >>"$file" || die2 "could not write results to '$file'"
}

cmd_target() {
  local mirror="" source_repo="" owner="" output=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mirror)      mirror="${2:-}"; shift 2 ;;
      --source-repo) source_repo="${2:-}"; shift 2 ;;
      --owner)       owner="${2:-}"; shift 2 ;;
      --output)      output="${2:-}"; shift 2 ;;
      *) die2 "target: unknown argument '$1'" ;;
    esac
  done
  [ -n "$source_repo" ] || die2 "target: --source-repo is required"
  [[ "$source_repo" =~ $REPO_RE ]] || die2 "target: --source-repo '$source_repo' is not OWNER/REPO"
  [ -n "$owner" ] || owner="${source_repo%%/*}"
  [ -n "$mirror" ] || die1 "no mirror repository is configured (MIRROR_REPO is unset) — the mirror has no default, so nothing is published until one is named"
  case "$mirror" in */*) die1 "mirror name '$mirror' must be a bare repository name in the '$owner' organisation, not OWNER/NAME" ;; esac
  [[ "$mirror" =~ $NAME_RE ]] || die1 "mirror name '$mirror' contains characters a repository name cannot"
  local full="$owner/$mirror"
  if [ "$(printf '%s' "$full" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$source_repo" | tr '[:upper:]' '[:lower:]')" ]; then
    die1 "mirror '$full' is this repository — publishing onto the source would replace its default branch"
  fi
  emit_output "$output" "repo=$full" "name=$mirror"
  printf '%s\n' "$full"
}

cmd_tree() {
  local stage="" repo="" branch="" message="" remote="" output=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stage)   stage="${2:-}"; shift 2 ;;
      --repo)    repo="${2:-}"; shift 2 ;;
      --branch)  branch="${2:-}"; shift 2 ;;
      --message) message="${2:-}"; shift 2 ;;
      --remote)  remote="${2:-}"; shift 2 ;;
      --output)  output="${2:-}"; shift 2 ;;
      *) die2 "tree: unknown argument '$1'" ;;
    esac
  done
  [ -n "$stage" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$message" ] || die2 "tree: --stage, --repo, --branch and --message are all required"
  [[ "$repo" =~ $REPO_RE ]] || die2 "tree: --repo '$repo' is not OWNER/NAME"
  [[ "$branch" =~ ^[A-Za-z0-9_./-]+$ ]] || die2 "tree: --branch '$branch' is not a branch name"
  [ -d "$stage" ] || die2 "tree: stage '$stage' is not a directory"
  [ -n "$(find "$stage" -type f | head -1)" ] || die2 "tree: stage '$stage' holds no files — an empty deliverable is not published"
  [ ! -e "$stage/.git" ] || die2 "tree: stage '$stage' contains a .git entry — that is a checkout, not a staged deliverable"
  [ -n "$remote" ] || remote="https://github.com/$repo.git"

  local name="${PUBLISH_MIRROR_GIT_NAME:-github-actions[bot]}"
  local email="${PUBLISH_MIRROR_GIT_EMAIL:-github-actions[bot]@users.noreply.github.com}"
  # The checkout lives in its own subdirectory of the scratch dir; error
  # captures live BESIDE it, never inside it, or they would be committed.
  # SCRATCH is deliberately NOT `local`: the EXIT trap runs after this function
  # has returned, where a local is out of scope — under `set -u` that was an
  # "unbound variable" line on stderr at every exit and a scratch directory
  # never removed (the cleanup silently did nothing).
  local work
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/publish-mirror.XXXXXX")" && [ -d "$SCRATCH" ] || die2 "tree: could not create a scratch directory"
  trap 'rm -rf "$SCRATCH"' EXIT
  local scratch="$SCRATCH"
  work="$scratch/work"
  mkdir -p "$work" || die2 "tree: could not create the checkout directory"

  git -C "$work" init -q || die2 "tree: git init failed"
  git -C "$work" remote add origin "$remote" || die2 "tree: could not add remote"
  # Absent-vs-unreachable are different answers: ls-remote's own status says
  # whether the remote answered; an empty answer says the branch is not there.
  local heads rc existed=0
  heads="$(git -C "$work" ls-remote --heads origin "refs/heads/$branch" 2>"$scratch/lsr.err")"; rc=$?
  [ "$rc" -eq 0 ] || die2 "tree: the mirror remote did not answer (git ls-remote exited $rc: $(tr '\n' ' ' <"$scratch/lsr.err"))"
  if [ -n "$heads" ]; then
    existed=1
    git -C "$work" fetch -q --depth 1 origin "refs/heads/$branch" || die2 "tree: could not fetch '$branch' from the mirror"
    git -C "$work" checkout -q -B "$branch" FETCH_HEAD || die2 "tree: could not check out '$branch'"
    find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || die2 "tree: could not clear the checkout"
  else
    git -C "$work" checkout -q --orphan "$branch" || die2 "tree: could not start branch '$branch'"
  fi
  cp -Rp "$stage"/. "$work"/ || die2 "tree: could not copy the stage into the checkout"
  git -C "$work" add -A || die2 "tree: git add failed"
  local sha
  if [ "$existed" -eq 1 ] && git -C "$work" diff --cached --quiet; then
    sha="$(git -C "$work" rev-parse HEAD)"
    emit_output "$output" "result=unchanged" "sha=$sha"
    echo "unchanged $sha"
    return 0
  fi
  git -C "$work" -c user.name="$name" -c user.email="$email" commit -q -m "$message" || die2 "tree: git commit failed"
  # A PLAIN push. If the mirror moved underneath us the push is rejected and
  # this exits 2; the answer is to re-run, never to force.
  git -C "$work" push -q origin "HEAD:refs/heads/$branch" 2>"$scratch/push.err" || die2 "tree: push to '$repo' '$branch' was rejected: $(tr '\n' ' ' <"$scratch/push.err")"
  sha="$(git -C "$work" rev-parse HEAD)"
  emit_output "$output" "result=pushed" "sha=$sha"
  echo "pushed $sha"
}

# release_existing_is_this TAG REPO TARGET PRERELEASE FILE... — TAG is already
# on REPO. Returns when the mirror's release IS the one this run would create:
# the tag names TARGET (read as the commit it resolves to, so an annotated tag
# from the backfill counts too), it is published with the same prerelease flag,
# and its assets are exactly FILE... by name, sha256 and upload state. That is
# a re-run of a publish that failed AFTER the release step (dates, helm, index,
# the gh-pages push): refusing it would leave the mirror with the release but
# no index entry for it — the gap the index step exists to close. On any
# difference: refused (1), every difference named — a published release is
# never overwritten, and a differing one is a human decision. A release or tag
# that cannot be read, or an asset the mirror reports no digest for, is "cannot
# tell" (2).
release_existing_is_this() {
  local tag="$1" repo="$2" target="$3" prerelease="$4"; shift 4
  local json at flags draft pre assets
  json="$(gh api "repos/$repo/releases/tags/$tag" 2>&1)" || die2 "release: '$tag' exists on '$repo' but its release could not be read (gh exited $?: $(printf '%s' "$json" | tr '\n' ' '))"
  at="$(gh api "repos/$repo/commits/$tag" --jq .sha 2>&1)" || die2 "release: could not resolve tag '$tag' on '$repo' to a commit (gh exited $?: $(printf '%s' "$at" | tr '\n' ' '))"
  [[ "$at" =~ ^[0-9a-f]{40}$ ]] || die2 "release: tag '$tag' on '$repo' resolves to '$at', not a commit sha"
  flags="$(printf '%s' "$json" | jq -r '[(.draft | tostring), (.prerelease | tostring)] | @tsv' 2>&1)" || die2 "release: the release '$tag' of '$repo' did not parse: $(printf '%s' "$flags" | tr '\n' ' ')"
  IFS=$'\t' read -r draft pre <<<"$flags"
  assets="$(printf '%s' "$json" | jq -r '.assets[] | [.name, ((.digest // "") | ltrimstr("sha256:")), (.state // "")] | @tsv' 2>&1)" || die2 "release: could not read the assets of '$tag' on '$repo': $(printf '%s' "$assets" | tr '\n' ' ')"

  local want=false why=""
  [ "$prerelease" -eq 0 ] || want=true
  differs() { why="${why:+$why; }$1"; }
  [ "$at" = "$target" ] || differs "its tag is at $at, this run publishes $target"
  [ "$draft" = false ] || differs "it is a draft"
  [ "$pre" = "$want" ] || differs "it is prerelease=$pre, this run publishes prerelease=$want"
  # Fields by awk, not `read`: a tab is IFS whitespace, so `read` would fold
  # the empty digest of `name<TAB><TAB>uploaded` away and read the state as
  # the digest.
  local f name sum d st found
  for f in "$@"; do
    name="$(basename "$f")"
    sum="$(sha256_of "$f")" || die2 "release: could not hash '$f'"
    if ! awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }' <<<"$assets"; then differs "asset '$name' is not on the mirror's release"; continue; fi
    d="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$assets")"
    st="$(awk -F'\t' -v n="$name" '$1 == n { print $3; exit }' <<<"$assets")"
    if [ "$st" != uploaded ]; then differs "asset '$name' is on the mirror's release in state '$st', not uploaded"; continue; fi
    [ -n "$d" ] || die2 "release: asset '$name' of '$tag' on '$repo' has no digest — cannot tell whether it is this file"
    [ "$d" = "$sum" ] || differs "asset '$name' hashes to $d on the mirror, $sum here"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=0
    for f in "$@"; do [ "$(basename "$f")" != "$name" ] || { found=1; break; }; done
    [ "$found" -eq 1 ] || differs "asset '$name' is on the mirror's release but not in --assets"
  done < <(cut -f1 <<<"$assets")
  [ -z "$why" ] || die1 "release: '$tag' already exists on '$repo' and is not what this run would publish — a mirrored release is never overwritten; $why"   # mutation-anchor: release-existing-differs
}

cmd_release() {
  local tag="" repo="" target="" assets="" notes="" prerelease=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)        tag="${2:-}"; shift 2 ;;
      --repo)       repo="${2:-}"; shift 2 ;;
      --target)     target="${2:-}"; shift 2 ;;
      --assets)     assets="${2:-}"; shift 2 ;;
      --notes)      notes="${2:-}"; shift 2 ;;
      --prerelease) prerelease=1; shift ;;
      *) die2 "release: unknown argument '$1'" ;;
    esac
  done
  [ -n "$tag" ] && [ -n "$repo" ] && [ -n "$target" ] && [ -n "$assets" ] && [ -n "$notes" ] || die2 "release: --tag, --repo, --target, --assets and --notes are all required"
  [[ "$repo" =~ $REPO_RE ]] || die2 "release: --repo '$repo' is not OWNER/NAME"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die1 "release: '$tag' is not a release tag (vX.Y.Z or vX.Y.Z-<pre>)"
  [[ "$target" =~ ^[0-9a-f]{40}$ ]] || die2 "release: --target '$target' is not a full commit sha"
  [ -d "$assets" ] || die2 "release: assets '$assets' is not a directory"
  [ -s "$notes" ] || die2 "release: notes file '$notes' is missing or empty"
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$assets" -mindepth 1 -maxdepth 1 -type f | sort)
  [ "${#files[@]}" -gt 0 ] || die2 "release: '$assets' holds no files — a release with no assets is not what a customer downloads"
  command -v gh >/dev/null 2>&1 || die2 "release: gh is not on PATH"
  command -v jq >/dev/null 2>&1 || die2 "release: jq is not on PATH"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die2 "release: neither sha256sum nor shasum is on PATH"

  # Existing release → already done when it IS this one, refused otherwise (see
  # release_existing_is_this). `gh release view` exits 1 for "not found" AND
  # for auth or network failure, so the text decides which it was; anything
  # that is not a clear "not found" is "cannot tell".
  local err rc
  err="$(gh release view "$tag" --repo "$repo" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    release_existing_is_this "$tag" "$repo" "$target" "$prerelease" "${files[@]}"
    echo "already released $tag on $repo at $target with ${#files[@]} asset(s) — the mirror's release is identical to this one, nothing re-created (a re-run of a publish that failed after this step)"
    return 0
  fi
  printf '%s' "$err" | grep -qi 'release not found' || die2 "release: could not read releases of '$repo' (gh exited $rc: $(printf '%s' "$err" | tr '\n' ' '))"

  local -a args=(release create "$tag" --repo "$repo" --target "$target" --title "$tag" --notes-file "$notes")
  [ "$prerelease" -eq 1 ] && args+=(--prerelease)
  gh "${args[@]}" "${files[@]}" || die2 "release: gh release create exited $?"
  echo "released $tag on $repo at $target with ${#files[@]} asset(s)"
}

# ---- index: the Helm repository index, derived from the mirror's own releases ----
# One implementation for the workflow (every stable publish) and for
# scripts/backfill-releases.sh --pages (the one-shot carry-over): both hand the
# mirror name, the source's release list and an empty directory to this command
# and push DIR/stage when it says the index changed. Neither ever reads the
# source repository's gh-pages — an index copied from there points every URL
# at the source's Pages site, and `helm repo add` against the mirror breaks.

# index_set_created DATES IN OUT — copy the helm index IN to OUT with every
# entry's `created` replaced by the original publish date of the release its
# URL names (DATES: tag<TAB>date). Two passes over IN: the first maps each entry
# to its tag, the second rewrites. An entry with no tag or no date, or a count
# of rewritten lines that is not the entry count, is a failure (non-zero, reason
# on stderr) — never a partially dated index.
index_set_created() {
  awk -F'\t' 'NR == FNR { d[$1] = $2; next }
    FILENAME != ARGV[1] && FNR == 1 { pass++ }
    pass == 1 && /^  - /  { it++ }
    pass == 1 && /^    - https?:\/\// { u = $0; sub(/\/[^\/]*$/, "", u); sub(/.*\//, "", u); tag[it] = u }
    pass == 2 && /^  - /  { it2++ }
    pass == 2 && /^    created: / {
      t = tag[it2]; if (t == "" || !(t in d)) { print "no publish date for entry " it2 " (tag: " t ")" > "/dev/stderr"; bad = 1; exit 3 }
      print "    created: \"" d[t] "\""; fixed++; next }
    pass == 2 { print }
    END { if (!bad && fixed != it) { print "rewrote " fixed " created line(s) for " it " entries" > "/dev/stderr"; exit 3 } }
  ' "$1" "$2" "$2" >"$3"
}

cmd_index() {
  local repo="" src_releases="" out="" remote="" forbidden="" strict=0 helm="helm" allow_empty=0 output=""
  local -a extra=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)             repo="${2:-}"; shift 2 ;;
      --source-releases)  src_releases="${2:-}"; shift 2 ;;
      --out)              out="${2:-}"; shift 2 ;;
      --remote)           remote="${2:-}"; shift 2 ;;
      --forbidden)        forbidden="${2:-}"; shift 2 ;;
      --extra-forbidden)  extra+=("${2:-}"); shift 2 ;;
      --strict)           strict=1; shift ;;
      --helm)             helm="${2:-}"; shift 2 ;;
      --allow-empty)      allow_empty=1; shift ;;
      --output)           output="${2:-}"; shift 2 ;;
      *) die2 "index: unknown argument '$1'" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$src_releases" ] && [ -n "$out" ] || die2 "index: --repo, --source-releases and --out are all required"
  [[ "$repo" =~ $REPO_RE ]] || die2 "index: --repo '$repo' is not OWNER/NAME"
  [ -s "$src_releases" ] || die2 "index: --source-releases '$src_releases' is missing or empty — without the source's release dates no entry can be stamped"
  if [ -e "$out" ]; then
    [ -d "$out" ] || die2 "index: --out '$out' exists and is not a directory"
    [ -z "$(ls -A "$out")" ] || die2 "index: --out '$out' is not empty; a stale directory could carry a file the guard never read"
  fi
  [ -n "$forbidden" ] || forbidden="$SELF_DIR/../.publish-forbidden"
  [ -r "$forbidden" ] || die2 "index: forbidden list '$forbidden' is missing or unreadable — the guard has no rules"
  local e
  for e in "${extra[@]+"${extra[@]}"}"; do [ -s "$e" ] || die2 "index: extra forbidden list '$e' is missing or empty"; done
  local t
  for t in gh jq git awk; do command -v "$t" >/dev/null 2>&1 || die2 "index: '$t' is not on PATH"; done
  command -v "$helm" >/dev/null 2>&1 || die2 "index: '$helm' is not on PATH — the Helm index is rebuilt with it, and an index built any other way is not one helm would"   # mutation-anchor: index-helm-required
  local guard="$SELF_DIR/publish-guard.sh"
  [ -r "$guard" ] || die2 "index: $guard is missing"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die2 "index: neither sha256sum nor shasum is on PATH"
  [ -n "$remote" ] || remote="https://github.com/$repo.git"
  local base="https://github.com/$repo/releases/download"

  mkdir -p "$out/charts" "$out/stage" "$out/current" "$out/log" || die2 "index: cannot create '$out'"
  out="$(cd "$out" && pwd)"
  local L="$out/log"

  # -- the source's release list: tag → original publish date ----------------------
  # `gh api --paginate` prints one JSON array per page; `jq -s add` joins them
  # and a single array passes through unchanged.
  jq -s 'add // []' "$src_releases" >"$out/source-releases.json" 2>"$L/jq.err" || die2 "index: --source-releases '$src_releases' did not parse as a release list: $(tr '\n' ' ' <"$L/jq.err")"
  jq -r '.[] | select(.tag_name != null) | [.tag_name, (.published_at // .created_at)] | @tsv' "$out/source-releases.json" >"$out/dates.tsv" 2>"$L/jq.err" || die2 "index: could not read tag and publish date from '$src_releases': $(tr '\n' ' ' <"$L/jq.err")"
  [ -s "$out/dates.tsv" ] || die2 "index: --source-releases '$src_releases' lists no release — no publish date to stamp any chart with"
  date_of() { awk -F'\t' -v t="$1" '$1 == t && $2 != "" && $2 != "null" { print $2; exit }' "$out/dates.tsv"; }

  # -- the mirror's releases, read fresh: the index covers exactly what a
  #    `helm repo add` against the mirror can download -------------------------------
  gh api --paginate "repos/$repo/releases" >"$out/mirror-pages.json" 2>"$L/gh.err" || die2 "index: could not read the releases of '$repo' (gh api --paginate repos/$repo/releases failed: $(tr '\n' ' ' <"$L/gh.err"))"
  jq -s 'add // []' "$out/mirror-pages.json" >"$out/mirror-releases.json" 2>"$L/jq.err" || die2 "index: the release list of '$repo' did not parse: $(tr '\n' ' ' <"$L/jq.err")"
  jq -r '.[] | select(.draft == false) | select(.prerelease == false) | .tag_name' "$out/mirror-releases.json" >"$out/stable-tags.txt" 2>"$L/jq.err" || die2 "index: could not filter the release list of '$repo': $(tr '\n' ' ' <"$L/jq.err")"   # mutation-anchor: index-stable-only
  # Oldest first by the SOURCE's publish date of the same tag (the mirror's own
  # created_at is the instant it was mirrored, which for a backfilled release is
  # years off).
  : >"$out/order.tsv"
  local d
  while IFS= read -r t; do
    d="$(date_of "$t")"
    [ -n "$d" ] || die2 "index: mirror release '$t' has no publish date in '$src_releases' — a release the source never had cannot be placed in time"
    printf '%s\t%s\n' "$d" "$t" >>"$out/order.tsv"
  done <"$out/stable-tags.txt"
  sort "$out/order.tsv" | cut -f2 >"$out/tags-oldest-first.txt"
  local n_stable
  n_stable="$(grep -c . "$out/tags-oldest-first.txt" || true)"

  # -- place each chart version once, under the oldest release carrying it ---------
  # Layout charts/<tag>/<file>: `helm repo index` walks one level of
  # subdirectories and joins the directory name onto --url, so one --url yields
  # every chart's own release-asset URL.
  : >"$out/placed.tsv"    # name<TAB>version<TAB>tag<TAB>file
  local f cname cver got hname hver
  while IFS= read -r t; do
    jq -r --arg t "$t" '.[] | select(.tag_name == $t) | .assets[] | select(.name | endswith(".tgz")) | [.name, ((.digest // "") | ltrimstr("sha256:"))] | @tsv' "$out/mirror-releases.json" >"$out/tgz-$t.tsv" 2>"$L/jq.err" || die2 "index: could not list the assets of '$repo' release '$t': $(tr '\n' ' ' <"$L/jq.err")"
    while IFS=$'\t' read -r f d; do
      [[ "$f" =~ $CHART_FILE_RE ]] || die2 "index: mirror asset '$f' on '$t' is not a <chart>-<version>.tgz"
      cname="${BASH_REMATCH[1]}"; cver="${BASH_REMATCH[2]}"
      if awk -F'\t' -v n="$cname" -v v="$cver" '$1 == n && $2 == v { f = 1 } END { exit !f }' "$out/placed.tsv"; then continue; fi
      [ -n "$d" ] || die2 "index: mirror asset '$f' on '$t' has no digest — cannot verify the download"
      mkdir -p "$out/charts/$t" || die2 "index: cannot create '$out/charts/$t'"
      gh release download "$t" --repo "$repo" --dir "$out/charts/$t" --pattern "$f" >"$L/dl-$t.log" 2>&1 || die2 "index: could not download '$f' from '$repo' release '$t': $(tr '\n' ' ' <"$L/dl-$t.log")"
      [ -s "$out/charts/$t/$f" ] || die2 "index: '$f' did not download from '$repo' release '$t'"
      got="$(sha256_of "$out/charts/$t/$f")"
      [ "$got" = "$d" ] || die2 "index: '$f' from '$repo' release '$t' hashes to $got, the mirror says $d — the download is not the asset"   # mutation-anchor: index-download-digest
      # What the tarball says it is must be what its name says it is.
      "$helm" show chart "$out/charts/$t/$f" >"$L/chart-$t-$f.yaml" 2>"$L/helm.err" || die2 "index: helm show chart '$f' failed: $(tr '\n' ' ' <"$L/helm.err")"
      hname="$(awk '$1 == "name:" { print $2; exit }' "$L/chart-$t-$f.yaml")"; hver="$(awk '$1 == "version:" { print $2; exit }' "$L/chart-$t-$f.yaml")"
      [ "$hname" = "$cname" ] && [ "$hver" = "$cver" ] || die2 "index: '$f' contains chart '$hname' version '$hver', not what its name says"
      printf '%s\t%s\t%s\t%s\n' "$cname" "$cver" "$t" "$f" >>"$out/placed.tsv"
    done <"$out/tgz-$t.tsv"
  done <"$out/tags-oldest-first.txt"
  local n_charts
  n_charts="$(grep -c . "$out/placed.tsv" || true)"

  # -- the mirror's current gh-pages: everything on it stays, only index.yaml is
  #    replaced, and its index.yaml is what the rebuilt one is compared with. An
  #    unreachable remote is could-not-tell; an absent branch is a first publish.
  git -C "$out/current" init -q || die2 "index: git init failed"
  local heads pages_existed=0
  heads="$(git -C "$out/current" ls-remote --heads "$remote" refs/heads/gh-pages 2>"$L/lsr.err")" || die2 "index: the mirror remote did not answer (git ls-remote: $(tr '\n' ' ' <"$L/lsr.err"))"
  if [ -n "$heads" ]; then
    pages_existed=1
    git -C "$out/current" fetch -q --depth 1 "$remote" refs/heads/gh-pages 2>"$L/fetch.err" || die2 "index: could not fetch gh-pages from the mirror: $(tr '\n' ' ' <"$L/fetch.err")"
    git -C "$out/current" checkout -q FETCH_HEAD 2>/dev/null || die2 "index: could not check out the mirror's gh-pages"
    find "$out/current" -mindepth 1 -maxdepth 1 ! -name .git -exec cp -Rp {} "$out/stage"/ \; || die2 "index: could not copy the mirror's gh-pages"
  fi
  local present=absent; [ "$pages_existed" -eq 0 ] || present=present

  if [ "$n_charts" -eq 0 ]; then
    if [ "$allow_empty" -eq 1 ]; then
      emit_output "$output" "charts=0" "stable_releases=$n_stable" "changed=false" "pages_existed=$([ "$pages_existed" -eq 1 ] && echo true || echo false)" "download_base=$base" "stage=$out/stage" "index="
      echo "index: the mirror '$repo' carries no chart tarball on any stable release yet — nothing to index (--allow-empty); gh-pages $present, nothing staged"
      return 0
    fi
    die1 "index: the mirror '$repo' carries no chart tarball on any stable release — a Helm index with nothing in it is not published"
  fi

  "$helm" repo index "$out/charts" --url "$base" >"$L/helm-index.out" 2>&1 || { cat "$L/helm-index.out"; die2 "index: helm repo index failed"; }
  [ -s "$out/charts/index.yaml" ] || die2 "index: helm wrote no index.yaml"
  # `created` = the original publish date of the release each chart sits under,
  # read off the entry's own URL; every entry must get one.
  index_set_created "$out/dates.tsv" "$out/charts/index.yaml" "$out/index.yaml" 2>"$L/awk.err" || die2 "index: could not set created on the index: $(tr '\n' ' ' <"$L/awk.err")"   # mutation-anchor: index-created-from-source
  # Unchanged apart from `generated:`? Then the mirror's own file stays staged
  # verbatim, the publisher sees no difference, and nothing is pushed.
  local changed=1
  if [ "$pages_existed" -eq 1 ] && [ -e "$out/stage/index.yaml" ] && cmp -s <(grep -v '^generated:' "$out/stage/index.yaml") <(grep -v '^generated:' "$out/index.yaml"); then changed=0; fi   # mutation-anchor: index-unchanged-not-pushed
  [ "$changed" -eq 0 ] || cp "$out/index.yaml" "$out/stage/index.yaml" || die2 "index: could not stage the index"

  # -- the guard over the whole staged branch: the index as text, the tarballs
  #    already on the branch as opaque binaries. publish-guard.sh stages a tree
  #    from a git checkout by design; there is no tree here, so it gets a
  #    one-file scratch checkout and the staged branch as --assets, where guards
  #    2–4 (forbidden paths, forbidden strings, gitleaks) read it.
  local scratch="$out/scratch-src"
  mkdir -p "$scratch" && git -C "$scratch" init -q || die2 "index: could not init the guard's scratch checkout"
  printf 'index scratch tree\n' >"$scratch/README.md"
  # Unsigned: on a human's machine a global commit.gpgsign=true would try to
  # sign this never-published commit and end the run.
  git -C "$scratch" add README.md && git -C "$scratch" -c user.name=index -c user.email=index@localhost -c commit.gpgsign=false commit -q -m scratch || die2 "index: could not commit the guard's scratch checkout"
  printf 'README.md\n' >"$out/include.txt"
  local -a gargs=(--source "$scratch" --include "$out/include.txt" --forbidden "$forbidden" --out "$out/guard-out" --assets "$out/stage")
  for e in "${extra[@]+"${extra[@]}"}"; do gargs+=(--extra-forbidden "$e"); done
  [ "$strict" -eq 0 ] || gargs+=(--strict)
  local rc=0
  bash "$guard" "${gargs[@]}" >"$out/guard.log" 2>&1 || rc=$?   # mutation-anchor: index-guard
  case "$rc" in
    0) ;;
    1) grep -E 'REFUSED|^    ' "$out/guard.log" | sed 's/^/    /'
       die1 "index: the guard refused the index or the Pages branch: $(grep -E 'REFUSED' "$out/guard.log" | sed 's/^::error::publish-guard: //' | paste -sd';' -)" ;;
    *) cat "$out/guard.log"; die2 "index: the guard could not tell (exit $rc)" ;;
  esac

  local change_text=changed; [ "$changed" -eq 1 ] || change_text=unchanged
  emit_output "$output" "charts=$n_charts" "stable_releases=$n_stable" "changed=$([ "$changed" -eq 1 ] && echo true || echo false)" "pages_existed=$([ "$pages_existed" -eq 1 ] && echo true || echo false)" "download_base=$base" "stage=$out/stage" "index=$out/index.yaml"
  echo "index: $n_charts chart version(s) from $n_stable stable release(s) of $repo at $base/<tag>/; index.yaml $change_text against the mirror's gh-pages ($present); staged at $out/stage, not pushed by this command"
}

[ "$#" -ge 1 ] || die2 "a subcommand is required: target | tree | release | index"
sub="$1"; shift
case "$sub" in
  target)  cmd_target "$@" ;;
  tree)    cmd_tree "$@" ;;
  release) cmd_release "$@" ;;
  index)   cmd_index "$@" ;;
  -h|--help) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,2\}//' ;;
  *) die2 "unknown subcommand '$sub' (target | tree | release | index)" ;;
esac
