#!/usr/bin/env bash
# Part of the Limbowatch action (action.yml): runs the scan and hands its results to GitHub (annotations, job summary, outputs). Inputs arrive as LW_* environment variables.
set -eu
tmp="${RUNNER_TEMP:-/tmp}"
set -- --cache "$tmp/limbowatch-cache" --fail-on "$LW_FAIL_ON" \
       -o table -o "json=$tmp/limbowatch.json" -o "markdown=$tmp/limbowatch.md" -o "github=$tmp/limbowatch.annotations"
[ "$LW_FAIL_ON_UNKNOWN" = "true" ] || set -- "$@" --no-fail-on-unknown
[ -z "$LW_SARIF" ] || set -- "$@" -o "sarif=$LW_SARIF"
if [ -n "$LW_REPORTS" ]; then
  set -- "$@" -o "json=$LW_REPORTS/report.json" -o "markdown=$LW_REPORTS/report.md" -o "html=$LW_REPORTS/report.html" \
         -o "csv=$LW_REPORTS/report.csv" -o "cyclonedx=$LW_REPORTS/cyclonedx.json"
fi
branch="${GITHUB_REF_NAME:-}"
if [ "$LW_ISSUES" = "gitea" ] && { [ "$branch" = "$LW_DEFAULT_BRANCH" ] || [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; }; then
  set -- "$@" --issues gitea
fi
status=0
# shellcheck disable=SC2086 # LW_EXTRA is a list of options
limbowatch scan "$LW_PATH" "$@" $LW_EXTRA || status=$?
if [ "$status" -le 1 ] && [ -f "$tmp/limbowatch.json" ]; then
  if [ "$LW_ANNOTATIONS" = "true" ] && [ -s "$tmp/limbowatch.annotations" ]; then
    echo "::group::Annotations: one per affected package"
    cat "$tmp/limbowatch.annotations"
    echo "::endgroup::"
  fi
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$tmp/limbowatch.md" >> "$GITHUB_STEP_SUMMARY"
  python3 - "$tmp/limbowatch.json" >> "$GITHUB_OUTPUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
print(f"findings={doc['summary']['findings']}")
print(f"failing={doc['gate']['failing_findings']}")
print(f"failed={'true' if doc['gate']['failed'] else 'false'}")
PY
  # The verdict again as the step's last line, below the annotations
  python3 -c 'import json,sys;g=json.load(open(sys.argv[1]))["gate"];print(("FAILED" if g["failed"] else "PASSED")+"  "+g["message"])' "$tmp/limbowatch.json"
  [ -z "$LW_REPORTS" ] || echo "report=$LW_REPORTS/report.json" >> "$GITHUB_OUTPUT"
fi
exit "$status"
