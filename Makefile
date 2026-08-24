# Makefile for tracebloc/client — uniform entry points (backend#1606).
#
# Every active tracebloc repo exposes the SAME three targets, so "run
# your tests before you push" stops being a rule you can only obey with
# per-repo tribal knowledge:
#
#   make check      lint + fast tests.   Budget: under 60 s.
#   make check-all  everything CI runs (bar the CI-only heavy suites).
#   make setup      install what those targets need, and a git pre-push hook
#                   that runs `make check` (skip once with --no-verify).
#
# This file is a THIN WRAPPER. Almost every command below is copied from the
# workflow that already runs it — standard-checks.yml, installer-tests.yaml,
# drift-checks.yaml and helm-ci.yaml. It introduces no new tool, no new config,
# and no new rule. When a workflow changes, change the matching line here.
#
# `shellcheck` and `drift` are the two targets not copied from a workflow LINE,
# but both are still exactly what a workflow runs: since #753, `Standard checks
# / Lint` runs `make lint`, and since #755 the REQUIRED `Source-of-truth drift`
# runs `make drift`. For those two this file IS the definition rather than a copy
# of one — which is the point: the pre-push tier and the merge gate cannot
# disagree about what linting, or drift, means. The org
# reusable job `quality / shellcheck` (tracebloc/.github) applies the same rule
# to the PR diff; that one cannot be copied from, so this target reproduces its
# classification and flags, and says so in its own comment.

.DEFAULT_GOAL := help

# The shellcheck file set is DERIVED from the tree, never written down.
#
# It used to be a 19-entry SHELLCHECK_FILES list copied out of
# installer-tests.yaml. Measured on develop at 8de5d64: that list expanded to 34
# files where the same classification applied to the tree found 42 (the live
# number is higher now and is printed by the target -- see `check` above on why
# it is not restated here). It had drifted past eight real scripts --
#
#   docker/k3s-cuda/build.sh          docker/k3s-cuda/k3d-entrypoint-tracebloc-cdi.sh
#   docs/migration-tools/generate.sh  docs/migration-tools/migrate-tenant.sh
#   scripts/chart-version-guard.sh    scripts/check-digest-drift.sh
#   scripts/index-invariants.sh       scripts/tests/test_helper.bash
#
# -- and a parse error planted in index-invariants.sh was invisible to the list
# and caught by the derivation. This is the SECOND drift of this list;
# backend#1606 found the first and fixed it by re-copying, which reset the
# clock rather than stopping it. Enumerating a file set is the defect.
#
# The rule below is the one `quality / shellcheck` applies (the required check,
# in tracebloc/.github's code-quality.yml): classify by extension, else by
# shebang; skip .bats/.ps1/.psm1/.zsh; error severity; SC1091 excluded because
# a library sourced through a variable path can never be followed. Same rule,
# same flags.
#
# SCOPE, precisely, because #753's first draft got this wrong (Arturo review):
#   * this target, run by `Standard checks / Lint` and by `make check` -- the
#     WHOLE TREE, on every PR and every push.
#   * `quality / shellcheck` -- the PR DIFF only. Its caller passes
#     `all-files: false` and declares no `schedule:`, so on a PR touching no
#     shell file it legitimately reports "Shell files to check: 0" and exits 0.
# Both are required checks and both derive. Dropping the whole-tree half would
# leave no CI job sweeping the full tree at error severity, which is what the
# old enumerated jobs did on every run.
#
# Versions differ, and that is not drift: the runner ships 0.9.0 (measured in
# run 32232682350), a dev box is typically newer -- 0.11.0 via brew today. The
# 44-file set was verified green under BOTH before this was armed.
#
# Honest limit, because a comment claiming "cannot drift" would be the thing
# this change is deleting: this MIRRORS the org job's rule across a repo
# boundary, it does not read it. If that classification changes, this needs the
# same edit. What is gone is the enumeration -- the part that actually drifted.
#
# Note `--shell=bash` is deliberately NOT passed (the old inline copies did).
# The gate infers the dialect from each file's shebang; forcing bash would make
# a local run disagree with it on the repo's `#!/bin/sh` scripts.

