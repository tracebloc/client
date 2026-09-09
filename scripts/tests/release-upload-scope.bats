#!/usr/bin/env bats
# release-upload-scope.bats — the release-upload step of release-helm-chart.yaml
# attaches ONLY the freshly packaged charts, never the historical tarballs.
#
# THE DEFECT THIS PINS. The `release` job packages the two charts, uploads them
# as a workflow artifact, checks out gh-pages (which holds EVERY historical
# .tgz), downloads the artifact into an isolated dir, and only then runs
# softprops/action-gh-release. Its `files:` globs used to be root-level
# (`client-*.tgz`), so in the gh-pages working dir they matched all 63
# historical tarballs and attached them to every release (v1.9.107: 69 assets,
# 63 chart tgzs, zero downloads). The step's own comment said "BOTH" charts —
# two files were intended. The fix scopes the globs to the isolated dir and
# COPIES (not moves) the charts out of it, so they still exist at upload time.
#
# DERIVED, NOT RESTATED (workspace rule 1). This file holds no copy of the
# directory name. It is read off the workflow's own actions/download-artifact
# `path:` — the one declaration that creates the dir — and every other mention
# (the `files:` globs, the cp source) is compared against THAT. The
# `download path moved` mutation below is what proves the derivation: a guard
# with the name hardcoded would stay green on it.
#
# FAILS CLOSED (rule 3): an unreadable workflow, a missing `release` job, no
# upload step, no `files:` entry, or an expression the parser cannot resolve is
# a named refusal, never "nothing to check".
#
# ONE IMPLEMENTATION (rule 9): `guard` below is the whole check. The real
# workflow and every mutated copy go through the same function, so a mutation
# that reddens here reddens the thing that gates CI, not a re-implementation.

WF=""

setup() {
  WF="${BATS_TEST_DIRNAME}/../../.github/workflows/release-helm-chart.yaml"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# guard <workflow.yaml> [dir]
#   default: run every check, exit 0 with OK lines / exit 1 with one FAIL line.
#   `dir`:   print only the derived new-charts directory (used by the
#            mutations to build their fixtures off the workflow, not off a
#            literal in this file).
guard() {
  run python3 - "$@" <<'PY'
import posixpath, sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "check"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except (OSError, yaml.YAMLError) as e:
    fail("cannot read or parse workflow %s: %s" % (path, e))
if not isinstance(doc, dict):
    fail("workflow %s is not a mapping" % path)
release = (doc.get("jobs") or {}).get("release")
if not isinstance(release, dict):
    fail("no `release` job in %s" % path)
steps = [s for s in (release.get("steps") or []) if isinstance(s, dict)]


def uses(step, prefix):
    return str(step.get("uses", "")).startswith(prefix)


downloads = [i for i, s in enumerate(steps) if uses(s, "actions/download-artifact")]
uploads = [i for i, s in enumerate(steps) if uses(s, "softprops/action-gh-release")]
if len(downloads) != 1:
    fail("expected exactly one actions/download-artifact step in `release`, found %d" % len(downloads))
if len(uploads) != 1:
    fail("expected exactly one softprops/action-gh-release step in `release`, found %d" % len(uploads))
dl_i, up_i = downloads[0], uploads[0]
dl, up = steps[dl_i], steps[up_i]

# The one declaration of the isolated dir: where the artifact is downloaded to.
new_dir = str((dl.get("with") or {}).get("path", "") or "").strip().rstrip("/")
if not new_dir or new_dir == "." or new_dir.startswith("/") or "${{" in new_dir:
    fail("download-artifact `path:` is not a plain relative directory: %r" % new_dir)
if mode == "dir":
    print(new_dir)
    sys.exit(0)

if dl_i > up_i:
    fail("the download-artifact step must run BEFORE the release-upload step")
# Pre-releases skip every gh-pages step but must still ship their charts as
# release assets, so the dir has to exist and the upload has to run on both
# paths: neither step may carry an `if:`.
for label, step in (("download-artifact", dl), ("release-upload", up)):
    if "if" in step:
        fail("the %s step carries an `if:` — it must run on stable AND pre-release paths" % label)

# --- the upload globs -------------------------------------------------------
with_ = up.get("with") or {}
files_raw = with_.get("files")
if not isinstance(files_raw, str) or not files_raw.strip():
    fail("release-upload step has no `files:` entries — nothing would be attached")
workdir = str(with_.get("working_directory", "") or "").strip()
if "${{" in workdir:
    fail("release-upload `working_directory` is an expression the guard cannot resolve: %r" % workdir)
entries = [l.strip() for l in files_raw.splitlines() if l.strip()]
for e in entries:
    if "${{" in e:
        fail("release-upload glob %r is an expression the guard cannot resolve" % e)
    eff = posixpath.normpath(posixpath.join(workdir, e)) if workdir else posixpath.normpath(e)
    if not eff.startswith(new_dir + "/") or "/" in eff[len(new_dir) + 1:]:
        fail("release-upload glob %r resolves to %r, not directly under %s/ — in the gh-pages "
             "checkout a root glob matches every historical tarball" % (e, eff, new_dir))
if str(with_.get("fail_on_unmatched_files", "")).lower() != "true":
    fail("release-upload step must set fail_on_unmatched_files: true — an empty glob must be a "
         "red run, not a release page with no charts on it")

# Every chart the job packages must be attached: one glob per `helm package`.
def script_lines(step):
    out = []
    for raw in str(step.get("run", "") or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


packaged = sum(1 for s in steps for l in script_lines(s) if l.startswith("helm package "))
if packaged == 0:
    fail("no `helm package` line found in the `release` job — cannot tell how many charts to expect")
if len(entries) != packaged:
    fail("release-upload has %d glob(s) but the job packages %d chart(s) — every packaged chart "
         "must be attached" % (len(entries), packaged))

# --- the charts must still be in the dir at upload time ---------------------
# Spellings of the dir a run: script may use: the literal, and any env var
# (job- or step-level) whose value IS the dir.
def env_aliases(step):
    names = set()
    for scope in (doc.get("env") or {}, release.get("env") or {}, step.get("env") or {}):
        for k, v in (scope or {}).items():
            if str(v).strip().rstrip("/") == new_dir:
                names.add(k)
    spellings = {new_dir}
    for n in names:
        for form in ("$%s", "${%s}", '"$%s"', '"${%s}"'):
            spellings.add(form % n)
    return spellings


def joined_lines(step):
    # Shell joins a trailing-backslash line with the next one.
    out, buf = [], ""
    for line in script_lines(step):
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append(buf + line)
        buf = ""
    if buf:
        out.append(buf)
    return out


copies, destroyers = 0, []
for s in steps[:up_i]:
    aliases = env_aliases(s)
    for line in joined_lines(s):
        tokens = line.split()
        refs = any(t.startswith(a) for t in tokens for a in aliases)
        if not refs:
            continue
        cmd = tokens[0]
        if cmd in ("mv", "rm", "rmdir"):
            destroyers.append(line)
        elif cmd == "cp":
            copies += 1
if destroyers:
    fail("the new charts are moved or deleted before the release-upload step, so the scoped globs "
         "would match nothing: %s" % "; ".join(destroyers))
if copies == 0:
    fail("no `cp` from %r found before the release-upload step — the charts must be COPIED to the "
         "gh-pages root (index URLs are root-relative) and left in place for the upload" % new_dir)

print("OK: release-upload globs are scoped to %s/ (%d entries, one per packaged chart)" % (new_dir, len(entries)))
print("OK: %s is copied, not moved, before the upload" % new_dir)
PY
}

# Write a mutated copy of the real workflow to $1 by piping it through the
# given sed program, and PROVE the mutation applied: an inert mutation and
# good coverage look identical in a log (rule 5).
mutate() {
  local out="$1"; shift
  sed "$@" "$WF" >"$out" || return 1
  ! cmp -s "$WF" "$out" || return 1
}

# ── the real workflow ────────────────────────────────────────────────────────

@test "the shipped workflow scopes the release-upload globs to the download dir and copies, not moves" {
  guard "$WF"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"OK: release-upload globs are scoped to"* ]] || return 1
  [[ "$output" == *"is copied, not moved, before the upload"* ]] || return 1
}

