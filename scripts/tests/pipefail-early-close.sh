#!/usr/bin/env bash
# =============================================================================
#  pipefail-early-close.sh — the entry point for the early-close gate
#  (backend#1778). Resolves WHICH files run under errexit+pipefail, then hands
#  them to pipefail-early-close.awk, which decides which LINES are offenders.
#
#  WHY A WRAPPER AND NOT JUST THE AWK (Bugbot on #763, two findings)
#  ----------------------------------------------------------------
#  1. INHERITED OPTIONS. `scripts/lib/*.sh` never set errexit/pipefail
#     themselves — they are sourced by scripts/install.sh, which does. An awk
#     that only asks "does this file contain both `set` lines" therefore reads
#     the entire lib tree as safe, and a reverted `helm repo list | grep -q`
#     or `lspci | grep -qi` stays green while the `if` misbranches under
#     pipefail (repo "absent", GPU host treated as CPU). That is most of the
#     installer, and the exact code this ticket is about.
#
#  2. THE FILE LIST. `find scripts docs -name '*.sh'` is a restatement of a
#     definition the repo already owns. scripts/sh-files.sh is THE classifier
#     (extension, else shebang), read by the gating shellcheck sweep. Using it
#     picks up docker/k3s-cuda/build.sh — which sets `set -euo pipefail` and
#     converted a `grep | head` for this very ticket — plus `.bash` files.
#     Deriving beats listing, and #753 is this repo's cautionary tale about a
#     hand-kept file list drifting past eight real scripts.
#
#  Inheritance is computed to a FIXPOINT and matched on BASENAME, because the
#  source lines are `source "${LIB_DIR}/common.sh"` — the directory is a
#  variable, so only the basename is statically known. Basename matching is the
#  fail-closed direction: it can mark a same-named file that is never actually
#  sourced (a false hazard, costing at most a spurious finding someone can
#  silence with the marker), never the reverse.
#
#  Usage:  pipefail-early-close.sh [file...]     (default: the whole repo)
#  Output: one `path:line: code` per offender. Exit 0 always; the caller judges.
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
AWK_PROG="$HERE/pipefail-early-close.awk"

cd "$ROOT" || exit 1

files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # Fail closed: sh-files.sh exits 1 when it classifies nothing, and an empty
  # sweep must never read as a clean one (backend#1729 rule 3).
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(bash "$ROOT/scripts/sh-files.sh")
  if [ "${#files[@]}" -eq 0 ]; then
    echo "pipefail-early-close: sh-files.sh classified no shell files — refusing to report clean" >&2
    exit 2
  fi
fi

# --- seed: files that enable BOTH options themselves ------------------------
haz=""
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)|-o[[:space:]]+errexit)' "$f" 2>/dev/null || continue
  grep -qE '^[[:space:]]*set[[:space:]].*pipefail' "$f" 2>/dev/null || continue
  haz="$haz $f"
done

# --- close over `source` / `.` to a fixpoint --------------------------------
# A file sourced BY a hazardous file runs under the caller's options.
while :; do
  added=0
  for f in $haz; do
    [ -f "$f" ] || continue
    # Basenames of every sourced path in this hazardous file.
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      for cand in "${files[@]}"; do
        [ "$(basename "$cand")" = "$base" ] || continue
        case " $haz " in *" $cand "*) continue ;; esac
        haz="$haz $cand"; added=1
      done
    done <<EOF
$(grep -hoE '(^|[[:space:]])(source|\.)[[:space:]]+"?[^"[:space:];|&]+\.(sh|bash)' "$f" 2>/dev/null \
    | sed -E 's|.*/||; s|^.*[[:space:]]||' | sort -u)
EOF
  done
  [ "$added" -eq 0 ] && break
done

exec awk -v hazardous="$haz " -f "$AWK_PROG" "${files[@]}"
