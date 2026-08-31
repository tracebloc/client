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
except ModuleNotFoundError:
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
_DEFINE = re.compile(r'{{-?\s*define\s+"([^"]+)"\s*-?}}(.*?){{-?\s*end\s*-?}}', re.S)
_INCLUDE = re.compile(r'include\s+"([^"]+)"')
_SECRET_LOOKUP = re.compile(r'lookup\s+"v1"\s+"Secret"\s+\S+\s+([^\n)]*\)?)')


def helpers_following_the_override(sources):
    """Helper names whose rendered value contains `tracebloc.fullname`.

    Transitive: a helper that includes a helper that includes `fullname` follows
    the override too. Closed by iteration rather than recursion so a cyclic
    include cannot hang the guard.
    """
    bodies = {}
    for text in sources:
        for name, body in _DEFINE.findall(text):
            bodies[name] = body
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
                 follow the override — `telemetryTokenPresent`'s legacy name

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
    for line in lines:
        if line.split("#", 1)[0].count("lookup ") >= 2:
            out.add("fallback")
    return out


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
            if not have:
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
            # CANNOT TELL IS A FINDING. An empty list agrees with every
            # expectation, so a class that stops matching would read as a pass.
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
    ok, msgs = assert_lookup_keys()
    for m in msgs:
        print(m)
    if not ok:
        fail = True

    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
