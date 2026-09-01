"""Assertions 2, 3 and 4 of the fullnameOverride guard — backend#2626.

Split out of `fullname-override-completeness.sh` rather than embedded as a
heredoc so it can be read, linted and reasoned about; the shell half only
renders and loops profiles.

Reads the rendered manifests — produced with `fullnameOverride` set to something
distinctive — and answers two opposite questions about the SAME set of scalars:

  MOVED   nothing may still carry the release name
  STAYED  every declared exception must still carry it

Both are required. Checking only the first is satisfied by renaming Helm's own
bookkeeping and the env var `helm rollback` reads.

ONE CLASSIFIER, TWO CALLERS, and this is the structural point rather than a
refactor. The first version answered MOVED by looking at doc-root
`metadata.name` and nothing else, while STAYED enumerated the exception classes
separately. So the two halves disagreed about what the exceptions were, and
every name-REFERENCE site fell through the gap: un-routing `DEPLOYMENT_NAME`
(which `kubectl set image` targets) or the Collector's filelog glob (which globs
pod directories) rendered both broken and left the guard green on all four
profiles — the two sites this PR's own description called out as the ones a
`metadata.name` sweep misses (Asad + Bugbot, review of backend#2626).

Now `classify()` walks EVERY string scalar and labels the ones carrying the
release name with the exception class that licenses them, or `None`. MOVED is
"nothing classified `None`"; STAYED is "every class is non-empty and correct".
Neither can be satisfied by breaking the other, and neither can be satisfied by
a site the other never looked at.
"""

from __future__ import annotations

import os
import re
import sys

# PREFLIGHT, NOT A BARE IMPORT. This runs on CI runners and on operators'
# laptops, and a runner with `python3` but no PyYAML used to die as a
# `ModuleNotFoundError` traceback -- after which the shell half printed
# "[ERROR] fullnameOverride is incomplete in 4 profile check(s)", so a MISSING
# DEPENDENCY reported itself as a chart defect and sent the reader hunting
# un-routed names that do not exist (Asad + Bugbot, review of backend#2626).
#
# Exit 2, distinct from the 1 that means "the chart is incomplete": the caller
# and a human both need "could not check" to be a different answer from "checked
# and found a problem". `scripts/tests/pyyaml-preflight.bats` asserts every
# sidecar in this tree carries this shape.
try:
    import yaml
except ImportError:
    # `ImportError`, NOT `ModuleNotFoundError`, and the distinction is not
    # pedantic. `ModuleNotFoundError` is a SUBCLASS of `ImportError`, so catching
    # the subclass misses the parent -- and a plain `ImportError` is exactly what
    # `scripts/tests/pyyaml-preflight.bats` injects to simulate an absent PyYAML
    # (`raise ImportError("simulated: PyYAML not installed")`). Measured: under
    # that simulation the narrow form gave a TRACEBACK and rc 1, i.e. the very
    # failure this block exists to prevent, while the bats class-rule stayed
    # green because it reads the AST and accepts either name.
    #
    # It is also the real-world case: a PyYAML installed but broken (a partial
    # wheel, a C-extension mismatch) raises `ImportError`, not
    # `ModuleNotFoundError`. Catching the parent covers both.
    sys.stderr.write(
        "[ERROR] this guard needs PyYAML and the interpreter does not have it.\n"
        "        Install it:  python3 -m pip install pyyaml\n"
        "        NOT a chart defect -- nothing about fullnameOverride was\n"
        "        checked, which is a different answer from 'checked and clean'.\n"
    )
    raise SystemExit(2)

#: Env var names that ARE a Helm identity and must keep the release name.
#: `helm rollback` reads these; renaming them is backend#2620.
RELEASE_ENV = {"RELEASE_NAME", "RELEASE", "RELEASE_NAMESPACE"}

#: Attribute paths whose value IS the release name, by Helm's own convention.
RELEASE_IDENTITY_SUFFIXES = (
    ".app.kubernetes.io/instance",
    ".meta.helm.sh/release-name",
)

# The exception classes, as labels. Kept as constants because both the
# classifier and the per-class expectations below key on them, and a typo in one
# place would silently create a class nothing checks.
CLS_INSTANCE = "app.kubernetes.io/instance label"
CLS_ANNOTATION = "meta.helm.sh/release-name annotation"
CLS_ENV = "RELEASE_NAME / RELEASE / RELEASE_NAMESPACE env (a Helm identity)"
CLS_PATH = "on-disk path (a location, not a name)"


