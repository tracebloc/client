#!/usr/bin/env python3
"""Copy a Helm-managed pull Secret under an operator-owned name (backend#2571).

Step of the `dockerRegistry.create: true` -> `dockerRegistry.existingSecret`
migration. Run `regcred-preflight.sh` before and after this.

THE NEW NAME MUST NOT BE `<release>-regcred`. That is the name the chart itself
uses (`tracebloc.createdRegistrySecretName`), so on a release called `tracebloc`
the obvious choice `tracebloc-regcred` COLLIDES: applying this output would
rewrite the live Helm-managed Secret in place, strip its ownership metadata, and
break the next `helm upgrade`. Measured on a k3d rehearsal, 2026-08-31. Use
something like `tracebloc-ops-regcred`.

Reads a Secret's YAML on stdin, writes a renamed copy on stdout with every trace
of Helm ownership removed. WITHOUT this strip, Helm adopts the new Secret as part
of the release and deletes it the moment the old one is released -- so the
migration would look complete and then break the next upgrade.

The credential is never read, printed, or retyped: `.data` passes through byte
for byte. That is the point -- re-entering the PAT would put it in shell history
and argv, which is the exposure this migration removes.
"""
import sys, yaml

STRIP_META = ("uid", "resourceVersion", "creationTimestamp", "ownerReferences",
              "generation", "managedFields", "selfLink", "namespace")
STRIP_LABELS = ("app.kubernetes.io/managed-by", "helm.sh/chart",
                "app.kubernetes.io/instance", "app.kubernetes.io/version")

def main():
    if len(sys.argv) != 2:
        sys.exit("usage: regcred-copy.py <new-secret-name>   (Secret YAML on stdin)")
    new_name = sys.argv[1]
    d = yaml.safe_load(sys.stdin)
    if not isinstance(d, dict) or d.get("kind") != "Secret":
        sys.exit("stdin is not a Secret -- refusing")
    if d.get("type") != "kubernetes.io/dockerconfigjson":
        sys.exit("Secret type is %r, expected kubernetes.io/dockerconfigjson -- refusing"
                 % d.get("type"))
    if not (d.get("data") or {}).get(".dockerconfigjson"):
        sys.exit("Secret has no .dockerconfigjson payload -- refusing")
    # THE COLLISION IS ENFORCED, NOT MERELY DOCUMENTED (Bugbot on #916). The
    # docstring warns that the new name must not be the chart's own
    # `<release>-regcred`, and a rule that lives only in prose is the shape that
    # teaches the bypass: applying this output over the source rewrites the LIVE
    # Helm-managed Secret in place and strips its ownership metadata, breaking
    # the next `helm upgrade`.
    #
    # Compared against the SOURCE's own name, read from the input, rather than
    # pattern-matching "-regcred" -- so it holds whatever the chart calls its
    # Secret, and cannot drift from the chart's naming.
    source_name = ((d.get("metadata") or {}).get("name")) or ""
    if new_name == source_name:
        sys.exit(
            "the new name %r is the SOURCE Secret's own name -- refusing.\n"
            "  That is the chart's Secret. Applying this over it would rewrite the\n"
            "  live Helm-managed Secret and strip its ownership metadata, breaking\n"
            "  the next `helm upgrade`. Pick a distinct operator-owned name,\n"
            "  e.g. %r." % (new_name, source_name + "-ops" if source_name else "tracebloc-ops-regcred")
        )

    m = d["metadata"]
    for k in STRIP_META:
        m.pop(k, None)
    for k in STRIP_LABELS:
        (m.get("labels") or {}).pop(k, None)
    for k in [k for k in (m.get("annotations") or {}) if k.startswith("meta.helm.sh/")]:
        m["annotations"].pop(k)
    for k in ("labels", "annotations"):
        if k in m and not m[k]:
            m.pop(k)
    m["name"] = new_name
    d.pop("status", None)
    yaml.safe_dump(d, sys.stdout, sort_keys=False)

main()
