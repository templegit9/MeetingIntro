#!/bin/bash
# Developer-only. Build first, then pass that exact binary. No installed-app UI is opened.
set -euo pipefail
binary=${1:?Usage: scripts/eval-margin.sh /path/to/MeetingIntro [report-directory]}
report_dir=${2:-docs/evals/margin/run-$(date -u +%Y%m%dT%H%M%SZ)}
if [[ ! -x "$binary" ]]; then echo "Not executable: $binary" >&2; exit 2; fi
if [[ -e "$report_dir/results.json" || -e "$report_dir/run-info.json" ]]; then
  echo "Refusing to overwrite an existing eval run: $report_dir" >&2; exit 2
fi
mkdir -p "$report_dir"
python3 - "$report_dir/run-info.json" <<'PYMETA'
import datetime, json, os, sys
from pathlib import Path
now = datetime.datetime.now(datetime.timezone.utc)
Path(sys.argv[1]).write_text(json.dumps({"started_at": now.isoformat(), "local_started_at": now.astimezone().isoformat(), "finished_at": None, "exit_code": None, "learning_checks": os.getenv("MARGIN_LEARNING_SELFTEST") == "1", "filter": os.getenv("MARGIN_EVAL_MATCH"), "context_only": os.getenv("MARGIN_EVAL_CONTEXT_ONLY") == "1"}, indent=2))
PYMETA
git rev-parse HEAD > "$report_dir/base-commit.txt"
git diff --stat > "$report_dir/working-tree.txt"
shasum -a 256 "$binary" > "$report_dir/binary-sha256.txt"
set +e
MARGIN_FIXTURES=1 MARGIN_EVAL_REPORT="$report_dir/results.json" "$binary" 2>&1 | tee "$report_dir/run.log"
eval_status=${PIPESTATUS[0]}
set -e
python3 - "$report_dir/run-info.json" "$eval_status" <<'PYMETA'
import datetime, json, sys
from pathlib import Path
p = Path(sys.argv[1]); data = json.loads(p.read_text())
data.update(finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), exit_code=int(sys.argv[2]))
p.write_text(json.dumps(data, indent=2))
PYMETA
python3 scripts/render-margin-eval.py "$(dirname "$report_dir")"
exit "$eval_status"
