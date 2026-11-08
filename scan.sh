#!/usr/bin/env bash
# Part of the Limbowatch action (action.yml): runs the scan and hands its results to GitHub (annotations, job summary,
# outputs). Inputs arrive as LW_* environment variables; LW_MODE (from install.sh) says image or python.
set -eu
tmp="${RUNNER_TEMP:-/tmp}"
if [ "${LW_MODE:-python}" = "image" ]; then
  # The workspace and the runner's temp directory are mounted at the same paths, so every path means the same
  # inside and out. The runner's user, so files it writes aren't owned by root (self-hosted runners clean up).
  ws="${GITHUB_WORKSPACE:-$PWD}"
  mkdir -p "$tmp/limbowatch-home"
  run() {
    docker run --rm -i --user "$(id -u):$(id -g)" -e HOME="$tmp/limbowatch-home" \
      -v "$ws:$ws" -v "$tmp:$tmp" -w "$PWD" \
      -e LIMBOWATCH_GITHUB_TOKEN -e GITHUB_TOKEN -e LIMBOWATCH_ISSUES_TOKEN -e NVD_API_KEY \
      -e CI -e GITHUB_ACTIONS -e GITHUB_REPOSITORY -e GITHUB_SERVER_URL -e NO_COLOR -e FORCE_COLOR \
      "$LW_IMAGE" "$@"
  }
else
  run() { "$@"; }
fi

set -- --cache "$tmp/limbowatch-cache" --fail-on "$LW_FAIL_ON" \
       -o table -o "json=$tmp/limbowatch.json" -o "markdown=$tmp/limbowatch.md" -o "github=$tmp/limbowatch.annotations"
[ "$LW_FAIL_ON_UNKNOWN" = "true" ] || set -- "$@" --no-fail-on-unknown
[ -z "$LW_SARIF" ] || set -- "$@" -o "sarif=$LW_SARIF"
if [ -n "$LW_REPORTS" ]; then
  set -- "$@" -o "json=$LW_REPORTS/report.json" -o "markdown=$LW_REPORTS/report.md" -o "html=$LW_REPORTS/report.html" \
         -o "sarif=$LW_REPORTS/report.sarif" -o "csv=$LW_REPORTS/report.csv" -o "cyclonedx=$LW_REPORTS/cyclonedx.json"
fi
branch="${GITHUB_REF_NAME:-}"
if [ "$LW_ISSUES" = "gitea" ] && { [ "$branch" = "$LW_DEFAULT_BRANCH" ] || [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; }; then
  set -- "$@" --issues gitea
fi
status=0
# shellcheck disable=SC2086 # LW_EXTRA is a list of options
run limbowatch scan "$LW_PATH" "$@" $LW_EXTRA || status=$?
if [ "$status" -le 1 ] && [ -f "$tmp/limbowatch.json" ]; then
  if [ "$LW_ANNOTATIONS" = "true" ] && [ -s "$tmp/limbowatch.annotations" ]; then
    echo "::group::Annotations: one per affected package"
    cat "$tmp/limbowatch.annotations"
    echo "::endgroup::"
  fi
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$tmp/limbowatch.md" >> "$GITHUB_STEP_SUMMARY"
  # outputs, then the verdict again as the step's last line, below the annotations
  run python3 - "$tmp/limbowatch.json" "$tmp/limbowatch.outputs" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
gate = doc["gate"]
with open(sys.argv[2], "w") as out:
    out.write(f"findings={doc['summary']['findings']}\nfailing={gate['failing_findings']}\n")
    out.write(f"failed={'true' if gate['failed'] else 'false'}\n")
print(("FAILED" if gate["failed"] else "PASSED") + "  " + gate["message"])
PY
  cat "$tmp/limbowatch.outputs" >> "$GITHUB_OUTPUT"
  [ -z "$LW_REPORTS" ] || echo "report=$LW_REPORTS/report.json" >> "$GITHUB_OUTPUT"
fi
if [ "$status" = 1 ] && [ "$LW_ALLOW_FAILURE" = "true" ]; then
  echo "::warning title=Limbowatch::Findings at or above fail-on; allow-failure is on, so the step passes."
  status=0
fi
exit "$status"