def walk(node, path=""):
    """Every scalar in the document, with a dotted path to it."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{path}[{i}]")
    else:
        yield path, node


def env_value_paths(doc):
    """`{path-of-an-env-value: ENV_NAME}` for every env entry in `doc`.

    Env vars are `name`/`value` SIBLINGS, so the variable's name is not on its
    value's path and cannot be recovered from the path alone. Computed once per
    document and shared by both callers rather than re-derived in each.
    """
    out = {}
    for path, val in walk(doc):
        if path.endswith(".name") and isinstance(val, str):
            out[path.rsplit(".name", 1)[0] + ".value"] = val
    return out


def classify(doc, path, val, rel, ns, envs):
    """Which exception licenses `val` carrying the release name — or `None`.

    `None` means "an unrouted site". Every branch here is a class STAYED then
    checks for the right VALUE, so adding a class cannot weaken MOVED without
    also adding an obligation.
    """
    if any(path.endswith(s) for s in RELEASE_IDENTITY_SUFFIXES):
        return CLS_INSTANCE if path.endswith(RELEASE_IDENTITY_SUFFIXES[0]) else CLS_ANNOTATION
    if path in envs and envs[path] in RELEASE_ENV:
        return CLS_ENV
    # A PATH IS A LOCATION. `/var/lib/tracebloc/<release>/telemetry` merely
    # contains the release; renaming it orphans a tenant's data rather than
    # moving it. Deliberately narrow: only a value that IS a filesystem path, at
    # a key that declares itself one. A release-scoped path embedded in a
    # ConfigMap blob is NOT covered, which is what makes the Collector's filelog
    # glob catchable.
    if path.endswith(".hostPath.path") or (path.endswith(".path") and val.startswith("/")):
        return CLS_PATH
    return None


# --------------------------------------------------------------------------
# Assertion 5 — the CLASS behind the credential-Secret finding
# --------------------------------------------------------------------------
#
# THE INSTANCE IS FIXED ELSEWHERE, AND THIS IS THE CLASS. `secrets.yaml` resolves
# credentials as "explicit, else THE VALUE IN THE LIVE SECRET, else randAlphaNum",
# and the middle tier is a `lookup` keyed on a name that follows the override. A
# lookup that misses is not an error -- it silently takes the last tier, which for
# a credential means minting a new password while the fixed-name `mysql-pvc`
# datadir keeps the old one. That was Bugbot's High on this PR, and it is fixed in
# `secrets.yaml` by refusing a rename of a live release.
#
# But it is a CLASS, and this chart has TWO members:
#
#   secrets.yaml                     mitigated by a `fail` keyed on the
#                                    un-overridden name (that refusal)
#   tracebloc.telemetryTokenPresent  mitigated by OR-ing a lookup on the LEGACY
#                                    fixed name -- and nothing asserted that
#
# So the second member was one edit away from the same silent shape, with no
# check. This holds both: a Secret lookup keyed on a name that follows the
# override must carry one of the two mitigations, in its own file.
#
# WHICH NAMES FOLLOW THE OVERRIDE IS DERIVED, INCLUDING THROUGH HELPERS -- closed
# over `include` across the template sources rather than listed here, so a helper
# added tomorrow that wraps `fullname` is covered without anyone remembering.
#
# IT DOES NOT SECOND-GUESS WHICH MITIGATION IS RIGHT. `secrets.yaml`'s refusal was
# measured against a live cluster with `--dry-run=server`, which is the only way to
# exercise a `lookup` at all; this assertion is a text-level check and could not
# have established that. It only requires that a mitigation is still there.

TEMPLATES = "client/templates"
_INCLUDE = re.compile(r'include\s+"([^"]+)"')
_SECRET_LOOKUP = re.compile(r'lookup\s+"v1"\s+"Secret"\s+\S+\s+([^\n)]*\)?)')
#: Every `{{ … }}` action, in order. Used to find a define's BALANCED end.
_ACTION = re.compile(r"{{-?\s*(.*?)\s*-?}}", re.S)
#: Actions that open a block and therefore need their own `end`.
_OPENS = re.compile(r"^(if|range|with|block|define)\b")


def define_bodies(text):
    """`{helper: body}`, each body closed at its BALANCED `end`.

    NOT A REGEX, and the regex it replaces was a real defect (Bugbot, Medium).
    `{{- define "x" -}}(.*?){{- end -}}` is non-greedy, so a helper containing an
    inner `if`/`range`/`with` closes at the INNER `end` and its tail is silently
    dropped. Measured on this chart: 28 of 55 helper bodies were truncated.

    It changed no answer TODAY — no helper's `tracebloc.fullname` reference
    happens to sit in a dropped tail, so the routed-helper closure came out at 21
    either way. That is exactly why it was worth fixing rather than noting: the
    guard's coverage depended on WHERE in a helper an include happened to sit, and
    one edit moving an include below an `if` would have silently un-routed it —
    after which a routed Secret lookup reads as unrouted and assertion 5 stops
    requiring a mitigation. A check that passes because it is not connected to
    what it claims to check.

    Depth is counted over the ACTIONS rather than over the text, so an `end`
    inside a quoted string or a comment cannot close a block early.
    """
    out, stack = {}, []
    for m in _ACTION.finditer(text):
        action = m.group(1)
        opened = re.match(r'define\s+"([^"]+)"', action)
        if opened:
            stack.append([opened.group(1), m.end(), 1])
            continue
        if not stack:
            continue
        if _OPENS.match(action):
            stack[-1][2] += 1
        elif re.match(r"^end\b", action):
            stack[-1][2] -= 1
            if stack[-1][2] == 0:
                name, start, _ = stack.pop()
                out[name] = text[start : m.start()]
    return out


def helpers_following_the_override(sources):
    """Helper names whose rendered value contains `tracebloc.fullname`.

    Transitive: a helper that includes a helper that includes `fullname` follows
    the override too. Closed by iteration rather than recursion so a cyclic
    include cannot hang the guard.
    """
    bodies = {}
    for text in sources:
        bodies.update(define_bodies(text))
    following = {"tracebloc.fullname"}
    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in following:
                continue
            if any(inc in following for inc in _INCLUDE.findall(body)):
                following.add(name)
                changed = True
    return following


def _mitigations(text, routed_vars):
    """Which mitigation shapes this file carries, as a set of labels.

    TWO SHAPES, BOTH REAL, and neither is a substitute for judgement about which
    one a given site needs:

      "refusal"  a MISS on the routed lookup leads to `fail` — however the other
                 half of the condition is computed
      "fallback" a second lookup in the same expression, on a name that does not
                 follow the override — `telemetryTokenPresent`'s legacy name.
                 NOT computed here: it is a property of the LINE, so it is
                 established per site by `_fallback_on_line` rather than once per
                 file. A file-wide answer let one qualifying line license every
                 routed lookup in it (client#911).

    THE REFUSAL IS DETECTED ON THE INVARIANT, NOT ON THE ARITHMETIC. The first cut
    matched `printf "%s-secrets" .Release.Name` — the shape the refusal happened to
    have when it keyed on the UN-OVERRIDDEN NAME. Arturo then showed that name
    keying caught only one of three rename directions and missed reinstall-over-a-
    kept-PVC entirely, so the refusal was re-keyed on the persisted DATA (the
    retained `mysql-pvc`) — a strictly better guard that my detector would have
    reported as no guard at all.

    A detector that breaks when the thing it guards is IMPROVED is worse than
    none: it pushes back toward the shape it happened to be written against. So it
    now keys on the property that has to hold however the other half is computed —
    a miss on THIS lookup must reach a `fail`:

        $existingSecret := (lookup "v1" "Secret" … $secretName)
        …
        if and $mysqlDataPresent (not $existingSecret)   <- the miss
          fail …                                        <- the refusal

    `routed_vars` are the variables assigned from a routed Secret lookup, so the
    negation has to be of THAT lookup's result rather than of any variable.
    """
    out = set()
    lines = text.splitlines()
    for var in routed_vars:
        neg = re.compile(rf"(not|empty)\s+\${re.escape(var)}\b")
        for i, line in enumerate(lines):
            if not neg.search(line):
                continue
            # `fail` within the guarded block. A small window rather than a full
            # parse: the refusal is the first statement of the branch in every
            # spelling this chart uses, and a wider window would start accepting
            # an unrelated `fail` further down the file.
            if any("fail " in nxt or "fail(" in nxt for nxt in lines[i : i + 4]):
                out.add("refusal")
    return out


def _fallback_on_line(code, following, vars_):
    """True iff THIS line carries a Secret lookup the override cannot move.

    THE PROPERTY, NOT A PROXY FOR IT (@saadqbal on client#911). This used to be
    `count("lookup ") >= 2` over every line in the FILE, and the result was reused
    for every routed lookup in that file. Both halves were wrong, and the docstring
    above already described the check this now performs — "a second lookup in the
    same expression, on a name that does not follow the override" — while the code
    asserted only that two `lookup ` substrings existed SOMEWHERE.

    Measured: routing all three telemetry-token names through `fullnameOverride`
    leaves every probe missing on a rename, and the old detector still reported
    "all 2 routed Secret lookup(s) of 2 carry a mitigation" and exited 0. It
    counted the arity of the fallback and never its point — a fallback that also
    follows the override is not a fallback, it is the same miss twice.

    So the question asked here is the one that matters: does at least one lookup on
    this line key on a name the override CANNOT move? `.Release.Name` and a literal
    both qualify; anything reaching `tracebloc.fullname` does not.
    """
    for expr in _SECRET_LOOKUP.findall(code):
        referenced = set(_INCLUDE.findall(expr))
        for v in re.findall(r"\$(\w+)", expr):
            if v in vars_:
                referenced.add(vars_[v])
        if not (referenced & following):
            return True
    return False


#: A helper whose `fullname` reference sits AFTER an inner `if`/`end` — the exact
#: shape the non-greedy regex dropped. Written down here rather than hunted for in
#: the chart, because the chart does not currently contain one: the defect was
#: LATENT, and a check that can only be exercised by a bug already present is a
#: check that arrives too late (CLAUDE.md rule 6 — derive the input domain, do not
#: wait for the input).
_SELFTEST_TEMPLATE = """
{{- define "probe.routed" -}}
{{- if .Values.something -}}
irrelevant
{{- end -}}
{{ include "tracebloc.fullname" . }}-probe
{{- end -}}
{{- define "probe.unrouted" -}}
{{- if .Values.something -}}
irrelevant
{{- end -}}
a-constant-name
{{- end -}}
"""


#: THREE LINES THAT PIN `_fallback_on_line` TO ITS STATED PROPERTY (@saadqbal,
#: review of client#911). The detector it replaced -- `count("lookup ") >= 2` over
#: the whole FILE -- was quietly wrong for five rounds and nothing in the tree
#: could tell: regress to it and the real chart still renders green, because the
#: chart happens not to contain the shape that separates them. Same reasoning as
#: `_SELFTEST_TEMPLATE` above: a check exercisable only once the bug is present
#: arrives too late, so the input is written down rather than waited for.
#:
#: `_BOTH_ROUTED` is the one that does the pinning. Two lookups on one line, both
#: keyed on names the override moves -- so on a rename both probes miss together
#: and the "fallback" mitigates nothing. The old form counted two `lookup `s and
#: called it mitigated; the property says it is not.
_SELFTEST_BOTH_ROUTED = (
    '{{- $s := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.fullname" .)) '
    '| default (lookup "v1" "Secret" .Release.Namespace (include "probe.routed" .)) -}}'
)
#: A genuine fallback: the second lookup keys on a literal, which no override can
#: move, so it still resolves after a rename.
_SELFTEST_REAL_FALLBACK = (
    '{{- $s := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.fullname" .)) '
    '| default (lookup "v1" "Secret" .Release.Namespace "tracebloc-legacy-secret") -}}'
)
#: And the single-lookup routed case, which has no fallback at all -- the negative
#: control for a detector that simply answered True.
_SELFTEST_NO_FALLBACK = (
    '{{- $s := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.fullname" .)) -}}'
)


def selftest_the_fallback_detector():
    """`(ok, messages)` — `_fallback_on_line` asks the property, not the arity.

    Three halves, and the FIRST is the one the old form fails: without it, a
    detector counting `lookup ` occurrences passes everything here.
    """
    following = {"tracebloc.fullname", "probe.routed"}
    msgs, ok = [], True
    if _fallback_on_line(_SELFTEST_BOTH_ROUTED, following, {}):
        ok = False
        msgs.append(
            "   [ERROR] a line whose BOTH Secret lookups key on names the override "
            "moves reads as mitigated. That is the arity of the fallback, not its "
            "point — on a rename both probes miss together, and assertion 5 then "
            "passes a chart where a routed credential Secret is unreachable.")
    if not _fallback_on_line(_SELFTEST_REAL_FALLBACK, following, {}):
        ok = False
        msgs.append(
            "   [ERROR] a lookup keyed on a literal name is not recognised as a "
            "fallback, so every genuinely mitigated site reports as unmitigated "
            "and the assertion fails on a safe chart — noise that gets it muted.")
    if _fallback_on_line(_SELFTEST_NO_FALLBACK, following, {}):
        ok = False
        msgs.append(
            "   [ERROR] a single routed lookup with no second probe reads as "
            "mitigated, so the detector answers True regardless of its input.")
    # THE `$var` INDIRECTION IS LIVE CODE and gets the same treatment: the same
    # routed name reached through `$name` must read exactly as it does inline.
    if _fallback_on_line(
        '{{- $s := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.fullname" .)) '
        '| default (lookup "v1" "Secret" .Release.Namespace $probe) -}}',
        following, {"probe": "probe.routed"},
    ):
        ok = False
        msgs.append(
            "   [ERROR] a routed name reached through a `$var` reads as an "
            "unmovable one, so the indirection launders a routed lookup into a "
            "mitigation.")
    if ok:
        msgs.append("   [OK] the fallback detector keys on the property, not the lookup count")
    return ok, msgs


#: FOUR SPECIMENS THAT PIN `_mitigations` (@saadqbal, review of client#911).
#: `_fallback_on_line` had three; its sibling had NONE, and that asymmetry is the
#: whole finding: make `_mitigations` return `{"refusal"}` unconditionally and
#: assertion 5 still prints "all 2 routed Secret lookup(s) of 2 carry a mitigation"
#: and exits 0, with both existing selftests green. The detector that decides
#: whether a routed credential Secret is mitigated could be deleted and nothing in
#: the tree would say so.
#:
#: Written down here rather than hunted for in the chart, for the reason the
#: fallback specimens give: a check exercisable only once the bug is present
#: arrives too late.
_SELFTEST_REFUSAL = (
    '{{- $existingSecret := (lookup "v1" "Secret" .Release.Namespace $secretName) -}}\n'
    '{{- if and $mysqlDataPresent (not $existingSecret) -}}\n'
    '{{-   fail "refusing to reinstall over a kept PVC" -}}\n'
    '{{- end -}}\n'
)
#: The same negation, but NO `fail` follows it -- a condition that merely branches.
_SELFTEST_NO_REFUSAL = (
    '{{- $existingSecret := (lookup "v1" "Secret" .Release.Namespace $secretName) -}}\n'
    '{{- if and $mysqlDataPresent (not $existingSecret) -}}\n'
    '{{-   $bootstrap = true -}}\n'
    '{{- end -}}\n'
)
#: A `fail` reached by negating some OTHER variable. This is the discrimination
#: `routed_vars` exists for: a refusal elsewhere in the file must not license the
#: routed lookup.
_SELFTEST_OTHER_VAR_REFUSAL = (
    '{{- if (not $somethingElse) -}}\n'
    '{{-   fail "unrelated refusal" -}}\n'
    '{{- end -}}\n'
)
#: And a `fail` too far below the negation to be its consequence -- the window the
#: detector deliberately keeps small so an unrelated `fail` cannot be adopted.
_SELFTEST_DISTANT_FAIL = (
    '{{- if (not $existingSecret) -}}\n'
    '{{-   $a = 1 -}}\n{{-   $b = 2 -}}\n{{-   $c = 3 -}}\n{{-   $d = 4 -}}\n'
    '{{- end -}}\n'
    '{{- fail "something unrelated, much later" -}}\n'
)


def selftest_the_refusal_detector():
    """`(ok, messages)` — `_mitigations` answers about THIS lookup, not the file.

    The first half is the one an unconditional `return {"refusal"}` fails; the
    rest stop it drifting to "any `fail` anywhere licenses anything".
    """
    msgs, ok = [], True
    if "refusal" not in _mitigations(_SELFTEST_REFUSAL, {"existingSecret"}):
        ok = False
        msgs.append(
            "   [ERROR] a MISS on the routed lookup that reaches `fail` is not "
            "recognised as a refusal, so every mitigated site reports as "
            "unmitigated and assertion 5 fails on a safe chart — noise that gets "
            "it muted.")
    if _mitigations(_SELFTEST_NO_REFUSAL, {"existingSecret"}):
        ok = False
        msgs.append(
            "   [ERROR] a negation that merely BRANCHES reads as a refusal. This is "
            "the half an unconditional `return {\"refusal\"}` fails: without it the "
            "detector can be deleted and assertion 5 still reports every routed "
            "credential Secret as mitigated.")
    if _mitigations(_SELFTEST_OTHER_VAR_REFUSAL, {"existingSecret"}):
        ok = False
        msgs.append(
            "   [ERROR] a `fail` reached by negating an UNRELATED variable licenses "
            "the routed lookup, so one refusal anywhere in a file mitigates every "
            "routed Secret in it — which is the file-wide mistake the fallback half "
            "was already demoted for.")
    if _mitigations(_SELFTEST_DISTANT_FAIL, {"existingSecret"}):
        ok = False
        msgs.append(
            "   [ERROR] a `fail` well below the negation is adopted as its "
            "consequence, so the window is not bounded and any later refusal in the "
            "file counts.")
    if ok:
        msgs.append("   [OK] the refusal detector answers about the routed lookup, not the file")
    return ok, msgs


def selftest_the_parser():
    """`(ok, messages)` — the define parser reads a body past an inner `end`.

    Two halves, and the second is what stops this passing vacuously: a parser that
    marked EVERYTHING routed would satisfy the first assertion and fail this one.
    """
    following = helpers_following_the_override([_SELFTEST_TEMPLATE])
    if "probe.routed" not in following:
        return False, [
            "   [ERROR] the define parser does not read a helper body past an inner "
            "`end`, so a helper whose `fullname` reference sits below an `if` reads "
            "as UNROUTED — after which a routed Secret lookup needs no mitigation "
            "and assertion 5 passes on a chart that is not safe."
        ]
    if "probe.unrouted" in following:
        return False, [
            "   [ERROR] the define parser marked a helper with no `fullname` "
            "reference as routed, so 'follows the override' means nothing and the "
            "check above cannot distinguish a safe site from an unsafe one."
        ]
    return True, ["   [OK] the define parser reads helper bodies past an inner `end`"]


def assert_lookup_keys():
    """`(ok, messages)` — every Secret lookup on a routed name is mitigated."""
    files = sorted(
        os.path.join(TEMPLATES, f)
        for f in os.listdir(TEMPLATES)
        if f.endswith(".yaml") or f.endswith(".tpl")
    )
    if not files:
        return False, [f"   [ERROR] no templates found under {TEMPLATES} — nothing checked."]
    sources = {f: open(f, encoding="utf-8").read() for f in files}
    following = helpers_following_the_override(sources.values())
    if len(following) < 2:
        # FAIL CLOSED: `fullname` alone means the define regex matched nothing, so
        # every name would read as "does not follow the override" and this
        # assertion would pass vacuously.
        return False, [
            "   [ERROR] resolved no helpers as following the override, so every "
            "lookup would read as safe. The define parser matched nothing."
        ]

    msgs, lookups, routed_sites = [], 0, 0
    for path, text in sources.items():
        vars_ = dict(
            re.findall(r'\$(\w+)\s*:?=\s*\(?\s*include\s+"([^"]+)"', text)
        )
        # Variables assigned from a Secret lookup whose NAME follows the
        # override — the ones a refusal has to negate.
        routed_vars = set()
        for m in re.finditer(
            r'\$(\w+)\s*:?=\s*\(?\s*lookup\s+"v1"\s+"Secret"\s+\S+\s+([^\n)]*\)?)', text
        ):
            expr = m.group(2)
            referenced = set(_INCLUDE.findall(expr))
            for v in re.findall(r"\$(\w+)", expr):
                if v in vars_:
                    referenced.add(vars_[v])
            if referenced & following:
                routed_vars.add(m.group(1))
        have = _mitigations(text, routed_vars)
        for line in text.splitlines():
            code = line.split("#", 1)[0]
            if "lookup " not in code or '"Secret"' not in code:
                continue
            lookups += 1
            routed = []
            for expr in _SECRET_LOOKUP.findall(code):
                referenced = set(_INCLUDE.findall(expr))
                for v in re.findall(r"\$(\w+)", expr):
                    if v in vars_:
                        referenced.add(vars_[v])
                if referenced & following:
                    routed.append(expr.strip())
            if not routed:
                continue
            routed_sites += 1
            # Per SITE, not per file: the refusal is a property of the file (it
            # keys on routed_vars), the fallback is a property of this line.
            site_have = have | ({"fallback"} if _fallback_on_line(code, following, vars_) else set())
            if not site_have:
                msgs.append(
                    f"   [ERROR] {path}: a Secret lookup keys on a name that follows "
                    f"fullnameOverride ({', '.join(routed)}) and the file carries "
                    f"NEITHER mitigation — no `fail` reached by a MISS on that "
                    f"lookup, and no fallback lookup on a name the override cannot "
                    f"move. A missed lookup is not an error: it silently takes the "
                    f"last resolution tier, which for a credential means minting a "
                    f"new one while the kept datadir holds the old."
                )
    if not lookups:
        return False, [
            "   [ERROR] found ZERO Secret lookups in the templates — the matcher "
            "sees nothing, so this assertion proves nothing."
        ]
    if not routed_sites:
        # Also a finding: this chart HAS routed lookups, so zero means the
        # "follows the override" resolution stopped resolving.
        return False, [
            "   [ERROR] found ZERO Secret lookups keyed on a routed name, but this "
            "chart has at least two. The name resolution has stopped working, so "
            "every site would read as safe."
        ]
    if msgs:
        return False, msgs
    return True, [
        f"   [OK] all {routed_sites} routed Secret lookup(s) of {lookups} carry a "
        f"mitigation (refusal or fallback)"
    ]


def identity_env_sites(docs, rel, ns, name_token):
    """`{(kind, normalised-name, ENV_NAME)}` for every helm-identity env value.

    THE CLASS BEING NON-EMPTY IS NOT THE PROPERTY (@saadqbal / Bugbot, Medium on
    client#911). STAYED asked only that the `RELEASE_NAME`/`RELEASE`/
    `RELEASE_NAMESPACE` class still hold values equal to the release identity —
    and a value routed through `fullnameOverride` no longer CARRIES the release
    name, so the token scan never classifies it and it simply LEAVES the set.
    `RELEASE_NAME` is set on both the auto-upgrade and image-refresh CronJobs and
    `RELEASE` on the storage-assertions Job, so routing any one of them left the
    class populated by its siblings and the guard green — while auto-upgrade
    would `helm rollback` a name that is no longer the release (backend#2620),
    which is the exact failure this guard exists to prevent.

    So the domain is DERIVED from the render that cannot be wrong — the one with
    the override UNSET — and every site it names must still be there with the
    override set. Disappearing is the finding; the old check could not see it,
    because it only ever looked at what remained.

    The workload NAME moves under the override, so it cannot key the site as-is:
    the release/override token is normalised out, leaving `<NAME>-jobs-manager`
    on both sides.
    """
    out = set()
    token = re.compile(
        rf"(^|[^A-Za-z0-9]){re.escape(name_token)}($|[^A-Za-z0-9])"
    )
    for d in docs:
        kind = d.get("kind")
        raw = (d.get("metadata") or {}).get("name") or ""
        norm = token.sub(r"\1<NAME>\2", raw)
        envs = env_value_paths(d)
        for path, val in walk(d):
            if not isinstance(val, str) or path not in envs:
                continue
            # RELEASE_ENV is the declaration; this reads it rather than repeating
            # the three names, so adding a fourth is covered without an edit here.
            if envs[path] in RELEASE_ENV and val in (rel, ns):
                out.add((kind, norm, envs[path]))
    return out


def strip_ansi(text):
    return re.sub(r"\033\[[0-9;]*m", "", text)


def main() -> int:
    rel = os.environ["RELEASE"]
    ns = os.environ["NS"]
    ovr = os.environ["OVERRIDE"]
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
    default_docs = [d for d in yaml.safe_load_all(open(sys.argv[2], encoding="utf-8")) if d]
    notes_override = sys.argv[3] if len(sys.argv) > 3 else ""
    notes_default = sys.argv[4] if len(sys.argv) > 4 else ""
    if not docs:
        print("   [ERROR] the render produced no documents; nothing was checked.")
        return 1

    fail = False
    # Word-boundary, so an unrelated word merely CONTAINING those letters is not
    # a hit while the release token itself is.
    tok = re.compile(rf"(^|[^A-Za-z0-9]){re.escape(rel)}($|[^A-Za-z0-9])")

    # --- VERBATIM -----------------------------------------------------------
    # The default must be `.Release.Name` UNCHANGED. Assertion 1 in the shell
    # cannot see this: it diffs two renders that both pass through the helper, so
    # `| trunc N` applied to the default cancels out on both sides. Measured --
    # a mutation adding `trunc 3` to the helper survived that diff.
    verbatim = [
        f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
        for d in default_docs
        if isinstance((d.get("metadata") or {}).get("name"), str)
        and tok.search(d["metadata"]["name"])
    ]
    if not verbatim:
        fail = True
        print(
            f"   [ERROR] with the override UNSET, no resource name contains the release "
            f"name {rel!r} whole. The default is not '.Release.Name' verbatim — a "
            f"truncating or normalising helper renames every existing install."
        )
    else:
        print(f"   [OK] {len(verbatim)} resource name(s) carry the release name verbatim when unset")

    # --- classify every token-bearing scalar, once ---------------------------
    licensed = {CLS_INSTANCE: [], CLS_ANNOTATION: [], CLS_ENV: [], CLS_PATH: []}
    unrouted = []
    scanned = 0
    for d in docs:
        where = f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
        envs = env_value_paths(d)
        for path, val in walk(d):
            if not isinstance(val, str):
                continue
            scanned += 1
            if not tok.search(val):
                continue
            cls = classify(d, path, val, rel, ns, envs)
            if cls is None:
                unrouted.append((where, path, val))
            else:
                licensed[cls].append((where, path, val, envs.get(path, "")))

    # FAIL CLOSED. Zero scalars scanned agrees with every assertion below, and a
    # walk that stopped walking is indistinguishable from a clean chart.
    if scanned == 0:
        print("   [ERROR] walked 0 string scalars — the walk sees nothing, so nothing was checked.")
        return 1

    # --- MOVED --------------------------------------------------------------
    if unrouted:
        fail = True
        print(
            f"   [ERROR] {len(unrouted)} value(s) still carry the release name {rel!r} "
            f"under fullnameOverride={ovr!r}, and no exception licenses them — each is "
            f"an unrouted site:"
        )
        for where, path, val in sorted(unrouted)[:20]:
            snippet = val if len(val) <= 90 else val[:87] + "..."
            print(f"             {where}  {path} = {snippet!r}")
        if len(unrouted) > 20:
            print(f"             ... and {len(unrouted) - 20} more")
    else:
        print(
            f"   [OK] no unrouted value carries the release name "
            f"({scanned} string scalars across {len(docs)} documents)"
        )

    # --- STAYED -------------------------------------------------------------
    expected = {CLS_INSTANCE: rel, CLS_ANNOTATION: rel, CLS_ENV: None, CLS_PATH: None}
    for cls, found in licensed.items():
        if not found:
            # CANNOT TELL IS A FINDING — but for the PATH class the scope of that
            # finding is the CHART, not the profile (Bugbot, High; demoted after
            # measuring). The only release-scoped path on a cloud profile is the
            # Collector's queue directory, which renders because
            # `telemetryCollector` is on by chart DEFAULT and no `client/ci`
            # profile sets it. A profile that disabled it — entirely plausible now
            # the gate is tri-state (backend#1906) — would have no release-scoped
            # path at all, and a per-profile check would then refuse a complete
            # chart.
            #
            # MEASURED AT HEAD, so the finding as filed does not reproduce: aks 1,
            # bm 4, eks 1, oc 1. The concern is real and the failure is not, so the
            # emptiness is REPORTED here and asserted once ACROSS profiles by the
            # shell, which is the only layer that sees all four.
            if cls is CLS_PATH:
                print(
                    f"   [note] no {cls} in this profile — legitimate when neither "
                    f"hostPath nor the Collector renders. Asserted across profiles, "
                    f"not here."
                )
                print("PATHCLASS 0")
                continue
            if cls is CLS_ENV:
                # SAME DEMOTION AS CLS_PATH, and it was already half-made
                # (Bugbot Medium; reproduced by @saadqbal). The identity-env block
                # below ALREADY treats per-profile emptiness as legitimate and
                # prints `ENVCLASS 0` — but this arm set `fail = True` first, so
                # that half could never rescue the run. On aks with autoUpgrade,
                # imageRefresh and sealCheck.storageAssertions all off: 41
                # documents, 0 identity envs, sidecar exit 1, and BOTH messages in
                # one output — an [ERROR] saying the class proves nothing, then a
                # note saying the emptiness is fine. A required drift guard
                # refusing a complete chart.
                #
                # NO `ENVCLASS 0` HERE, deliberately, and this is the part the
                # one-line "extend the demotion" fix would get wrong. The shell
                # parses `grep -E '^ENVCLASS [0-9]+$' | head -1`, and the
                # identity-env block below prints the REAL count unconditionally.
                # Printing one here too would make `head -1` read this zero and
                # discard the true value — turning a cross-profile assertion into
                # one that always sees 0. CLS_PATH can print its count because its
                # two branches are mutually exclusive within this loop; CLS_ENV's
                # count is owned by the block below.
                print(
                    f"   [note] no {cls} in this profile — legitimate when neither "
                    f"the CronJobs nor the storage-assertions Job renders. Counted "
                    f"and asserted across profiles below, not here."
                )
                continue
            print(
                f"   [ERROR] found NO {cls} carrying the release name — the class matches "
                f"nothing, so its half of this assertion proves nothing."
            )
            fail = True
            continue
        if cls is CLS_PATH:
            # A DIFFERENT PREDICATE, and the difference is the point: a path is
            # not the release name, it merely contains it. The property is that
            # it did not FOLLOW the override.
            #
            # FIRST, THOUGH: every member must actually BE a path. This class is
            # the only one whose obligation a non-path can satisfy by accident —
            # the other three demand the value equal a release identity, so a
            # mis-classified value fails there, while "did not follow the
            # override" is true of any unrouted name. So a broadened allowlist
            # here would silently swallow unrouted sites out of MOVED and report
            # nothing. Measured: a mutation returning CLS_PATH for every
            # unclassified value left the guard green.
            notpath = [f for f in found if not f[2].startswith("/")]
            if notpath:
                fail = True
                print(
                    f"   [ERROR] {len(notpath)} value(s) classified as an on-disk path "
                    f"are not paths, so MOVED is not seeing them:"
                )
                for where, path, val, _ in sorted(notpath)[:10]:
                    print(f"             {where}  {path} = {val!r}")
            followed = [f for f in found if ovr in f[2]]
            if followed:
                fail = True
                print(f"   [ERROR] {len(followed)} {cls} followed the override:")
                for where, path, val, _ in sorted(followed):
                    print(f"             {where}  {path} = {val!r}")
            else:
                print(f"   [OK] {len(found)} release-scoped path(s) kept the release name")
            # A MACHINE-READABLE COUNT for the cross-profile assertion in the
            # shell. Printed on both branches so a profile that HAS paths and a
            # profile that has none are distinguishable there.
            print(f"PATHCLASS {len(found)}")
            continue
        want = expected[cls]
        if cls is CLS_ENV:
            bad = [f for f in found if f[2] not in (rel, ns)]
        else:
            bad = [f for f in found if f[2] != want]
        if bad:
            fail = True
            print(f"   [ERROR] {len(bad)} {cls} value(s) are not the release identity:")
            for where, path, val, name in sorted(bad)[:10]:
                print(f"             {where}  {name or path} = {val!r}")
        else:
            print(f"   [OK] {len(found)} {cls} value(s) still carry the release identity")

    # --- EVERY IDENTITY ENV SITE SURVIVED, not just the class ----------------
    # See identity_env_sites: a routed site vanishes from the class instead of
    # failing it, so the class-level check above is blind to exactly the
    # regression backend#2620 describes.
    want_sites = identity_env_sites(default_docs, rel, ns, rel)
    have_sites = identity_env_sites(docs, rel, ns, ovr)
    # PER-PROFILE EMPTINESS IS NOT A CHART FINDING, on the same terms as the PATH
    # class above. A profile that renders neither CronJob nor the
    # storage-assertions Job has no identity env, and failing here would refuse a
    # complete chart -- the mistake the PATH class already made and had demoted
    # after measuring. So the count goes out machine-readably and the shell
    # asserts it once ACROSS profiles, which is the only layer that sees all four.
    # Measured at head: aks 5, bm 5, eks 5, oc 5.
    if not want_sites:
        print(
            "   [note] the DEFAULT render names no helm-identity env in this profile "
            "— legitimate when neither CronJob nor the storage-assertions Job "
            "renders. Asserted across profiles, not here."
        )
        print("ENVCLASS 0")
    else:
        missing = sorted(want_sites - have_sites)
        if missing:
            fail = True
            print(
                f"   [ERROR] {len(missing)} helm-identity env site(s) present with the "
                f"override UNSET no longer carry the release identity under "
                f"fullnameOverride={ovr!r} — routed away, not merely changed:"
            )
            for kind, name, env in missing:
                print(f"             {kind}/{name}  {env}")
        else:
            print(
                f"   [OK] all {len(want_sites)} helm-identity env site(s) still carry "
                f"the release identity, site by site"
            )
        print(f"ENVCLASS {len(want_sites)}")

        # AND EACH NAME MUST CARRY ITS OWN IDENTITY, which the set comparison
        # above cannot see. `identity_env_sites` accepts a value in (rel, ns) for
        # any of the three names, so swapping RELEASE_NAME with
        # RELEASE_NAMESPACE keys the same triple on both sides and passes -- a
        # consumer reading RELEASE_NAME would get the namespace. Checked here
        # against the name's own meaning, which is assertable only because this
        # profile deliberately makes rel and ns differ
        # (`relnamelongenoughtocatchatruncation38` vs `tracebloc`); under the
        # installer's own one-string-for-both convention (backend#2621) it would
        # not be.
        #
        # A `valueFrom` env has no literal to read. That is not a pass: it is a
        # site this text-level check cannot see, and saying so is the finding
        # (rule 3). It also drops silently out of both sets above, so this is the
        # only place it is reported at all.
        env_expected = {"RELEASE_NAME": rel, "RELEASE": rel, "RELEASE_NAMESPACE": ns}
        assert set(env_expected) == RELEASE_ENV, (
            "env_expected and RELEASE_ENV disagree: a name in one and not the "
            "other is either an unchecked env or a check for an env that does "
            "not exist"
        )
        swapped, unreadable = [], []
        for d in docs:
            where = f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
            envs = env_value_paths(d)
            if not envs:
                continue
            values = {path: val for path, val in walk(d) if isinstance(val, str)}
            for vpath, ename in envs.items():
                if ename not in RELEASE_ENV:
                    continue
                if vpath not in values:
                    unreadable.append((where, vpath, ename))
                elif values[vpath] != env_expected[ename]:
                    swapped.append((where, ename, values[vpath]))
        if unreadable:
            fail = True
            print(
                f"   [ERROR] {len(unreadable)} helm-identity env(s) carry no literal "
                f"value, so neither this check nor the site comparison above can "
                f"read them:"
            )
            for where, vpath, ename in sorted(unreadable):
                print(f"             {where}  {ename} at {vpath}")
        if swapped:
            fail = True
            print(
                f"   [ERROR] {len(swapped)} helm-identity env(s) carry an identity "
                f"that is not the one they name:"
            )
            for where, ename, val in sorted(swapped):
                print(
                    f"             {where}  {ename} = {val!r} "
                    f"(expected {env_expected[ename]!r})"
                )
        elif not unreadable:
            print(
                f"   [OK] each helm-identity env carries the identity it names "
                f"(RELEASE_NAME/RELEASE={rel!r}, RELEASE_NAMESPACE={ns!r})"
            )

    # --- NOTES --------------------------------------------------------------
    # A SEPARATE RENDER, because `helm template` does not emit NOTES.txt at all
    # (measured on the CI-pinned v3.15.4: `--show-only templates/NOTES.txt`
    # answers "could not find template"). The shell half therefore renders it
    # with `helm install --dry-run=client`, which works with no cluster.
    #
    # WHY IT IS WORTH A FOURTH ASSERTION. NOTES is the first thing anyone sees
    # after an install, and it was half-routed seven lines apart: L6 printed
    # `rel-jobs-manager` while L13 printed `zzoverride-jobs-manager`, under one
    # override. That is exactly the mixed render this guard's own rationale calls
    # worse than a badly-named release, in the one output an operator reads
    # (Asad, review of backend#2626).
    if notes_override and notes_default:
        try:
            over_txt = strip_ansi(open(notes_override, encoding="utf-8").read())
            def_txt = strip_ansi(open(notes_default, encoding="utf-8").read())
        except OSError as exc:
            print(f"   [ERROR] could not read the rendered NOTES ({exc}) — not checked.")
            return 1
        if not tok.search(def_txt):
            # Vacuity guard: if the DEFAULT notes never mention the release name,
            # "the override notes do not" is true of an empty file.
            print(
                "   [ERROR] the default NOTES never mentions the release name, so the "
                "override check below proves nothing. Did NOTES stop naming resources?"
            )
            fail = True
        # The instance-label line is the one legitimate carrier, and it is
        # allowlisted by its own text rather than by a path — free text has no
        # path. Narrow on purpose: only a line that is showing the operator the
        # selector `app.kubernetes.io/instance=<release>`.
        offenders = [
            ln.strip()
            for ln in over_txt.splitlines()
            if tok.search(ln) and "app.kubernetes.io/instance=" not in ln
        ]
        if offenders:
            fail = True
            print(
                f"   [ERROR] {len(offenders)} NOTES line(s) print the release name under "
                f"fullnameOverride={ovr!r}, so the install message names resources that "
                f"do not exist:"
            )
            for ln in offenders[:10]:
                print(f"             {ln[:110]}")
        else:
            print("   [OK] NOTES prints no stale release name under the override")
    else:
        # NOT SILENTLY SKIPPED. A guard that quietly checks three things when it
        # documents four is the shape this whole file exists to prevent.
        print("   [ERROR] no rendered NOTES was passed, so NOTES was not checked at all.")
        fail = True

    # --- 5. the class behind the credential-Secret finding -------------------
    # The parser this rests on is self-tested first: if it cannot read a helper
    # body, everything below reads as safe.
    ok, msgs = selftest_the_parser()
    for m in msgs:
        print(m)
    if not ok:
        fail = True

    ok, msgs = selftest_the_fallback_detector()
    for m in msgs:
        print(m)
    if not ok:
        fail = True

    ok, msgs = selftest_the_refusal_detector()
    for m in msgs:
        print(m)
    if not ok:
        fail = True

    ok, msgs = assert_lookup_keys()
    for m in msgs:
        print(m)
    if not ok:
        fail = True

    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
