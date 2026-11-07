#!/usr/bin/env bash
# Part of the Limbowatch action (action.yml): downloads OSV-Scanner (checksum-verified) and installs Limbowatch into its own venv. Inputs arrive as LW_* environment variables.
set -eu
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported $(uname -m)"; exit 2 ;; esac
bin="${RUNNER_TEMP:-/tmp}/limbowatch-bin"
mkdir -p "$bin"
python3 - "$LW_OSV_VERSION" "$arch" "$bin/osv-scanner" <<'PY'
import hashlib, sys, urllib.request
ver, arch, dest = sys.argv[1:]
base = f"https://github.com/google/osv-scanner/releases/download/v{ver}/"
name = f"osv-scanner_linux_{arch}"
sums = urllib.request.urlopen(base + "osv-scanner_SHA256SUMS", timeout=60).read().decode()
want = next(line.split()[0] for line in sums.splitlines() if line.endswith(" " + name))
data = urllib.request.urlopen(base + name, timeout=300).read()
if hashlib.sha256(data).hexdigest() != want:
    sys.exit(f"checksum mismatch for {name}")
open(dest, "wb").write(data)
PY
chmod +x "$bin/osv-scanner"
echo "$bin" >> "$GITHUB_PATH"
python3 -m venv "$bin/venv"
src="${LW_SOURCE}/${LW_REF}.tar.gz"
"$bin/venv/bin/pip" install --quiet --disable-pip-version-check \
  "limbowatch @ ${src}#subdirectory=packages/core" "limbowatch-cli @ ${src}#subdirectory=packages/cli"
ln -sf "$bin/venv/bin/limbowatch" "$bin/limbowatch"
