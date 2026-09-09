#!/usr/bin/env bats
# check-style.sh — the prose/terminology gate (backend#1924, backend#1729 sweep 6).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Sweep 6 measured that of the 24 shell scripts under scripts/ (excluding
# scripts/tests/ itself), exactly two were referenced by no bats suite.
# gen-manifest.sh was the other, and it got client#707. This is the residual.
#
# The stake is lower than gen-manifest's on purpose — an inert style guard costs
# drifting wording, not unverified code running privileged steps — but the reason
# to cover it is the same: an uncovered gate is a gate nobody can prove fires,
# and this one now sits inside the REQUIRED "Source-of-truth drift" check, so a
# rule that silently stopped matching would read as "clean" forever.
#
# SHAPE (from client#707): every rule is tested BOTH ways — it fires on a
# violation AND passes on the clean equivalent. One-sided tests are the trap
# here: a rule whose regex stopped matching anything passes every
# "clean input is clean" assertion while enforcing nothing.
#
# The brand-colour vocabulary is DERIVED from the script's own `brand=` regex
# rather than restated (backend#1729 rule 1/6). A hand-copied list of tones would
# agree with itself while a newly added tone went untested — the exact vocabulary
# gap mutation coverage cannot see.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # A copy, always: these tests plant violations and corrupt the tree, and must
  # never touch the working tree (same rule as gen-manifest.bats).
  WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/style.XXXXXX")"
  cp -R "$REPO/scripts" "$WORK/scripts"
  CS="$WORK/scripts/check-style.sh"
  # The planted-violation file. NOT under scripts/tests/ — the scanner excludes
  # that directory, so a fixture there would prove nothing (and every "it fires"
  # test would pass for the wrong reason).
  FIXTURE="$WORK/scripts/lib/zz-style-fixture.sh"
}

teardown() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  return 0
}

# The real script, run the way CI runs it.
run_style() { ( cd "$WORK" && bash scripts/check-style.sh ) }

# Plant lines in a scanned .sh file.
fixture() { printf '%s\n' "$@" > "$FIXTURE"; }

# ── the clean baseline ───────────────────────────────────────────────────────
# If this ever fails, every "fires on a violation" test below is meaningless:
# they would be measuring the working tree's own violations, not the plant.

@test "the working tree is clean (baseline — the rest of this suite depends on it)" {
  run run_style
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ok: style + terminology clean"* ]] || return 1
}

# ── rule 1: hardcoded brand colour ───────────────────────────────────────────

# Pull the tone vocabulary out of the script instead of restating it.
# BOTH extractors FAIL CLOSED on a missing marker, and both callers assert the
# token SHAPE (Bugbot + Asad on #762). `${re##*38;2;(}` is a no-op when the
# marker is absent, so deleting rule 1's entire RGB arm made _brand_rgbs fall
# through and return the HEX vocabulary instead. Those hexes were then planted as
# `printf '\033[38;2;#?(01a5cc m'` — which still contains a brand hex, so the
# surviving hex rule fired, the count floor was met, and the test asserting "the
# RGB half is caught" passed with the RGB half GONE. Reproduced before fixing.
#
# Non-emptiness was never the contract. The contract is "this is the RGB
# vocabulary", so the marker must be present and every token must look like a
# triple. A guard on the extractor alone would still let a stray hex through.
_brand_hexes() {
  local line re
  line="$(grep -m1 '^brand=' "$CS")"
  case "$line" in *'#?('*) ;; *) return 1 ;; esac
  re="${line#brand=\'}"; re="${re%\'}"
  re="${re#*\#?(}"
  printf '%s' "${re%%)*}" | tr '|' ' '
}
_brand_rgbs() {
  local line re
  line="$(grep -m1 '^brand=' "$CS")"
  case "$line" in *'38;2;('*) ;; *) return 1 ;; esac
  re="${line#brand=\'}"; re="${re%\'}"
  re="${re##*38;2;(}"
  printf '%s' "${re%%)*}" | tr '|' ' '
}

@test "rule 1: EVERY brand hex the script declares is caught (vocabulary derived, not restated)" {
  local hexes count=0
  hexes="$(_brand_hexes)" || return 1  # fail closed: no `#?(` marker is a finding
  [ -n "$hexes" ] || return 1
  for h in $hexes; do
    # Shape first: only a 6-digit hex may stand in for a hex token. Without this
    # a leaked RGB fragment would satisfy the loop just as well.
    [[ "$h" =~ ^[0-9a-fA-F]{6}$ ]] || return 1
    fixture "  local c=\"#${h}\""
    run run_style
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"hardcoded brand colour"* ]] || return 1
    count=$((count + 1))
  done
  [ "$count" -ge 6 ] || return 1       # the declared palette, not a subset
}

