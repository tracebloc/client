#!/usr/bin/env bash
#
#  collector-offsets-persisted.sh — the filelog receiver persists its read
#  offsets, to a storage extension the Collector actually loads (backend#1906).
#
#  WHY THIS EXISTS. `file_storage` backed only the exporter queue. The `filelog`
#  receiver kept its read offsets in memory, and `start_at` governs where a NEWLY
#  DISCOVERED file is read from — so after a restart every file looked new, `end`
#  won, and everything written while the Collector was down was skipped. D7's disk
#  queue covers records already ingested; nothing covered the read side, and the
#  restart-during-a-backend-outage path is exactly where both are needed.
#
#  Bugbot caught it. The comment sitting above `start_at: end` at the time
#  asserted the opposite — that the setting prevented re-reads across restarts —
#  which is why nobody looked: a wrong comment is worse than no comment, because
#  it answers the question before it gets asked (backend#1729 rule 7).
#
#  WHY A SHELL TEST AND NOT helm-unittest. The Collector's config is a YAML
#  DOCUMENT EMBEDDED IN A STRING inside the ConfigMap. helm-unittest can only
#  regex that string, and a regex for `storage: file_storage` matches the
#  exporter's queue setting just as happily as the receiver's — passing while the
#  receiver has none, which is the exact defect. Parsing is the only way to say
#  WHERE the key is.
#
#  DERIVED IN BOTH DIRECTIONS. The extension name is read out of the receiver and
#  checked against the extensions the chart declares AND the ones `service` turns
#  on — a storage extension that is configured but not enabled is silently
#  ignored by the Collector. No name is written down here.
#
#  FAILS CLOSED. A config that cannot be found or parsed is a finding, not
#  agreement.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== collector offsets persisted =="

# Temp file, not a heredoc on the pipe: `render | python3 - <<'PY'` makes the
# heredoc stdin and silently discards the render (shellcheck SC2259).
CMP="$(mktemp -t collector-offsets.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs
       if d.get("kind") == "ConfigMap" and "telemetry-collector" in d["metadata"]["name"]]
if len(cms) != 1:
    sys.exit(f"[ERROR] expected exactly one Collector ConfigMap, found {len(cms)} "
             "— cannot check what cannot be located")

cfg = yaml.safe_load(cms[0]["data"]["config.yaml"])
filelog = (cfg.get("receivers") or {}).get("filelog")
if not filelog:
    sys.exit("[ERROR] no filelog receiver in the rendered config")

storage = filelog.get("storage")
if not storage:
    sys.exit("[ERROR] the filelog receiver sets no `storage`, so read offsets live "
             "in memory only: every restart re-discovers each file, `start_at` "
             "decides afresh, and with `end` the logs written while the Collector "
             "was down are skipped with no error and no gap in the metrics")

declared = set((cfg.get("extensions") or {}).keys())
enabled = set((cfg.get("service") or {}).get("extensions") or [])
if storage not in declared:
    sys.exit(f"[ERROR] filelog persists to `{storage}`, which is not declared in "
             f"`extensions` (declared: {sorted(declared)})")
if storage not in enabled:
    sys.exit(f"[ERROR] filelog persists to `{storage}`, which is declared but NOT "
             f"listed in `service.extensions` (enabled: {sorted(enabled)}) — the "
             "Collector loads only enabled extensions, so the offsets would go "
             "nowhere")

print(f"  ok: filelog persists offsets to `{storage}` (declared and enabled), "
      f"start_at={filelog.get('start_at')!r}")
PY

helm template t "$CHART" \
  --set clientId=x --set clientPassword=y \
  --set storageClass.create=false \
  --set telemetryCollector.enabled=true 2>/dev/null | python3 "$CMP"

echo "collector offsets persisted: green"
