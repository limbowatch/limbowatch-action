#!/usr/bin/env bash
# Part of the Limbowatch action (action.yml): runs the scan and hands its results to GitHub (annotations, job summary,
# outputs). Inputs arrive as LW_* environment variables; LW_MODE (from install.sh) says image or python.
set -eu
tmp="${RUNNER_TEMP:-/tmp}"
box="$tmp/limbowatch"   # the scan's own directories: home, cache, out (its results for this script)
out="$box/out"
rm -rf "$out" "$box/reports"  # an earlier step's, in one job
mkdir -p "$box/home" "$box/cache" "$out"

# A file the scan wrote, safe for this script to read: a regular file, not a symlink to one of the runner's.
is_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
# Copy the regular files under $1 to $2. Symlinks are skipped, not followed, and find doesn't descend into
# symlinked directories.
copy_files() {
  (cd "$1" && find . -type f -print0) | while IFS= read -r -d '' f; do
    mkdir -p "$2/$(dirname "$f")" && cp -- "$1/$f" "$2/$f"
  done
}
REPORT_FILES="report.json report.md report.html report.sarif report.csv cyclonedx.json"
# Copy what the image wrote into the reports directory back to it ($1 to $2). The image may be compromised and later
# steps may run what's in the checkout, so only regular files directly in the directory, no dotfiles, no names with a
# control character, never onto a symlink or a file git tracks. Any such file only when git can read the directory
# and tracks nothing in it (a directory for reports alone); otherwise, as for `reports: .`, only the report files.
copy_back() {
  local from="$1" to="$2" only="$REPORT_FILES" listed
  if listed="$(git -C "$to" ls-files -- . 2>/dev/null)" && [ -z "$listed" ]; then only=""; fi
  (cd "$from" && find . -mindepth 1 -maxdepth 1 -type f -print0) | while IFS= read -r -d '' f; do
    f="${f#./}"
    case "$f" in *[[:cntrl:]]* | .*) continue ;; esac
    if [ -n "$only" ]; then case " $only " in *" $f "*) ;; *) continue ;; esac; fi
    if [ -L "$to/$f" ] || { [ -e "$to/$f" ] && [ ! -f "$to/$f" ]; }; then continue; fi
    # exit 1 is "not tracked"; 0 is tracked, and anything else means git couldn't tell
    local rc=0
    git -C "$to" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 1 ] && { [ "$rc" = 0 ] || [ -z "$only" ]; }; then
      echo "::warning title=Limbowatch::The scan wrote a file the repository tracks in the reports directory; it wasn't copied."
      continue
    fi
    cp -- "$from/$f" "$to/$f"
  done
}