@test "the dir is derived from the workflow, not written down here" {
  guard "$WF" dir
  [ "$status" -eq 0 ] || return 1
  [ -n "$output" ] || return 1
  # The derived name is what the download-artifact step declares — and it is
  # the value the OK line reports, so the two readings agree.
  grep -qF "path: $output" "$WF" || return 1
  dir="$output"
  guard "$WF"
  [[ "$output" == *"scoped to $dir/"* ]] || return 1
}

# ── the mutation that motivated this file: root globs in the gh-pages checkout ─

@test "root-level globs (the 63-tarball shape) are REJECTED" {
  guard "$WF" dir; dir="$output"
  # Strip the `<dir>/` prefix from every line that starts with it — exactly the
  # old `files:` shape. The download `path:` has no trailing slash, so it is
  # untouched and the dir still exists; only the globs go back to the root.
  mutate mut.yaml "s#^\( *\)$dir/#\1#"
  grep -qE '^ *client-\*\.tgz$' mut.yaml || return 1        # mutation applied
  ! grep -qE "^ *$dir/" mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"not directly under"* ]] || return 1
  [[ "$output" == *"matches every historical tarball"* ]] || return 1
}

@test "only ONE glob left at the root still REDS (a partial fix is no fix)" {
  guard "$WF" dir; dir="$output"
  mutate mut.yaml "s#^\( *\)$dir/ingestor-#\1ingestor-#"
  grep -qE '^ *ingestor-\*\.tgz$' mut.yaml || return 1
  grep -qE "^ *$dir/client-" mut.yaml || return 1            # the other one is intact
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"'ingestor-*.tgz'"* ]] || return 1
}

# ── the derivation is real: move the download dir and the guard follows it ───

