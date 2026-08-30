"""Assertions 2 and 3 of the fullnameOverride guard — backend#2626.

Split out of `fullname-override-completeness.sh` rather than embedded as a
heredoc so it can be read, linted and reasoned about; the shell half only
renders and loops profiles.

Reads ONE rendered manifest, produced with `fullnameOverride` set to something
distinctive, and answers two opposite questions about it:

  MOVED   no resource name may still carry the release name
  STAYED  every exception must still carry it

Both are required. Checking only the first is satisfied by renaming Helm's own
bookkeeping and the env var `helm rollback` reads.
"""

from __future__ import annotations

import os
import re
import sys

import yaml


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


def main() -> int:
    rel = os.environ["RELEASE"]
    ns = os.environ["NS"]
    ovr = os.environ["OVERRIDE"]
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
    default_docs = [d for d in yaml.safe_load_all(open(sys.argv[2], encoding="utf-8")) if d]
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
    #
    # So look at the default render directly and require the release name to
    # appear WHOLE in the names built from it. A truncating or normalising helper
    # fails here even though it renders self-consistently.
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

    # --- MOVED --------------------------------------------------------------
    missed = [
        f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
        for d in docs
        if isinstance((d.get("metadata") or {}).get("name"), str)
        and tok.search(d["metadata"]["name"])
    ]
    if missed:
        fail = True
        print(
            f"   [ERROR] {len(missed)} resource name(s) still carry the release name "
            f"{rel!r} under fullnameOverride={ovr!r} — each is an unrouted site:"
        )
        for m in sorted(missed):
            print(f"             {m}")
    else:
        print(f"   [OK] no resource name carries the release name ({len(docs)} documents)")

    # --- STAYED: values that ARE the release name ---------------------------
    exact = {
        "app.kubernetes.io/instance label": ([], rel),
        "meta.helm.sh/release-name annotation": ([], rel),
        "RELEASE_NAME / RELEASE env (a Helm identity)": ([], rel),
        "RELEASE_NAMESPACE env": ([], ns),
    }
    for d in docs:
        where = f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
        for path, val in walk(d):
            if not isinstance(val, str):
                continue
            if path.endswith(".app.kubernetes.io/instance"):
                exact["app.kubernetes.io/instance label"][0].append((where, path, val))
            elif path.endswith(".meta.helm.sh/release-name"):
                exact["meta.helm.sh/release-name annotation"][0].append((where, path, val))
        # env vars are name/value SIBLINGS, so the key is not on the value's path
        for path, val in walk(d):
            if not path.endswith(".name") or not isinstance(val, str):
                continue
            key = {
                "RELEASE_NAME": "RELEASE_NAME / RELEASE env (a Helm identity)",
                "RELEASE": "RELEASE_NAME / RELEASE env (a Helm identity)",
                "RELEASE_NAMESPACE": "RELEASE_NAMESPACE env",
            }.get(val)
            if not key:
                continue
            sibling = path.rsplit(".name", 1)[0] + ".value"
            for p2, v2 in walk(d):
                if p2 == sibling:
                    exact[key][0].append((where, val, v2))

    for label, (found, expected) in exact.items():
        if not found:
            # CANNOT TELL IS A FINDING. An empty list agrees with every
            # expectation, so a selector that stops matching would read as a pass.
            print(
                f"   [ERROR] found NO {label} to check — the selector matches nothing, "
                f"so this assertion proves nothing."
            )
            fail = True
            continue
        bad = [f for f in found if f[2] != expected]
        if bad:
            fail = True
            print(
                f"   [ERROR] {len(bad)} {label} value(s) followed the override; they "
                f"must stay {expected!r}:"
            )
            for where, p, v in sorted(bad)[:10]:
                print(f"             {where}  {p} = {v!r}")
        else:
            print(f"   [OK] {len(found)} {label} value(s) still {expected!r}")

    # --- STAYED: on-disk paths ---------------------------------------------
    # A DIFFERENT PREDICATE, and the difference is the point. The checks above
    # compare for equality because a label or a Helm-identity env IS the release
    # name. A path is not: `/proc` and `/var/log/pods` never referenced the
    # release, and `/var/lib/tracebloc/<release>/telemetry` merely contains it.
    # Demanding equality reported those unscoped paths as regressions — the first
    # cut of this guard did exactly that. The real property is that no path may
    # FOLLOW the override, because a path is a location: renaming it orphans a
    # tenant's data rather than moving it.
    paths = [
        (f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}", path, val)
        for d in docs
        for path, val in walk(d)
        if isinstance(val, str)
        and (path.endswith(".hostPath.path") or (path.endswith(".path") and val.startswith("/")))
    ]
    if not paths:
        print("   [ERROR] found NO on-disk paths to check — selector matches nothing.")
        fail = True
    else:
        followed = [p for p in paths if ovr in p[2]]
        scoped = [p for p in paths if tok.search(p[2])]
        if followed:
            fail = True
            print(
                f"   [ERROR] {len(followed)} on-disk path(s) followed the override. A "
                f"path is a LOCATION, not a name — renaming it orphans a tenant's "
                f"data rather than moving it:"
            )
            for where, p, v in sorted(followed):
                print(f"             {where}  {p} = {v!r}")
        elif not scoped:
            # Vacuity guard: "none followed the override" is also true of a chart
            # that stopped scoping paths by release at all.
            print(
                "   [ERROR] no on-disk path is release-scoped, so 'none followed the "
                "override' proves nothing. Did the release-scoped paths disappear?"
            )
            fail = True
        else:
            print(
                f"   [OK] {len(scoped)} release-scoped path(s) kept the release name; "
                f"{len(paths) - len(scoped)} unscoped path(s) untouched"
            )

    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