reports_dir=""     # image mode: where the image's reports are copied to afterwards
rep="$LW_REPORTS"  # where the scan writes them
if [ "${LW_MODE:-python}" = "image" ]; then
  # Isolated: a compromised image must not be able to reach the runner. So it never sees the runner's temp
  # directory (GITHUB_ENV, GITHUB_PATH and GITHUB_OUTPUT are files there, and writing them runs code in later
  # steps). The checkout is read-only, so it can't change files that later steps run. Its root filesystem is
  # read-only, it has no capabilities, and it gets no new privileges. It writes only to its own directories, and
  # this script copies regular files out of them. Paths are the same inside and out. It runs as the runner's
  # user, so this script can read and remove what it writes.
  ws="${GITHUB_WORKSPACE:-$PWD}"
  mounts=(-v "$ws:$ws:ro" -v "$box/home:$box/home" -v "$box/cache:$box/cache" -v "$out:$out")
  if [ -n "$LW_REPORTS" ]; then
    # The reports directory is the one place in the checkout the scan can write (extra-args can put --state,
    # --audit-log or more -o files there). The image writes to a directory of its own mounted over it, and what it
    # wrote is copied back afterwards.
    mkdir -p "$LW_REPORTS" "$box/reports"
    reports_dir="$(cd "$LW_REPORTS" && pwd)"
    case "$ws/:$PWD/" in
      "$reports_dir"/*|*:"$reports_dir"/*)
        # the checkout itself, or above it: mounting over it would hide the project, so the reports are written
        # in the scan's own directory and only they are copied out
        rep="$box/reports"
        mounts+=(-v "$box/reports:$box/reports") ;;
      *)
        copy_files "$reports_dir" "$box/reports"   # a --state file kept there by an earlier run
        mounts+=(-v "$box/reports:$reports_dir") ;;
    esac
  fi
  # Workflow commands are off while the image runs: nothing it prints can set an output or end this step's
  # grouping. The token is random and the image never sees it.
  token="limbowatch-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  run() {
    local rc=0
    echo "::stop-commands::$token"
    docker run --rm -i --user "$(id -u):$(id -g)" \
      --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --pids-limit 1024 \
      -e HOME="$box/home" "${mounts[@]}" -w "$PWD" \
      -e LIMBOWATCH_GITHUB_TOKEN -e GITHUB_TOKEN -e LIMBOWATCH_ISSUES_TOKEN -e NVD_API_KEY -e LIMBOWATCH_VERIFY_FEED -e LIMBOWATCH_FEED -e LIMBOWATCH_ALLOW_INSECURE_HTTP \
      -e LIMBOWATCH_AUDIT_LOG -e LIMBOWATCH_SHOW_NETWORK \
      -e CI -e GITHUB_ACTIONS -e GITHUB_REPOSITORY -e GITHUB_SERVER_URL -e GITHUB_API_URL -e NO_COLOR -e FORCE_COLOR \
      "$LW_IMAGE" "$@" || rc=$?
    echo "::$token::"
    return "$rc"
  }
else
  run() { "$@"; }
fi

set -- --cache "$box/cache" --fail-on "$LW_FAIL_ON" \
       -o table -o "json=$out/limbowatch.json" -o "markdown=$out/limbowatch.md" -o "github=$out/limbowatch.annotations"
[ "$LW_FAIL_ON_UNKNOWN" = "true" ] || set -- "$@" --no-fail-on-unknown
[ -z "$LW_SARIF" ] || set -- "$@" -o "sarif=$out/limbowatch.sarif"
if [ -n "$LW_REPORTS" ]; then
  set -- "$@" -o "json=$rep/report.json" -o "markdown=$rep/report.md" -o "html=$rep/report.html" \
         -o "sarif=$rep/report.sarif" -o "csv=$rep/report.csv" -o "cyclonedx=$rep/cyclonedx.json"
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
# shellcheck disable=SC2086 # LW_EXTRA is a list of options; set -f passes a * or ? in it as typed
set -f
run limbowatch scan "$LW_PATH" "$@" $LW_EXTRA || status=$?
set +f
[ -z "$reports_dir" ] || copy_back "$box/reports" "$reports_dir"
if [ -n "$LW_SARIF" ] && is_file "$out/limbowatch.sarif"; then
  mkdir -p "$(dirname "$LW_SARIF")" && cp -- "$out/limbowatch.sarif" "$LW_SARIF"
fi
# exit 2 with a report: the scan ran but issues couldn't be updated; its findings are still shown
if is_file "$out/limbowatch.json"; then
  if [ "$LW_ANNOTATIONS" = "true" ] && is_file "$out/limbowatch.annotations" && [ -s "$out/limbowatch.annotations" ]; then
    echo "::group::Annotations: one per affected package"
    # annotation commands only, one per line
    grep -E '^::(error|warning|notice) [^:]*::' "$out/limbowatch.annotations" || true
    echo "::endgroup::"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && is_file "$out/limbowatch.md"; then cat "$out/limbowatch.md" >> "$GITHUB_STEP_SUMMARY"; fi
  # outputs, then the verdict again as the step's last line, below the annotations
  # it prints nothing itself, and workflow commands stay off while it runs, as for the scan
  run python3 - "$out/limbowatch.json" "$out/limbowatch.outputs" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
gate = doc["gate"]
with open(sys.argv[2], "w") as f:
    f.write(f"findings={doc['summary']['findings']}\nfailing={gate['failing_findings']}\n")
    f.write(f"failed={'true' if gate['failed'] else 'false'}\n")
    f.write("verdict=" + ("FAILED" if gate["failed"] else "PASSED") + "  " + " ".join(gate["message"].split()) + "\n")
PY
  if is_file "$out/limbowatch.outputs"; then
    # only well-formed values reach GITHUB_OUTPUT: a number, true or false
    grep -E '^(findings|failing)=[0-9]+$|^failed=(true|false)$' "$out/limbowatch.outputs" >> "$GITHUB_OUTPUT" || true
    [ -z "$LW_REPORTS" ] || echo "report=$LW_REPORTS/report.json" >> "$GITHUB_OUTPUT"
    # a line that starts with PASSED or FAILED can't be a workflow command
    sed -nE 's/^verdict=((PASSED|FAILED)  .*)$/\1/p' "$out/limbowatch.outputs" | head -1
  fi
fi
if [ "$status" = 1 ] && [ "$LW_ALLOW_FAILURE" = "true" ]; then
  echo "::warning title=Limbowatch::Findings at or above fail-on; allow-failure is on, so the step passes."
  status=0
fi
exit "$status"
