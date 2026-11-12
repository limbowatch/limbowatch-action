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
      -e CI -e GITHUB_ACTIONS -e GITHUB_REPOSITORY -e GITHUB_SERVER_URL -e GITHUB_API_URL -e NO_COLOR -e FORCE_COLOR \
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
event="${GITHUB_EVENT_NAME:-}"
case "$LW_ISSUES" in
  "" ) ;;
  github|gitea)
    # Issues follow the default branch: a push to it, a schedule or a manual run. Never from a pull request,
    # including pull_request_target, issue_comment or workflow_run, which run on the default branch but may scan
    # a fork's files.
    if [ "$event" = schedule ] || { [ "$branch" = "$LW_DEFAULT_BRANCH" ] && { [ "$event" = push ] || [ "$event" = workflow_dispatch ]; }; }; then
      set -- "$@" --issues "$LW_ISSUES"
    else
      echo "Limbowatch: issues are updated on a push to the default branch, a schedule or a manual run; not on $event to $branch."
    fi ;;
  * ) echo "::error title=Limbowatch::issues wants github or gitea, got '$LW_ISSUES'"; exit 2 ;;
esac
status=0
rm -f "$tmp/limbowatch.json" "$tmp/limbowatch.md" "$tmp/limbowatch.annotations"  # an earlier step's, in one job
# shellcheck disable=SC2086 # LW_EXTRA is a list of options
run limbowatch scan "$LW_PATH" "$@" $LW_EXTRA || status=$?
# exit 2 with a report: the scan ran but issues couldn't be updated; its findings are still shown
if [ -f "$tmp/limbowatch.json" ]; then
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
