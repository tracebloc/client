#!/usr/bin/env bash
#
#  telemetry-token-agreement.sh — the writer, the reader and the RBAC all name the
#  SAME Secret, in the same namespace, under the same key (backend#2274).
#
#  WHY THIS EXISTS. Four documents describe one credential:
#
#    * jobs-manager's env      — TELEMETRY_TOKEN_SECRET_{NAMESPACE,NAME,KEY}, the WRITER
#    * the Collector's volume  — secretName, the READER
#    * the Collector's config  — bearertokenauth.filename, which encodes the KEY
#    * a Role + RoleBinding    — resourceNames, and which ServiceAccount may use it
#
#  Any one of them disagreeing produces the same symptom: nothing. The Collector
#  mounts the Secret `optional: true` ON PURPOSE — a missing token must buffer to
#  disk, not CrashLoopBackOff on every customer node — so a wrong name, a wrong
#  namespace, a wrong key and a Role bound to the wrong ServiceAccount are ALL
#  indistinguishable from "not deployed yet". The DaemonSet is Ready, the metrics
#  are quiet, and no records exist.
#
#  That is why the reader holds no defaults of its own (the chart passes all three
#  values) and why this compares the rendered documents rather than trusting them.
#
#  DERIVED IN EVERY DIRECTION. No Secret name, namespace, key or ServiceAccount is
#  written down here. Everything is read out of one render and compared.
#
#  FAILS CLOSED. A missing document is a finding: comparing values you could not
#  find would report agreement between two absences.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== telemetry token agreement =="

CMP="$(mktemp -t tok-agree.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys, posixpath

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
if not docs:
    sys.exit("[ERROR] the chart rendered nothing")

writer = {}          # from jobs-manager's env
writer_sa = None
reader_secret = None
reader_ns = None
mount_path = None
auth_filename = None
role = None
bound_sas = set()

for d in docs:
    kind = d.get("kind")
    if kind == "Deployment":
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            for e in c.get("env") or []:
                if e.get("name", "").startswith("TELEMETRY_TOKEN_SECRET_"):
                    writer[e["name"]] = e.get("value")
                    writer_sa = (d["spec"]["template"]["spec"].get("serviceAccountName"), 
                                 d["metadata"].get("namespace", ""))
    elif kind == "DaemonSet" and "telemetry" in d["metadata"]["name"]:
        reader_ns = d["metadata"].get("namespace", "")
        for v in d["spec"]["template"]["spec"].get("volumes") or []:
            if "secret" in v:
                reader_secret = v["secret"].get("secretName")
                for c in d["spec"]["template"]["spec"].get("containers") or []:
                    for m in c.get("volumeMounts") or []:
                        if m.get("name") == v["name"]:
                            mount_path = m.get("mountPath")
    elif kind == "ConfigMap" and "telemetry-collector" in d["metadata"]["name"]:
        cfg = yaml.safe_load(d["data"]["config.yaml"])
        auth_filename = ((cfg.get("extensions") or {}).get("bearertokenauth") or {}).get("filename")
    elif kind == "Role" and d["metadata"]["name"].endswith("-token"):
        role = d
    elif kind == "RoleBinding" and d["metadata"]["name"].endswith("-token"):
        for s in d.get("subjects") or []:
            bound_sas.add((s.get("name"), s.get("namespace", "")))

# --- fail closed on anything we could not locate -----------------------------
missing = [n for n, v in (
    ("jobs-manager's TELEMETRY_TOKEN_SECRET_* env", writer or None),
    ("the Collector DaemonSet's token volume", reader_secret),
    ("the Collector's bearertokenauth.filename", auth_filename),
    ("the token Role", role),
    ("the token RoleBinding's subjects", bound_sas or None),
) if not v]
if missing:
    sys.exit("[ERROR] could not locate: " + "; ".join(missing)
             + " — comparing values that were not found would report agreement "
               "between absences")

problems = []

# 1. the NAME, across writer / reader / RBAC
names = {
    "jobs-manager env": writer.get("TELEMETRY_TOKEN_SECRET_NAME"),
    "Collector volume": reader_secret,
}
scoped = [r for r in role.get("rules") or [] if r.get("resourceNames")]
if not scoped:
    problems.append("the token Role has no name-scoped rule at all — `get`/`patch` "
                    "would cover every Secret in the namespace")
else:
    for r in scoped:
        for n in r["resourceNames"]:
            names[f"Role resourceNames ({','.join(r.get('verbs') or [])})"] = n
if len(set(names.values())) != 1:
    problems.append("the Secret NAME disagrees across documents: "
                    + ", ".join(f"{k}={v!r}" for k, v in sorted(names.items())))

