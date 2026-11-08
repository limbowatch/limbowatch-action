#!/usr/bin/env bash
# Part of the Limbowatch action (action.yml): sets Limbowatch up, by pulling its image or installing it with pip.
# Inputs arrive as LW_* environment variables; the chosen way is passed to scan.sh as LW_MODE.
#
# auto: the image on a Linux runner with Docker, unless the job itself runs in a container (common on Gitea and
# Forgejo runners), where mounting the workspace into a second container would point at the wrong paths.
set -eu
mode="$LW_INSTALL"
if [ "$mode" = "auto" ]; then
  if [ "$(uname -s)" = "Linux" ] && command -v docker >/dev/null 2>&1 && [ ! -f /.dockerenv ] \
     && ! grep -qsE '(docker|containerd|kubepods)' /proc/1/cgroup && docker info >/dev/null 2>&1; then
    mode=image
  else
    mode=python
  fi
fi
case "$mode" in
  image)
    echo "Limbowatch image: $LW_IMAGE"
    docker pull --quiet "$LW_IMAGE" >/dev/null
    docker run --rm "$LW_IMAGE" sh -c 'limbowatch --version && osv-scanner --version | head -1'
    ;;
  python)
    command -v python3 >/dev/null 2>&1 || { echo "install: python needs Python 3.12 or later on the runner (actions/setup-python)"; exit 2; }
    case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported $(uname -m)"; exit 2 ;; esac
    case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) os=windows ;; esac
    bin="${RUNNER_TEMP:-/tmp}/limbowatch-bin"
    mkdir -p "$bin"
    # OSV-Scanner, checked against its release's SHA-256 sums
    python3 - "$LW_OSV_VERSION" "$os" "$arch" "$bin/osv-scanner" <<'PY'
import hashlib, json, sys, time, urllib.error, urllib.request
ver, os_, arch, dest = sys.argv[1:]
base = f"https://github.com/google/osv-scanner/releases/download/v{ver}/"
api = f"https://api.github.com/repos/google/osv-scanner/releases/tags/v{ver}"
name = f"osv-scanner_{os_}_{arch}" + (".exe" if os_ == "windows" else "")

def fetch(url, timeout, accept=None):
    req = urllib.request.Request(url, headers={"Accept": accept} if accept else {})
    return urllib.request.urlopen(req, timeout=timeout).read()

def get(file, timeout):
    """A release file. GitHub's release downloads answer 502/504 now and then, sometimes for minutes while its
    API still serves the same asset: retry, then fall back to the API (the checksum is verified either way)."""
    for attempt in range(3):
        try:
            return fetch(base + file, timeout)
        except (urllib.error.URLError, TimeoutError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code < 500:
                raise
            print(f"retrying {base + file}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    asset = next(a for a in json.loads(fetch(api, 60))["assets"] if a["name"] == file)
    print(f"downloading {file} through the GitHub API", file=sys.stderr)
    return fetch(asset["url"], timeout, "application/octet-stream")

sums = get("osv-scanner_SHA256SUMS", 60).decode()
want = next(line.split()[0] for line in sums.splitlines() if line.endswith(" " + name))
data = get(name, 300)
if hashlib.sha256(data).hexdigest() != want:
    sys.exit(f"checksum mismatch for {name}")
open(dest, "wb").write(data)
PY
    chmod +x "$bin/osv-scanner"
    echo "$bin" >> "$GITHUB_PATH"
    python3 -m venv "$bin/venv"
    venv_bin="$bin/venv/bin"; [ -d "$venv_bin" ] || venv_bin="$bin/venv/Scripts"
    src="${LW_SOURCE}/${LW_REF}.tar.gz"  # both packages from the same pinned source
    "$venv_bin/python" -m pip install --quiet --disable-pip-version-check --retries 5 \
      "limbowatch @ ${src}#subdirectory=packages/core" "limbowatch-cli @ ${src}#subdirectory=packages/cli"
    echo "$venv_bin" >> "$GITHUB_PATH"
    "$venv_bin/limbowatch" --version
    ;;
  *) echo "install must be auto, image or python, not '$mode'"; exit 2 ;;
esac
echo "LW_MODE=$mode" >> "$GITHUB_ENV"