@test "moving the download path elsewhere REDS the now-stale globs (proves the dir is derived)" {
  guard "$WF" dir; dir="$output"
  mutate mut.yaml "s#^\( *path: \)$dir\$#\1elsewhere_dir#"
  grep -qE '^ *path: elsewhere_dir$' mut.yaml || return 1
  guard mut.yaml dir
  [ "$output" = "elsewhere_dir" ] || return 1                # the guard now reads the NEW dir
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"not directly under elsewhere_dir/"* ]] || return 1
}

# ── the charts must survive until the upload ─────────────────────────────────

@test "mv instead of cp out of the download dir is REJECTED" {
  mutate mut.yaml -E 's#^( *)cp ("?\$\{?[A-Za-z_]+\}?"?/\*\.tgz)#\1mv \2#'
  grep -qE '^ *mv "?\$' mut.yaml || return 1                 # mutation applied
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"moved or deleted before the release-upload step"* ]] || return 1
}

@test "an rm -rf of the download dir before the upload is REJECTED" {
  guard "$WF" dir; dir="$output"
  # Append a cleanup line right after the cp — a plausible "tidy up" edit.
  mutate mut.yaml -E "s#^( *)(cp \"?\\\$\{?[A-Za-z_]+\}?\"?/\*\.tgz .*)#\1\2\n\1rm -rf $dir#"
  grep -qE "^ *rm -rf $dir$" mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"moved or deleted before the release-upload step"* ]] || return 1
  [[ "$output" == *"rm -rf $dir"* ]] || return 1
}

@test "no cp at all (charts never reach the gh-pages root) is REJECTED" {
  mutate mut.yaml -E '/^ *cp "?\$\{?[A-Za-z_]+\}?"?\/\*\.tgz/d'
  ! grep -qE '^ *cp "?\$' mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no \`cp\` from"* ]] || return 1
}

# ── both paths: pre-releases ship charts as release assets only ──────────────

@test "gating the download step on stability is REJECTED (pre-releases would upload nothing)" {
  mutate mut.yaml -E "s#^( *)(uses: actions/download-artifact.*)#\1\2\n\1if: \\\${{ needs.verify.outputs.prerelease != 'true' }}#"
  grep -A1 'uses: actions/download-artifact' mut.yaml | grep -q '^ *if:' || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"download-artifact step carries an \`if:\`"* ]] || return 1
}

@test "gating the upload step on stability is REJECTED" {
  mutate mut.yaml -E "s#^( *)(uses: softprops/action-gh-release.*)#\1\2\n\1if: \\\${{ needs.verify.outputs.prerelease != 'true' }}#"
  grep -A1 'uses: softprops/action-gh-release' mut.yaml | grep -q '^ *if:' || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"release-upload step carries an \`if:\`"* ]] || return 1
}

# ── an empty match must be a red run, not a chart-less release ───────────────

@test "fail_on_unmatched_files switched off is REJECTED" {
  mutate mut.yaml 's#^\( *fail_on_unmatched_files: \)true$#\1false#'
  grep -q 'fail_on_unmatched_files: false' mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"fail_on_unmatched_files: true"* ]] || return 1
}

@test "fail_on_unmatched_files removed is REJECTED" {
  mutate mut.yaml '/^ *fail_on_unmatched_files: true$/d'
  ! grep -qE '^ *fail_on_unmatched_files:' mut.yaml || return 1   # the comment may still name it
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"fail_on_unmatched_files: true"* ]] || return 1
}

# ── every packaged chart is attached ─────────────────────────────────────────

@test "a third packaged chart with no matching glob is REJECTED" {
  mutate mut.yaml -E 's#^( *)(helm package \./ingestor)$#\1\2\n\1helm package ./extra#'
  grep -q 'helm package ./extra' mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"has 2 glob(s) but the job packages 3 chart(s)"* ]] || return 1
}

# ── fail closed: a guard that cannot check must not claim the globs are scoped ─

@test "a missing workflow fails closed" {
  guard "$BATS_TEST_TMPDIR/absent.yaml"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"cannot read or parse workflow"* ]] || return 1
}

@test "a workflow with no release job fails closed" {
  printf 'name: x\njobs: {}\n' >mut.yaml
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no \`release\` job"* ]] || return 1
}

@test "a release job with no upload step fails closed" {
  mutate mut.yaml '/uses: softprops\/action-gh-release/d'
  ! grep -q 'softprops/action-gh-release' mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"expected exactly one softprops/action-gh-release step"* ]] || return 1
}

@test "an upload step with no files: entries fails closed" {
  guard "$WF" dir; dir="$output"
  mutate mut.yaml "/^ *$dir\/.*\.tgz$/d"
  ! grep -qE "^ *$dir/" mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"no \`files:\` entries"* ]] || return 1
}

@test "a files: glob written as an expression the guard cannot resolve fails closed" {
  guard "$WF" dir; dir="$output"
  mutate mut.yaml "s#^\( *\)$dir/client-#\1\${{ env.SOMEWHERE }}/client-#"
  grep -qF '${{ env.SOMEWHERE }}/client-' mut.yaml || return 1
  guard mut.yaml
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"expression the guard cannot resolve"* ]] || return 1
}
