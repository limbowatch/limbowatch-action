# Limbowatch

[![Release](https://img.shields.io/github/v/release/limbowatch/limbowatch-action?include_prereleases&label=release)](https://github.com/limbowatch/limbowatch-action/releases)
[![Self-test](https://github.com/limbowatch/limbowatch-action/actions/workflows/self-test.yml/badge.svg)](https://github.com/limbowatch/limbowatch-action/actions/workflows/self-test.yml)
[![GitHub Marketplace](https://img.shields.io/badge/GitHub_Marketplace-limbowatch-2088ff?logo=github)](https://github.com/marketplace/actions/limbowatch)
[![License](https://img.shields.io/github/license/limbowatch/limbowatch-action)](https://github.com/limbowatch/limbowatch-action/blob/main/LICENSE)


Find dependencies affected by security advisories **in limbo**: published by their maintainers on GitHub, but not yet reviewed into the GitHub Advisory Database or OSV, so Dependabot, `npm audit`, OSV-Scanner and most other scanners can't see them yet. In October 2026, about 1 in 6 advisories behind 15 popular projects was in limbo, and the median wait for review was 23 days ([report](https://github.com/limbowatch/limbowatch/tree/main/research/2026-10-state-of-the-gap)).

The action reads your lockfiles, checks every package against the [live limbo feed](https://limbo.watch/feed/), annotates each finding on its lockfile line, writes a job summary and reports, and can fail the build.

> **Alpha.** Release 0.1.0a13. Options and formats may change before 0.1.0.

## Usage

```yaml
on: [push, pull_request]
permissions:
  contents: read
jobs:
  limbowatch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: limbowatch/limbowatch-action@v0.1.0a13
        with:
          fail-on: high
```

With GitHub code scanning (public repos, or private ones with GitHub Code Security):

```yaml
permissions:
  contents: read
  security-events: write   # for the SARIF upload
  actions: read            # the upload action needs it in private repos
steps:
  - uses: actions/checkout@v4
  - uses: limbowatch/limbowatch-action@v0.1.0a13
    with:
      fail-on: high
      sarif: limbowatch.sarif
  - if: always()
    uses: github/codeql-action/upload-sarif@v4
    with: { sarif_file: limbowatch.sarif, category: limbowatch }
```

Keep the reports, or act on the result in later steps:

```yaml
  - uses: limbowatch/limbowatch-action@v0.1.0a13
    id: limbo
    with: { fail-on: none }
  - if: steps.limbo.outputs.findings != '0'
    uses: actions/upload-artifact@v4
    with: { name: limbowatch-report, path: limbowatch-report/ }
```

Keep one issue per finding up to date in a private repo (opened, commented on as the advisory moves, closed when you upgrade), with the job's own token. Issues are written on a push to the default branch, a schedule or a manual run (never from a pull request), never in a public repo, and at most 50 new ones a run. The `concurrency` group keeps two runs from overlapping: GitHub lists a new issue a few seconds late.

```yaml
on: { push: { branches: [main] }, schedule: [{ cron: "17 6 * * *" }] }
permissions: { contents: read, issues: write }
concurrency: limbowatch
jobs:
  limbowatch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: limbowatch/limbowatch-action@v0.1.0a13
        with: { fail-on: none, issues: github }
```

**Gitea and Forgejo Actions:** `uses: https://github.com/limbowatch/limbowatch-action@v0.1.0a13`. With `issues: gitea` and a `LIMBOWATCH_ISSUES_TOKEN` secret, it opens and updates one issue per finding on a push to the default branch, a schedule or a manual run (never in a public repo).

## How it runs

On a Linux runner with Docker, it runs the Limbowatch image, pinned by digest and attested by the [Limbowatch repository](https://github.com/limbowatch/limbowatch). On macOS or Windows, or when the job runs in a container, it installs Limbowatch with pip from the same release (Python 3.12 or later, e.g. `actions/setup-python`), every dependency checked against the hashes in [requirements.txt](requirements.txt), and OSV-Scanner checked against its SHA-256 sums. `install: auto | image | python` picks one explicitly.

Exit codes: 0 passed, 1 a finding meets `fail-on`, 2 the scan couldn't run. `allow-failure: true` passes the step with a warning when findings meet `fail-on`; a scan that couldn't run still fails.

## Security and data

The action runs in your job; it doesn't upload files or source code.

- **Reads** your lockfiles and SBOMs (OSV-Scanner, offline) and, for C/C++, the build files that declare upstream sources.
- **Sends** package names and versions to public services (deps.dev, Maven Central, GitHub, CVE Services, OSV) to find out whether a dependency is affected. limbo.watch learns nothing: the feed is downloaded whole. With `extra-args: --no-upstream --no-resolve-maven`, the scan contacts limbo.watch and nothing else, at the cost of the checks those lookups make.
- **Needs** no secrets and only `permissions: contents: read`. It gets a token only when `issues` is set.
- **Verify it:** pin `uses:` to a commit SHA; the default image is pinned by digest and attested (`gh attestation verify oci://ghcr.io/limbowatch/limbowatch:<tag> --owner limbowatch`).
- **Lock it down:** check out only the dependency files (sparse checkout), or pass your own SBOM with `extra-args: --sbom <file>`; run it in a job of its own; allow only the hosts you chose with an egress filter.

Every host, what it receives and the option that turns it off: [Security and data](https://github.com/limbowatch/limbowatch/blob/main/docs/WATCHER.md#security-and-data).

## Inputs

| Input | Default | What it does |
|---|---|---|
| `path` | `.` | Project directory to scan. |
| `fail-on` | `low` | Fail for findings at or above this severity: `critical`, `high`, `medium`, `low`, `none`. |
| `fail-on-unknown` | `true` | Also fail for findings with no severity. |
| `allow-failure` | `false` | Pass the step with a warning when findings meet `fail-on`. |
| `sarif` | | Write SARIF to this file, for GitHub code scanning. |
| `annotations` | `true` | Annotate each finding on its lockfile line in the pull request. |
| `reports` | `limbowatch-report` | Directory for report.json, report.md, report.html, report.sarif, report.csv and cyclonedx.json; empty for none. |
| `issues` | | `github` (needs `permissions: issues: write`) or `gitea` (Gitea or Forgejo): open and update issues in this repo on a push to the default branch, a schedule or a manual run. Never in a public repo unless `extra-args` has `--issues-public`. |
| `issues-token` | | Token that can write issues here (pass a secret); for `github`, the job's token by default. A personal token's user needs write access: GitHub drops a new issue's labels otherwise, so nothing is opened and the step says why. |
| `extra-args` | | More `limbowatch scan` options. |
| `install` | `auto` | `image`, `python` or `auto`. |
| `image` | the release's image | The Limbowatch image, pinned by digest. |
| `osv-scanner-version` | `2.7.1` | OSV-Scanner release for `install: python`. |
| `limbowatch-source` | GitHub archives | Where `<ref>.tar.gz` source archives are served, for `install: python`. |
| `limbowatch-ref` | `v0.1.0a13` | Limbowatch release tag to install with `install: python`. |

## Outputs

| Output | Meaning |
|---|---|
| `findings` | Findings that aren't accepted (ignored). |
| `failing` | Findings at or above `fail-on`. |
| `failed` | `"true"` if the scan failed the `fail-on` gate. |
| `report` | Path of the JSON report (schema_version 1), when `reports` is set. |

## More

- Guide and all options: [docs/WATCHER.md](https://github.com/limbowatch/limbowatch/blob/main/docs/WATCHER.md)
- GitLab: the same scan as a CI/CD component, in the [GitLab CI/CD Catalog](https://gitlab.com/explore/catalog/limbowatch/limbowatch-component)
- [limbo.watch](https://limbo.watch): the live tracker, the [limbo feed](https://limbo.watch/feed/) (OSV records) and a [package checker](https://limbo.watch/check/)
- Issues and source: [limbowatch/limbowatch](https://github.com/limbowatch/limbowatch). This repository is a copy of its `integrations/action/`, made at each release; send changes there.

Advisory data from published GitHub repository security advisories and the GitHub Advisory Database (CC BY 4.0). Code: Apache-2.0.
