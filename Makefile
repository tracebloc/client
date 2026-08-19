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
# workflow that already runs it — standard-checks.yml, installer-tests.yaml
# and helm-ci.yaml. It introduces no new tool, no new config, and no new
# rule. When a workflow changes, change the matching line here.
#
# `shellcheck` is the one target not copied from a workflow LINE, but it is
# still exactly what a workflow runs: since #753, `Standard checks / Lint` runs
# `make lint`, so this file IS the definition rather than a copy of one. The org
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
# `bats`'s own count exactly (verified: 946 = 946).
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
.PHONY: shellcheck
shellcheck:
	@files=$$(mktemp); \
	git ls-files -z \
	  | xargs -0 -r -n1 sh -c 'case "$$1" in \
	      *.sh|*.bash|*.ksh) printf "%s\n" "$$1" ;; \
	      *.bats|*.ps1|*.psm1|*.zsh) ;; \
	      *) head -n 1 "$$1" 2>/dev/null \
	           | grep -Eq "^#![[:space:]]*[^[:space:]]*(/|[[:space:]])(ba|da|k)?sh([[:space:]]|$$)" \
	           && printf "%s\n" "$$1" ;; \
	    esac; :' sh > "$$files"; \
	n=$$(wc -l < "$$files" | tr -d " "); \
	if [ "$$n" -eq 0 ]; then \
	  echo "shellcheck: classified ZERO shell files -- the derivation above is broken."; \
	  echo "            Refusing to report green on an empty file set."; \
	  rm -f "$$files"; exit 1; \
	fi; \
	echo "shellcheck: $$n file(s), severity=error"; \
	tr "\n" "\0" < "$$files" | xargs -0 -r shellcheck --severity=error --exclude=SC1091; \
	rc=$$?; rm -f "$$files"; exit $$rc

# drift: the repo's duplicated-declaration guards. The first three come from
# installer-tests.yaml's `static` job; all three are pure local file
# comparisons (~0.2 s) and all three have a --write / regenerate mode named in
# their own output.
#
# The fourth is the CLIENT_ENV vocabulary-agreement guard (backend#1729
# sweep 5). It lives here, not in `helm-vocab`, because #715 moved it out of
# helm-ci's `Helm lint` into drift-checks.yaml's `Source-of-truth drift` job --
# the one that is a REQUIRED check, so the guard can block rather than advise.
# helm-ci's lint job calls `make helm-lint helm-vocab`, so keeping the guard in
# `helm-vocab` would silently put it back where #715 took it from. ~2 s, bash
# and python3 only.
.PHONY: drift
drift:
	scripts/gen-manifest.sh --check
	scripts/check-facts.sh --check
	bash scripts/check-style.sh
	bash scripts/tests/env-vocabulary-agreement.sh
	bash scripts/tests/telemetry-vocabulary-agreement.sh

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