# The bats total, DERIVED — never written down. It moves on most PRs that add a
# test, nothing enforces it, and the help text had drifted from its hardcoded
# 868 to a real 946 with nobody noticing. A number that is wrong is worse than
# no number, and re-hardcoding today's value only resets the drift clock.
#
# `=`, not `:=`: recursively expanded, so the grep runs only when `help` actually
# prints it. `make check` is the pre-push path with a sub-60 s budget and never
# pays for it. bats declares one test per `@test` at line start, so this matches
# `bats`'s own count exactly — re-verify by comparing it against the highest test
# number a full `make bats` prints, never against a number recorded here. The
# "verified: 946 = 946" that used to close this sentence had itself drifted past
# 1180 by the time anyone re-counted: the paragraph above, happening to the
# paragraph above.
BATS_TEST_COUNT = $(shell grep -h '^@test' scripts/tests/*.bats 2>/dev/null | wc -l | tr -d ' ')

.PHONY: help
help:
	@echo "tracebloc/client — make targets"
	@echo
	@echo "  check       lint + fast checks (~10 s) — run this before every push"
	@echo "  check-all   everything CI runs locally, including the $(BATS_TEST_COUNT)-test bats suite"
	@echo "  setup       check for / point at the tools these targets need; installs the pre-push hook"
	@echo "  install-hooks  (re)install the git pre-push hook that runs 'make check'"
	@echo
	@echo "  individual: lint (= parse + shellcheck) bats helm-lint helm-vocab"
	@echo "              helm-template helm-unittest drift"
	@echo
	@echo "  NOT here (CI-only, by name): the 9-distro prereq matrix, e2e-cluster"
	@echo "  (k3d), e2e-proxy (squid), path-persist, Pester, windows-e2e,"
	@echo "  e2e-journey, upgrade-e2e / seal-check-e2e / full-seal-e2e."

# ---- check: the pre-push tier ------------------------------------
#
# Re-measured 2026-08-19 (macOS, shellcheck 0.11.0), ~10 s total: parse 0.1 s,
# shellcheck 5.2 s, drift 0.4 s, helm-lint 0.7 s, helm-vocab 3.1 s. The old
# note here said 4 s and listed only four of the five targets -- it predated
# helm-vocab and never counted it. shellcheck got slower (3.2 -> 5.2 s) because
# #753 replaced the enumerated 34-file list with everything the derivation
# finds; that is the scripts nothing was checking, not a slowdown.
# Still six times inside the 60 s budget.
#
# No file count is written down here on purpose. It moves -- it was 42 when #753
# was measured and 44 once #747 landed -- and a stale number in a comment is the
# defect this PR exists to remove. Both targets print their live count when they
# run, the same reasoning as BATS_TEST_COUNT above.
#
# The bats suite is deliberately NOT here. It is the repo's real unit
# suite and it takes ~2 min serially on macOS — three times over the
# budget — and it does not parallelise without GNU parallel, which is
# not a thing every dev machine has. Splitting it into a fast tier is
# real work, not a Makefile line, so it lives in `check-all` until
# someone does it. A `check` that quietly took two minutes would be a
# `check` nobody runs.
.PHONY: check
check: lint drift helm-lint helm-vocab
	@echo "==> check: green (bats + helm unit tests are in 'make check-all')"

.PHONY: check-all
check-all: lint drift helm-lint helm-vocab bats helm-template helm-unittest
	@echo "==> check-all: green"

# setup: no dependency is installed — this only tells you what is missing —
# but it does install a git pre-push hook that runs `make check` (backend#1606
# step 4), via the install-hooks target below.
.PHONY: setup
setup:
	@missing=""; \
	for t in bash shellcheck bats helm python3; do \
	  command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "missing:$$missing"; \
	  echo "  macOS: brew install shellcheck bats-core helm python"; \
	  echo "  Debian/Ubuntu: apt-get install shellcheck bats python3  (helm: https://helm.sh/docs/intro/install/)"; \
	  exit 1; \
	fi; \
	echo "==> setup: shellcheck, bats, helm and python3 are all present; run 'make check'"
	@$(MAKE) --no-print-directory install-hooks

# install-hooks: put a pre-push hook in place that runs `make check`, so the
# canon's "run the tests before you push" is carried by the tooling rather than
# by memory. Factored out of `setup` so it is independently runnable and
# testable, and so a contributor who only wants the hook need not rerun the
# full `make setup`.
#
# Honest by design: the hook catches FORGETTING, not defiance — `git push
# --no-verify` skips it and always will. And it refuses to clobber a pre-push
# hook that is already there and not ours (e.g. one the pre-commit framework
# manages), rather than silently stomping a contributor's setup.
#
# `git rev-parse --git-path hooks` (not a hard-coded `.git/hooks`) so it lands
# in the right place inside a linked worktree or a submodule, where the git dir
# is not `.git`.
.PHONY: install-hooks
install-hooks:
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then \
	  echo "note: not a git checkout — skipping pre-push hook install"; \
	else \
	  hook="$$(git rev-parse --git-path hooks)/pre-push"; \
	  if [ -e "$$hook" ] && ! grep -q 'tracebloc pre-push hook' "$$hook" 2>/dev/null; then \
	    echo "note: $$hook already exists and is not ours — leaving it untouched."; \
	    echo "      add 'make check' to it, or remove it and re-run 'make install-hooks'."; \
	  else \
	    mkdir -p "$$(dirname "$$hook")" && \
	    printf '%s\n' \
	      '#!/bin/sh' \
	      '# tracebloc pre-push hook installed by make setup (backend#1606).' \
	      '# Runs make check so a push that would be red in CI is caught locally first.' \
	      '# It catches forgetting, not defiance: git push --no-verify skips it.' \
	      '#' \
	      '# Git exports GIT_DIR/GIT_WORK_TREE/etc into hook processes; a nested git' \
	      '# (e.g. Go buildvcs under go test) then fails in a linked worktree with' \
	      '# exit status 128. Clear them so make check runs as if from the shell.' \
	      'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY' \
	      'exec make check' > "$$hook" && \
	    chmod +x "$$hook" && \
	    echo "==> pre-push hook installed at $$hook" && \
	    echo "    'make check' now runs before each push (skip once with: git push --no-verify)"; \
	  fi; \
	fi

# ---- individual targets ------------------------------------------

# lint: both halves, and `Standard checks / Lint` runs exactly this target, so
# the pre-push tier and the merge gate cannot disagree about what linting means
# (backend#1850). Neither half installs anything: bash is bash, and shellcheck is
# preinstalled on ubuntu-latest.
# .bats files are bats DSL, not valid bash — they are exercised by
# actually running them in the `bats` target.
#
# The parse loop is `xargs -0 -n1`, NOT `while read -r -d ''`. Make runs
# recipes under /bin/sh, which on Debian and Ubuntu is dash, and dash
# rejects `read -d` outright — the loop body would never execute and the
# pipeline would still exit 0, so `make check` would cheerfully print
# "all shell scripts parse" having parsed nothing. GitHub Actions uses
# bash, so CI never showed it. xargs is POSIX, NUL-safe, and propagates
# a child failure as a non-zero exit. (Bugbot, #630.) The same hazard is why
# the `shellcheck` target materialises its file list instead of piping it.
.PHONY: lint
lint: parse shellcheck

# parse: bash -n over every shell script under scripts/. Reached in CI through
# `make lint`, which is what `Standard checks / Lint` runs -- not as a target of
# its own. Needs nothing but bash, which is why it survived #753's install purge.
#
# Materialises the list and counts it, for the same reason the `shellcheck`
# target does (Arturo, #754 review). The previous one-liner was
#
#     @find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
#     @echo "all shell scripts parse"
#
# and it FAILED OPEN in two ways at once. `find`'s exit status is lost across
# the pipe -- recipes run under dash, which has no `pipefail` -- and `xargs`
# with no input runs nothing and exits 0. So in a tree where `scripts/` is
# missing or renamed it printed
#
#     find: scripts: No such file or directory
#     all shell scripts parse
#
# and exited 0, under both dash and bash. That was survivable while an
# enumerated shellcheck line ran straight after it and would have failed on the
# same breakage; #753 made `parse` a load-bearing half of the required `Lint`
# check, which is exactly when a fail-open stops being tolerable.
#
# The count is derived and printed, so "parsed nothing" can no longer read
# identically to "parsed everything" -- the #630 hazard, one target over.
.PHONY: parse
parse:
	@files=$$(mktemp); \
	if ! find scripts -type f -name '*.sh' -print > "$$files" 2>/dev/null; then \
	  echo "parse: could not enumerate scripts/ -- refusing to report green"; \
	  rm -f "$$files"; exit 1; \
	fi; \
	n=$$(wc -l < "$$files" | tr -d " "); \
	if [ "$$n" -eq 0 ]; then \
	  echo "parse: found ZERO shell scripts under scripts/ -- refusing to report green"; \
	  rm -f "$$files"; exit 1; \
	fi; \
	tr "\n" "\0" < "$$files" | xargs -0 -r -n1 bash -n; \
	rc=$$?; rm -f "$$files"; \
	if [ "$$rc" -eq 0 ]; then echo "all $$n shell scripts parse"; fi; \
	exit $$rc

# shellcheck: run BOTH by the pre-push tier and by CI -- `Standard checks /
# Lint` calls `make lint`, which is this plus `parse`. No install anywhere:
# shellcheck is preinstalled on ubuntu-latest. One definition, so `make check`
# genuinely predicts the gate instead of merely resembling it (backend#1850).
#
# Two fail-closed properties, both of which the old one-liner lacked:
#   * classifying ZERO files is a FAILURE, not a green run. A silent no-op is
#     exactly how a broken derivation would look (backend#1729 rule 3).
#   * the classifier's exit code is not swallowed by the pipe. Recipes run
#     under /bin/sh -- dash on Debian, no pipefail -- so the file list is
#     materialised first and shellcheck's own status is what propagates.
# The `; :` inside the classifier is load-bearing: `grep -q ... && printf`
# exits 1 on every non-shell file, which would otherwise make xargs return 123.
# Both shellcheck sweeps read ONE definition of "which files are shell":
# $(SH_FILES). Overridable ONLY so the fail-closed path can be exercised without
# editing the real classifier -- `make shellcheck SH_FILES=/path/to/stub`. See that file's header for why it is a script and not a
# list -- in short, #753 replaced a 19-entry SHELLCHECK_FILES enumeration with a
# derivation after the list drifted past eight real scripts, and this PR's
# advisory sweep then kept referencing the deleted variable and went permanently
# green with no operands behind `|| true` (Arturo, #755 review). The script exits
# non-zero on a zero-file classification, so a broken derivation is loud in both
# sweeps instead of looking like a clean run in either.
SH_FILES ?= scripts/sh-files.sh

.PHONY: shellcheck
shellcheck:
	@files=$$(mktemp); \
	if ! $(SH_FILES) > "$$files"; then rm -f "$$files"; exit 1; fi; \
	n=$$(wc -l < "$$files" | tr -d " "); \
	echo "shellcheck: $$n file(s), severity=error"; \
	tr "\n" "\0" < "$$files" | xargs -0 -r shellcheck --severity=error --exclude=SC1091; \
	rc=$$?; rm -f "$$files"; exit $$rc

# lint-warnings: the advisory `--severity=warning` sweep, over the SAME derived
# set as `shellcheck` -- same script, so the two cannot diverge again.
#
# NOT part of `lint` and NOT a gate: the libs are sourced together as one
# program, so single-file shellcheck reports SC2034 "unused" for shared vars
# (CURL_SECURE, ARCH_DL, the colours) that common.sh defines and other libs
# consume. Printed for visibility only.
#
# `|| true` sits on the shellcheck INVOCATION only, never around the derivation
# -- that is the distinction the old one-liner lost. A broken classifier exits 1
# through sh-files.sh; only genuine warnings are tolerated.
#
# It exists as a target because installer-tests.yaml's `static` job used to run
# this sweep inline, and that job is gone; standard-checks.yml's `Lint` calls
# this so the visibility survives the move rather than being quietly dropped.
.PHONY: lint-warnings
lint-warnings:
	@files=$$(mktemp); \
	if ! $(SH_FILES) > "$$files"; then rm -f "$$files"; exit 1; fi; \
	n=$$(wc -l < "$$files" | tr -d " "); \
	echo "lint-warnings: $$n file(s), severity=warning (advisory)"; \
	tr "\n" "\0" < "$$files" | xargs -0 -r shellcheck --severity=warning --exclude=SC1091 || true; \
	rm -f "$$files"

# drift: the repo's duplicated-declaration guards, and the ONLY declaration of
# that set. drift-checks.yaml's `Source-of-truth drift` job -- the one that is a
# REQUIRED check on develop and on main -- runs `make drift` and lists nothing
# itself, so a guard added here gates automatically and the pre-push hook and
# the merge gate cannot disagree about what "the drift guards" are.
#
# They could, and did. Until 2026-08-19 this target held gen-manifest /
# check-facts / check-style while the required job held check-drift, so each
# side gated exactly what the other did not: a stale manifest.sha256 was caught
# by the pre-push hook and NOT at the merge gate, because the job that ran R8
# (`Static analysis`) is required on no branch. Hence one list, here.
#
# No count is written down. It was "five" for about two hours and was already
# six -- `telemetry-vocabulary-agreement.sh` arrived with a develop merge and
# neither prose copy followed it (Asad + Arturo, #755 review), which is the exact
# divergence this target exists to stop. The recipe prints the live number.
#
# Most are pure local file comparisons with a --write / regenerate mode named in
# their own output. `check-drift.sh` is the exception and wants `helm template`;
# an earlier version of this comment claimed all of them regenerate, one sentence
# before admitting that one shells out to helm.
#
# env-vocabulary-agreement lives here, not in `helm-vocab`, because #715 moved
# it out of helm-ci's `Helm lint` into the required drift job; helm-ci's lint job
# calls `make helm-lint helm-vocab`, so keeping it there would silently put it
# back where #715 took it from.
#
# `|`-separated because each guard is a multi-word command. One entry per guard,
# and this is the only place they are written down.
DRIFT_GUARDS := scripts/gen-manifest.sh --check|scripts/check-facts.sh --check|bash scripts/check-style.sh|bash scripts/tests/check-drift.sh|bash scripts/tests/env-vocabulary-agreement.sh|bash scripts/tests/telemetry-vocabulary-agreement.sh|bash scripts/tests/k3s-components-agreement.sh|bash scripts/tests/collector-class-a-agreement.sh|bash scripts/tests/openshift-scc-coverage.sh|bash scripts/tests/collector-offsets-persisted.sh|bash scripts/tests/node-agents-tenancy.sh|bash scripts/tests/telemetry-token-agreement.sh|bash scripts/tests/node-agents-namespace-safety.sh|bash scripts/tests/automount-token-explicit.sh|bash scripts/tests/collector-redaction-floor.sh|bash scripts/tests/collector-redaction-derived.sh|bash scripts/tests/telemetry-token-bootstrap.sh|bash scripts/tests/node-jsonpath-agreement.sh

# EXPORTED, not interpolated. The recipe reads $$DRIFT_GUARDS from the
# environment; it used to do `guards='$(DRIFT_GUARDS)'`, which Make expands
# INSIDE single quotes, so the first guard containing a `'` -- `bash -c '...'`,
# `python3 -c '...'` -- would terminate the assignment, collapse the list, and
# run zero guards while printing "all guards green" and exiting 0. In the check
# this PR makes REQUIRED. Found by Asad, reproduced independently by Arturo and
# again here (#755 review):
#
#   $ make drift DRIFT_GUARDS=                                  -> green, exit 0
#   $ make drift "DRIFT_GUARDS=bash -c 'exit 1'|scripts/..."    -> green, exit 0
#
# The irony was the point: this PR's whole argument is that a guard which cannot
# fail is not a gate, and its own comment here claimed "this is NOT the fail-open
# shape" -- a claim that should have been a machine check (backend#1729 rule 7).
# Now it is one, three ways:
#   * an empty list is a FAILURE, not a clean sweep;
#   * the environment carries the value, so no quote in a guard can collapse it;
#   * the loop COUNTS its iterations and refuses to report green unless it ran
#     exactly the number of `|`-separated entries the list declares.
export DRIFT_GUARDS

# Every guard RUNS even when an earlier one fails, and the target fails at the
# end if any did -- so a stale manifest no longer hides a terminology violation
# until you fix the manifest, push, and wait for CI again. The guards are
# independent in their REPORTING, never in whether they block.
.PHONY: drift
drift:
	@if [ -z "$${DRIFT_GUARDS:-}" ]; then \
	  echo "drift: the guard list is EMPTY -- refusing to report green on zero guards."; \
	  exit 1; \
	fi; \
	exp=$$(printf '%s' "$$DRIFT_GUARDS" | awk -F'|' '{print NF}'); \
	fail=0; ran=0; oifs=$$IFS; IFS='|'; \
	for g in $$DRIFT_GUARDS; do \
	  IFS=$$oifs; ran=$$((ran+1)); \
	  printf '\n==> %s\n' "$$g"; \
	  sh -c "$$g" || { fail=1; printf '!! FAILED: %s\n' "$$g"; }; \
	  IFS='|'; \
	done; IFS=$$oifs; \
	if [ "$$ran" -ne "$$exp" ]; then \
	  printf '\ndrift: ran %s guard(s) but the list declares %s -- refusing to report green.\n' "$$ran" "$$exp"; \
	  exit 1; \
	fi; \
	if [ "$$fail" -ne 0 ]; then \
	  printf '\ndrift: one or more guards FAILED (all %s were run -- see !! lines above)\n' "$$ran"; \
	  exit 1; \
	fi; \
	printf '\ndrift: all %s guards green\n' "$$ran"

# digest-drift: the watcher on every mutable label that points at a pinned
# digest (backend#1853). NOT in `check`: it needs the network and a docker
# daemon, and it is knowingly RED today -- the ingestor's 0.8 float has moved
# off the pinned v0.8.2 digest, which is the whole finding. A red target in the
# pre-push tier trains people to skip the tier.
#
# It runs on the schedule in .github/workflows/digest-drift.yml. Its bats suite
# IS in `make bats`, because that part needs no network.
.PHONY: digest-drift
digest-drift:
	scripts/check-digest-drift.sh

# bats: standard-checks.yml `Unit tests` / installer-tests.yaml
# `unit-bash`. ~2 min serially.
.PHONY: bats
bats:
	bats scripts/tests/*.bats

# helm-lint: helm-ci.yaml `lint`.
.PHONY: helm-lint
helm-lint:
	@for f in client/ci/*-values.yaml; do \
	  echo "=== Linting client with $$f ==="; \
	  helm lint --strict ./client -f "$$f" || exit 1; \
	done
	helm lint --strict ./ingestor

# helm-vocab: helm-ci.yaml `lint` job's vocabulary step. The CLIENT_ENV and
# channelTags vocabularies are closed by a values.schema.json `enum` /
# `additionalProperties` plus a `fail` in tracebloc.clientEnv, and helm-unittest
# can assert NEITHER: it treats a schema violation as a plugin-level error
# rather than a template failure, and offers no way to skip validation and reach
# the helper. So the gates are exercised from outside the plugin. ~2 s.
#
# CHART vocabulary only. env-vocabulary-agreement.sh is in `drift`, not here --
# see that target for why (#715 moved it to the required drift gate, and
# helm-ci's lint job runs this target).
.PHONY: helm-vocab
helm-vocab:
	bash scripts/tests/chart-env-vocabulary.sh

# helm-template: helm-ci.yaml `template`. kubeconform is pinned by
# version AND digest in CI; rather than re-implement that download here,
# this renders every platform (which is the part that catches template
# breaks) and runs kubeconform only if you already have it.
.PHONY: helm-template
helm-template:
	@for p in aks bm eks oc; do \
	  echo "=== Rendering $$p ==="; \
	  helm template test-$$p ./client -f client/ci/$$p-values.yaml > /tmp/rendered-$$p.yaml || exit 1; \
	  if command -v kubeconform >/dev/null 2>&1; then \
	    kubeconform -strict -ignore-missing-schemas -summary /tmp/rendered-$$p.yaml || exit 1; \
	  fi; \
	done
	@command -v kubeconform >/dev/null 2>&1 \
	  || echo "note: kubeconform not on PATH — rendered only. CI also validates the manifests."

# helm-unittest: helm-ci.yaml `unittest`. Needs the plugin; the install
# command is the one CI uses, pinned to the same version.
.PHONY: helm-unittest
helm-unittest:
	@helm plugin list 2>/dev/null | grep -q unittest \
	  || { echo "helm-unittest plugin missing — install it with:"; \
	       echo "  helm plugin install https://github.com/helm-unittest/helm-unittest --version 0.5.2"; \
	       exit 1; }
	helm unittest ./client