@test "rule 1: EVERY brand RGB triple the script declares is caught" {
  local rgbs count=0
  rgbs="$(_brand_rgbs)" || return 1    # fail closed: no `38;2;(` marker is a finding
  [ -n "$rgbs" ] || return 1
  for t in $rgbs; do
    # THE ASSERTION THAT MAKES THIS REAL: a token must actually be a triple.
    # Deleting the RGB arm used to leak the hex vocabulary in here, and a planted
    # `38;2;#?(01a5cc` still tripped the surviving HEX rule — so the test passed
    # while proving nothing about RGB.
    [[ "$t" =~ ^[0-9]{1,3}\;[0-9]{1,3}\;[0-9]{1,3}$ ]] || return 1
    fixture "  printf '\\033[38;2;${t}m'"
    run run_style
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"hardcoded brand colour"* ]] || return 1
    count=$((count + 1))
  done
  [ "$count" -ge 5 ] || return 1
}

@test "rule 1: caught case-insensitively (#01A5CC is the same violation as #01a5cc)" {
  fixture '  local c="#01A5CC"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"hardcoded brand colour"* ]] || return 1
}

@test "rule 1: a NON-brand colour is clean (the rule discriminates, it is not 'any hex')" {
  fixture '  local c="#123456"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 1: the colour engine itself is exempt (it is where the tones legitimately live)" {
  # Same violation text, placed in common.sh — the one file the report filters out.
  printf '\n  local c="#01a5cc"\n' >> "$WORK/scripts/lib/common.sh"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 2: banned term 'workspace' ──────────────────────────────────────────

@test "rule 2: 'workspace' in user-facing text is caught" {
  fixture '  echo "your workspace is ready"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"banned term 'workspace'"* ]] || return 1
}

@test "rule 2: the approved wording is clean" {
  fixture '  echo "your secure environment is ready"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 2: comments and the DNS-1123 sanitiser identifiers are exempt" {
  fixture \
    '# a comment mentioning workspace is fine' \
    '  _sanitize_workspace_name "$1"' \
    '  ConvertTo-WorkspaceName "$1"' \
    '  local workspace_name="x"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 3: bare curl (the TLS floor) ────────────────────────────────────────

@test "rule 3: a bare curl call is caught" {
  fixture '  curl -fsSL "$url" -o "$out"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"bare 'curl'"* ]] || return 1
}

@test "rule 3: curl_secure is NOT a bare curl (\\bcurl\\b must not match the wrapper)" {
  # The whole point of the rule is to push call sites onto the wrapper; flagging
  # the wrapper would make the rule unsatisfiable.
  fixture \
    '  curl_secure "$url" -o "$out"' \
    '  local curl_pid=$!' \
    '  nocurl=1'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 3: the documented exemptions are clean (TLS named, comment, presence test, install one-liner)" {
  fixture \
    '  curl --tlsv1.2 -fsSL "$url"' \
    '# curl in a comment is fine' \
    '  has curl || return 1' \
    '  command -v curl >/dev/null' \
    '  echo "  curl -fsSL https://tracebloc.io/i.sh | sh"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 4: capital-T 'Tracebloc' ────────────────────────────────────────────
# Note this is the FOURTH rule; the header comment called it "Three mechanical
# checks" until backend#1924, which is why it is worth a test of its own.

@test "rule 4: capital-T 'Tracebloc' in user-facing text is caught" {
  fixture '  echo "Welcome to Tracebloc"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"capital-T 'Tracebloc'"* ]] || return 1
}

@test "rule 4: lowercase product name is clean" {
  fixture '  echo "Welcome to tracebloc"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 4: PascalCase identifiers and comments are exempt" {
  # Two DIFFERENT exemptions live here and must be driven separately, or one of
  # them is untested: `Tracebloc[A-Z]` spares a name with a following capital,
  # `[-]Tracebloc` spares a cmdlet name with a leading dash. Found by mutation —
  # a fixture of only `Get-TraceblocClientEnv` satisfies BOTH, so deleting the
  # dash filter changed nothing and the test stayed green.
  fixture \
    '# Tracebloc in a comment is fine' \
    '  $key = "TraceblocInstallerResume"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 4: a cmdlet name with NO following capital is exempt via the leading dash alone" {
  # `Get-Tracebloc` — the one input that only `[-]Tracebloc` can spare.
  fixture '  Get-Tracebloc "$1"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 5: unbounded 'docker info' in scripts/lib/ (#741, #744) ──────────────
# BOTH ways, like the others: it fires on a real invocation and passes on the
# bounded equivalents. The trap this rule must survive is a *string mention* of
# 'docker info' vs an actual call — the regex matches an invocation (a
# flag/redirection/pipe or end-of-line after `info`), so the clean-side test
# below deliberately feeds the mentions that must NOT trip it. A one-sided "it
# fires" test would pass just as well against a rule that flagged those too, and
# such a rule would be unsatisfiable without littering the tree with markers.

@test "rule 5: an unbounded 'docker info' invocation is caught" {
  fixture '  if docker info >/dev/null 2>&1; then :; fi'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: a bare 'docker info' at end of line is caught (the next silent footgun)" {
  fixture '  docker info'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: routed through _bounded / _docker_answers is clean" {
  fixture \
    '  _bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker info >/dev/null 2>&1' \
    '  _bounded 10 sudo docker info &>/dev/null' \
    '  b="$(_bounded 10 docker info --format "{{.NCPU}}")"' \
    '  _docker_answers'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 5: string mentions and comments are NOT invocations (the discriminator)" {
  # Each line contains the literal 'docker info' but none is a call: a section
  # label, an audit-row string, an error hint (comma, not a space, follows), a
  # comment. The rule must leave all four alone.
  fixture \
    '  echo "## docker info"' \
    '  _audit_row "Container runtime" "Docker 27 — docker info OK" ok' \
    "  error \"daemon not answering — check 'sudo docker info', then re-run\"" \
    '  # a bare docker info against a wedged daemon hangs; that is why we bound it'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 5: 'timeout' in a trailing comment does NOT excuse an unbounded probe" {
  # The bound must PRECEDE the probe on the line. A probe whose only 'timeout' is
  # in a trailing comment is still unbounded and must be caught.
  fixture '  docker info >/dev/null 2>&1   # TODO: add a timeout later'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: a bare 'docker info' followed ONLY by a comment is caught (#744, Bugbot/LukasWodka)" {
  # No redirect/flag/pipe — just a trailing comment. Before the '#' follow-set the
  # regex matched none of its alternatives here, so this spelling slipped the gate.
  fixture '  docker info   # check the daemon'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

# ── rule 5, WIDENED past `docker info` (client#984) ──────────────────────────
# `docker info` was never the only subcommand that talks to the daemon, and the
# gap was measured, not imagined: the first cut of client#974 bounded a
# `k3d cluster list` inside the --diagnose bundle while a bare `docker ps -a` two
# lines ABOVE it kept the whole group hanging, and this rule could not see it —
# rule 5 matched only `info`, rule 6 only `k3d cluster list`. Each newly covered
# subcommand is driven separately: a single fixture naming all of them would pass
# with three of the four alternatives deleted.

@test "rule 5: an unbounded 'docker ps' is caught (the client#984 gap)" {
  fixture '  nodes=$(docker ps -a --filter "name=k3d-x-" --format "{{.Names}}" 2>/dev/null) || return 0'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: an unbounded 'docker inspect' with a QUOTED first arg is caught" {
  # Five of this tree's inspects are spelled `docker inspect "k3d-…-server-0"`, so
  # a flag-only follow-set walked straight past every one of them.
  fixture '  mounts=$(docker inspect "k3d-x-server-0" --format "{{range .Mounts}}{{println .Destination}}{{end}}" 2>/dev/null) || return 0'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: an unbounded 'docker inspect' with an EXPANDED first arg is caught" {
  fixture '  cluster_env=$(docker inspect "$server_container" --format "{{.Config.Image}}" 2>/dev/null) || return 0'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: an unbounded 'docker version' is caught (it reports the SERVER version)" {
  fixture '  ver="$(docker version --format "{{.Server.Version}}" 2>/dev/null)"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: a LINE-CONTINUED daemon read is caught" {
  fixture \
    '  binds=$(docker inspect "k3d-x-serverlb" \' \
    '    --format "{{range .NetworkSettings.Ports}}{{end}}" 2>/dev/null) || return 0'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
}

@test "rule 5: the widened set is satisfiable — every subcommand is clean via _bounded" {
  fixture \
    '  a=$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps -a --format "{{.Names}}" 2>/dev/null)' \
    '  b=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-x-server-0" --format "{{.Config.Image}}" 2>/dev/null)' \
    '  c=$(_bounded 10 docker version --format "{{.Server.Version}}" 2>/dev/null)' \
    '  _bounded_root 10 docker info >/dev/null 2>&1'
  run run_style
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "rule 5: MUTATING subcommands are deliberately NOT in the rule" {
  # run/exec/pull/update carry their own, very different budgets (a GPU verify runs
  # for 90s by design). Flagging them would make the rule unsatisfiable and would
  # push authors toward markers instead of bounds.
  fixture \
    '  docker run --rm hello-world >/dev/null 2>&1' \
    '  docker exec "$node" cat /tracebloc/marker' \
    '  docker pull "$image"' \
    '  docker update --restart unless-stopped "$node"'
  run run_style
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "rule 5: the diagnose bundle's own timeout NOTES are not invocations" {
  # The fix prints lines that name the calls it gave up on. Those must not trip the
  # rule, or the rule would forbid explaining itself.
  fixture \
    '  echo "## docker containers (k3d nodes)"' \
    '  echo "(the container listing did not complete within 10s)"' \
    '  echo "(the container inspect for $c did not complete)"' \
    '  echo "(the docker server-version read did not complete within 10s)"'
  run run_style
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── rule 6: rule 5's census, and the regression that earned it ───────────────

@test "rule 6: the census fires when rule 5 goes vacuous (a lib file the scan can no longer see)" {
  # Rename the file holding most of the daemon reads so `--include='*.sh'` misses
  # it. Rule 5 then has nothing to complain about and would report clean.
  mv "$WORK/scripts/lib/cluster.sh" "$WORK/scripts/lib/cluster.bash"
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"rule 5 went VACUOUS"* ]] || return 1
}

@test "rule 6: the floor is HONEST — the real tree meets it with no slack to spare" {
  # A floor below the truth is the same vacuity one step removed. Derive the count
  # the way rule 5 does and require the declared floor to match it exactly.
  local re floor found
  re="$(grep -m1 '^docker_probe=' "$CS")" || return 1
  re="${re#docker_probe=\'}"; re="${re%\'}"
  [ -n "$re" ] || return 1
  floor="$(grep -m1 '^DOCKER_READ_SITES_FLOOR=' "$CS" | cut -d= -f2)"
  [[ "$floor" =~ ^[0-9]+$ ]] || return 1
  found="$( ( cd "$WORK" && grep -rnE --include='*.sh' --include='*.ps1' \
                --exclude='check-style.sh' --exclude-dir='tests' "$re" scripts/lib/ ) \
            | grep -vE '# *style-guard: *allow' \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -c . || true)"
  [ "$found" -eq "$floor" ] || {
    echo "rule 5 finds $found daemon read(s) but DOCKER_READ_SITES_FLOOR is $floor"
    return 1
  }
}

@test "rules 5+7: the 'cmd;' invocation shape is in scope (the spelling that slipped)" {
  # `if _bounded_capture … docker version; then` — a semicolon with no space before
  # it. Both follow-sets missed this shape, so four --diagnose reads silently left
  # rule 5's scan mid-review while it kept reporting clean. Driven unbounded, so it
  # asserts the shape is MATCHED, not merely tolerated.
  fixture \
    '  if docker version; then :; fi' \
    '  if k3d cluster list; then :; fi'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded daemon read"* ]] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

@test "rules 5+7: _bounded_capture counts as a bound (the coreutils-free reader)" {
  fixture \
    '  if _bounded_capture "${TB_DOCKER_PROBE_TIMEOUT:-10}" "$_cap" docker version; then cat "$_cap"; fi' \
    '  if _bounded_capture "${TB_K3D_LIST_TIMEOUT:-15}" "$_cap" k3d cluster list; then cat "$_cap"; fi'
  run run_style
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── rule 7: unbounded 'k3d cluster list' in scripts/lib/ (client#974) ────────
# The bash twin of client#930, and rule 5's rule for the same daemon. Driven BOTH
# ways for the same reason rule 5 is: a regex that stopped matching invocations
# passes every clean-side assertion while enforcing nothing.
#
# The discriminator this rule carries and rule 5 does not is the LINE-CONTINUATION
# arm. assess.sh:90 — one of the seven sites #974 bounded — is a continued
# statement, and a rule that only knew rule 5's follow-set would have called the
# tree clean with a fresh unbounded call in it.

@test "rule 7: an unbounded 'k3d cluster list' invocation is caught" {
  fixture '  _list="$(k3d cluster list --no-headers)"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

@test "rule 7: '2>/dev/null || true' is NOT a bound (the whole finding of client#974)" {
  # This is the exact shape all seven pre-fix sites carried. `|| true` handles k3d
  # FAILING; a wedged Docker daemon does not fail the call, it blocks, so the
  # fallback is never reached. A rule that accepted this spelling would have
  # reported the pre-fix tree clean.
  fixture '  _json="$(k3d cluster list -o json 2>/dev/null || true)"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

@test "rule 7: a bare 'k3d cluster list' at end of line is caught (the diagnose-bundle shape)" {
  # diagnose.sh:126 pre-fix, inside the support bundle — the worst of the seven.
  fixture '  has k3d && k3d cluster list'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

@test "rule 7: a LINE-CONTINUED invocation is caught (the arm rule 5 does not have)" {
  # assess.sh:90's shape. With rule 5's follow-set alone the next char after
  # `list` is a backslash, which matches no alternative — so this call would have
  # been invisible to the rule that exists to find it.
  fixture \
    '  line="$(k3d cluster list --no-headers 2>/dev/null | awk "{print}")" \' \
    '    || line=""'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

@test "rule 7: routed through _bounded is clean (the rule is satisfiable)" {
  # gpu-nvidia.sh:102's shape — the in-tree precedent the seven were written
  # against — plus the continued and piped spellings the fix actually uses.
  fixture \
    '  out="$(_bounded "${TB_PROBE_TIMEOUT:-5}" k3d cluster list --no-headers 2>/dev/null)" || rc=$?' \
    '  s=$(_bounded 5 k3d cluster list -o json 2>/dev/null | jq -r ".[]" || echo "0")' \
    '  _bounded 5 k3d cluster list \' \
    '    || echo "(did not complete)"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 7: string mentions and comments are NOT invocations (the discriminator)" {
  # Each line contains the literal 'k3d cluster list' and none is a call: the
  # bundle's section heading, the timeout note the fix prints, a hint in prose, a
  # comment. All four must be left alone or the rule is unsatisfiable without
  # littering the tree with markers.
  fixture \
    '  echo "## k3d cluster list"' \
    '  echo "(k3d cluster list did not complete within 5s)"' \
    "  hint \"run 'k3d cluster list' by hand, then re-run\"" \
    '  # a bare k3d cluster list against a wedged daemon blocks; that is why we bound it'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 7: 'timeout' in a trailing comment does NOT excuse an unbounded call" {
  fixture '  k3d cluster list --no-headers   # TODO: add a timeout later'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"unbounded 'k3d cluster list'"* ]] || return 1
}

# ── rule 8: rule 7's census (backend#2849's house rule) ──────────────────────
# "A check that cannot distinguish 'clean' from 'didn't look'." Rule 6 is a text
# scan over scripts/lib/, so the moment it stops matching — a renamed file, an
# extension the --include misses, a nudged regex — it prints the same "ok: style +
# terminology clean" as a rule that checked every site. Rule 7 is the separate
# assertion that it FOUND something.

@test "rule 8: the census fires when rule 7 goes vacuous (a lib file the scan can no longer see)" {
  # Rename the file holding five of the eight known call sites so `--include='*.sh'`
  # misses it. Rule 6 then has nothing to complain about and would report clean;
  # rule 7 is what turns that into a red.
  mv "$WORK/scripts/lib/cluster.sh" "$WORK/scripts/lib/cluster.bash"
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"rule 7 went VACUOUS"* ]] || return 1
  [[ "$output" == *"floor is 8"* ]] || return 1
}

@test "rule 8: the floor is HONEST — the real tree meets it with no slack to spare" {
  # A floor set below the truth is the same vacuity one step removed: it would
  # survive four of the eight sites disappearing. Derive the count the way rule 6
  # does and assert the declared floor is not lower than what is actually there.
  local re floor found
  re="$(grep -m1 '^k3d_list_probe=' "$CS")" || return 1
  re="${re#k3d_list_probe=\'}"; re="${re%\'}"
  [ -n "$re" ] || return 1
  floor="$(grep -m1 '^K3D_LIST_SITES_FLOOR=' "$CS" | cut -d= -f2)"
  [[ "$floor" =~ ^[0-9]+$ ]] || return 1
  found="$( ( cd "$WORK" && grep -rnE --include='*.sh' --include='*.ps1' \
                --exclude='check-style.sh' --exclude-dir='tests' "$re" scripts/lib/ ) \
            | grep -vE '# *style-guard: *allow' \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -c . || true)"
  [ "$found" -eq "$floor" ] || {
    echo "rule 7 finds $found call site(s) but K3D_LIST_SITES_FLOOR is $floor — a floor below the truth lets sites vanish unnoticed; a floor above it is unsatisfiable"
    return 1
  }
}

# ── the opt-out marker ───────────────────────────────────────────────────────
# The header promises it works on ANY check. Tested per rule, because the marker
# is applied in one shared place (scan) and a regression would silently un-exempt
# every deliberate edge in the tree at once.

@test "the '# style-guard: allow' marker opts a line out of EVERY rule" {
  fixture \
    '  local c="#01a5cc"   # style-guard: allow' \
    '  echo "your workspace"   # style-guard: allow' \
    '  curl -fsSL "$url"   # style-guard: allow' \
    '  echo "Tracebloc"   # style-guard: allow' \
    '  docker info >/dev/null 2>&1   # style-guard: allow' \
    '  k3d cluster list --no-headers   # style-guard: allow'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "the marker is not required to be spaced exactly (#style-guard:allow also opts out)" {
  fixture '  echo "your workspace"   #style-guard:allow'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── scope: what the scanner does and does not read ───────────────────────────

@test "scope: violations in scripts/tests/ are not scanned (fixtures must not self-trip the gate)" {
  printf '  echo "your workspace"\n' > "$WORK/scripts/tests/zz-scope-fixture.sh"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "scope: .ps1 files ARE scanned (the gate is cross-platform, not bash-only)" {
  printf '  Write-Host "your workspace"\n' > "$WORK/scripts/zz-fixture.ps1"
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"banned term 'workspace'"* ]] || return 1
}

@test "scope: non-script files are not scanned" {
  printf 'your workspace\n' > "$WORK/scripts/zz-fixture.md"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── fail-closed ──────────────────────────────────────────────────────────────
# The script's own comment: "a mis-run guard (wrong dir, missing tree) must never
# look like a pass". Exit 2 is reserved for that, and is distinct from exit 1.

@test "fail-closed: no scripts/ tree -> exit 2, not a clean 0" {
  local lone="$WORK/lone"
  mkdir -p "$lone/scripts"
  cp "$CS" "$lone/scripts/check-style.sh"
  rm -rf "$lone/scripts"          # the script is gone with it; run the copy by path
  mkdir -p "$lone/bin"
  cp "$CS" "$lone/bin/check-style.sh"
  run bash "$lone/bin/check-style.sh"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"refusing to report clean"* ]] || return 1
}

@test "fail-closed: a grep internal error -> exit 2, not a clean 0" {
  # The `rc >= 2` branch in scan(). Driven by putting a grep that exits 2 on PATH,
  # so the REAL branch runs — rather than editing the script, which would test a
  # copy of the rule instead of the rule (backend#1729 rule 9).
  local stub="$WORK/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/grep"
  chmod +x "$stub/grep"
  run env PATH="$stub:$PATH" bash -c "cd '$WORK' && bash scripts/check-style.sh"
  [ "$status" -eq 2 ] || return 1
}

@test "exit codes are distinct: 1 means violations, 2 means the guard could not tell" {
  fixture '  echo "your workspace"'
  run run_style
  [ "$status" -eq 1 ] || return 1        # a real violation is 1, never 2
  [[ "$output" != *"failing closed"* ]] || return 1
}

# ── the header's own claim ───────────────────────────────────────────────────

@test "the header's rule count matches the rules actually implemented" {
  # backend#1924 found this stale: the header said "Three mechanical checks"
  # while four `report` calls were live. A gate whose own description undercounts
  # it is how a rule gets dropped without anyone noticing.
  local implemented declared
  implemented="$(grep -c '^report ' "$CS")"
  declared="$(grep -oE '^#  (Three|Four|Five|Six|Seven|Eight) mechanical checks' "$CS" | awk '{print $2}')"
  case "$declared" in
    Three) declared=3 ;; Four) declared=4 ;; Five) declared=5 ;; Six) declared=6 ;;
    Seven) declared=7 ;; Eight) declared=8 ;;
    *) return 1 ;;                       # unparsed header is a finding, not a pass
  esac
  [ "$implemented" -eq "$declared" ] || return 1
}