# 2. the NAMESPACE
nss = {
    "jobs-manager env": writer.get("TELEMETRY_TOKEN_SECRET_NAMESPACE"),
    "Collector DaemonSet": reader_ns,
    "token Role": role["metadata"].get("namespace", ""),
}
if len(set(nss.values())) != 1:
    problems.append("the NAMESPACE disagrees: "
                    + ", ".join(f"{k}={v!r}" for k, v in sorted(nss.items())))

# 3. the KEY. With no `items` on the volume, the Secret's keys project as files
#    named by key, so the Collector's credential file is <mountPath>/<key>.
if mount_path and auth_filename:
    derived_key = posixpath.basename(auth_filename)
    derived_dir = posixpath.dirname(auth_filename)
    if derived_dir.rstrip("/") != (mount_path or "").rstrip("/"):
        problems.append(f"bearertokenauth reads {auth_filename!r} but the Secret is "
                        f"mounted at {mount_path!r} — the Collector would read a "
                        "path nothing projects to")
    if derived_key != writer.get("TELEMETRY_TOKEN_SECRET_KEY"):
        problems.append(f"the KEY disagrees: the Collector reads {derived_key!r} "
                        f"(from {auth_filename!r}) but jobs-manager writes "
                        f"{writer.get('TELEMETRY_TOKEN_SECRET_KEY')!r}")

# 4. the RoleBinding must bind the ServiceAccount that actually writes.
if writer_sa and writer_sa not in bound_sas:
    problems.append(f"the token RoleBinding does not bind the writer: jobs-manager "
                    f"runs as {writer_sa} but the binding covers {sorted(bound_sas)} "
                    "— the create would 403 and the Collector would buffer forever")

print(f"   secret     {sorted(set(names.values()))[0]}")
print(f"   namespace  {sorted(set(nss.values()))[0]}")
print(f"   key        {posixpath.basename(auth_filename)}")
print(f"   writer sa  {writer_sa[0]} (ns {writer_sa[1]})")

if problems:
    sys.exit("[ERROR] " + "; ".join(problems))

print("  ok: writer, reader, key and RBAC all name the same Secret")
PY

helm template t "$CHART" \
  --set clientId=x --set clientPassword=y \
  --set storageClass.create=false \
  --set telemetryCollector.enabled=true 2>/dev/null | python3 "$CMP"

# ── two releases on one cluster resolve to DISTINCT Secrets (backend#2625) ──────
#
#  The agreement above proves the four documents of ONE release name the same
#  Secret. This proves the thing the ticket is actually about: two releases sharing
#  the node-agents namespace do NOT. A fixed name made both write one Secret — last
#  writer wins, and the loser's Collector authenticated as the wrong tenant.
#
#  DERIVED, like the rest of this file. It writes down no Secret name. It renders
#  two DIFFERENT release names, pulls the token name each render resolved to out of
#  the writer's own env and the reader's own volume, and asserts (1) the writer and
#  reader of each render still agree, (2) each render's name is a function of its
#  release — it contains the release name — and (3) the two names DIFFER. Point 3 is
#  the collision fix; points 1–2 stop it passing by resolving both to one constant.
NAME="$(mktemp -t tok-name.XXXXXX)"
trap 'rm -f "$CMP" "$NAME"' EXIT
cat >"$NAME" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
# Chase the references, do not match a string: the token name is whatever the
# writer was told and whatever the reader mounts, and this reports it only if the
# two agree — an empty or split render is a finding, not a silent pass.
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
writer = reader = None
for d in docs:
    kind = d.get("kind")
    if kind == "Deployment":
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            for e in c.get("env") or []:
                if e.get("name") == "TELEMETRY_TOKEN_SECRET_NAME":
                    writer = e.get("value")
    elif kind == "DaemonSet" and "telemetry" in d["metadata"]["name"]:
        for v in d["spec"]["template"]["spec"].get("volumes") or []:
            if "secret" in v:
                reader = v["secret"].get("secretName")
if not writer or not reader:
    sys.exit("[ERROR] could not locate the token name in the render "
             "(writer env / reader volume) — comparing absences would pass falsely")
if writer != reader:
    sys.exit(f"[ERROR] within one render the writer names {writer!r} but the reader "
             f"mounts {reader!r}")
print(writer)
PY

render_name() {
  helm template "$1" "$CHART" \
    --set clientId=x --set clientPassword=y \
    --set storageClass.create=false \
    --set telemetryCollector.enabled=true 2>/dev/null | python3 "$NAME"
}

rel_a="tenant-alpha"; rel_b="tenant-beta"
name_a="$(render_name "$rel_a")" || { echo "$name_a" >&2; exit 1; }
name_b="$(render_name "$rel_b")" || { echo "$name_b" >&2; exit 1; }

fail=0
case "$name_a" in *"$rel_a"*) ;; *)
  echo "[ERROR] release $rel_a resolved to $name_a, which does not scope to the release" >&2; fail=1 ;;
esac
case "$name_b" in *"$rel_b"*) ;; *)
  echo "[ERROR] release $rel_b resolved to $name_b, which does not scope to the release" >&2; fail=1 ;;
esac
if [ "$name_a" = "$name_b" ]; then
  echo "[ERROR] two releases resolved to the SAME Secret $name_a — the shared-namespace collision this ticket fixes" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || { echo "telemetry token agreement: FAILED" >&2; exit 1; }
echo "   release $rel_a -> $name_a"
echo "   release $rel_b -> $name_b"
echo "  ok: two releases resolve to distinct, release-scoped Secrets"

# --- the ACCEPTED-NAME SET, and the message that reports it -----------------
#
# `telemetryTokenPresent` ORs several lookups, and `telemetryCollectorState`
# hard-FAILS when none hits. Three names are accepted:
#
#   telemetryTokenSecretName        follows fullnameOverride  — the current one
#   telemetryTokenLegacyName        the fixed pre-#2274 name  — mid-migration
#   telemetryTokenPreOverrideName   <release>-telemetry-token — a RENAMED release
#
# The third was missing and the omission was invisible: on a release with
# fullnameOverride set, the token exists under the release-scoped name, the lookup
# missed it, and an operator who had explicitly enabled the Collector got a hard
# refusal naming two names that were never going to match (Bugbot, Medium, on
# client#911). Nothing pinned the set, so nothing would have caught it going away
# again.
#
# ASSERTED AS AN AGREEMENT, not as a list: every name the lookup accepts must
# also be NAMED IN THE REFUSAL. That is the property a human depends on — a
# message that omits a name it searched sends the reader to create a Secret that
# already exists under another name — and it is derived from the template on both
# sides, so adding a fourth name without mentioning it fails here.
helpers="client/templates/_helpers.tpl"
[ -r "$helpers" ] || { echo "[ERROR] cannot read $helpers — refusing to report agreement" >&2; exit 2; }

accepted="$(grep -oE 'include "tracebloc\.telemetryToken[A-Za-z]*Name"' "$helpers" \
            | sed -E 's/.*"tracebloc\.(telemetryToken[A-Za-z]*Name)".*/\1/' | sort -u)"
[ -n "$accepted" ] || { echo "[ERROR] found ZERO telemetry-token name helpers — the matcher sees nothing" >&2; exit 2; }

# The `or (lookup …)` chain, on one line by construction.
chain="$(grep -E 'if or \(lookup "v1" "Secret"' "$helpers" || true)"
[ -n "$chain" ] || { echo "[ERROR] could not find the telemetryTokenPresent lookup chain" >&2; exit 2; }
# The refusal, which must report every name the chain searched.
msg="$(grep -E 'telemetryCollector\.enabled is true but its token Secret' "$helpers" || true)"
[ -n "$msg" ] || { echo "[ERROR] could not find the token refusal message" >&2; exit 2; }

# PLACEHOLDERS COUNTED AGAINST ARGUMENTS, not "the name appears on the line".
# The first cut did the latter, and the `fail (printf "…" args)` call has the name
# helpers in its ARGUMENT list on the same line as the format string — so deleting
# a `%q` from the message left the include in the args, the substring still
# matched, and the check stayed green while the refusal reported one name fewer
# than it searched. Found by mutation-proving.
#
# An argument with no placeholder is silently dropped by printf, which is exactly
# the failure being guarded: a name searched and not reported.
set_fail=0
mismatch="$(python3 scripts/tests/telemetry_token_refusal_arity.py "$helpers")"
if [ -n "$mismatch" ]; then
  echo "[ERROR] $mismatch" >&2
  set_fail=1
else
  echo "  ok: the refusal reports every argument it is given"
fi
for n in $accepted; do
  case "$chain" in *"$n"*) ;; *) continue ;; esac      # not in the chain -> not our business
  case "$msg" in
    *"$n"*) echo "   accepted and passed to the refusal: $n" ;;
    *) echo "[ERROR] the lookup accepts $n but the refusal is not even given it" >&2
       set_fail=1 ;;
  esac
done
case "$chain" in
  *telemetryTokenPreOverrideName*) echo "  ok: a renamed release's pre-override token name is still accepted" ;;
  *) echo "[ERROR] telemetryTokenPresent no longer accepts the pre-fullnameOverride name" >&2
     echo "        (<release>-telemetry-token). A renamed release with the Collector" >&2
     echo "        explicitly enabled will hard-fail with the token sitting right there." >&2
     set_fail=1 ;;
esac
[ "$set_fail" -eq 0 ] || { echo "telemetry token agreement: FAILED" >&2; exit 1; }

echo "telemetry token agreement: green"
