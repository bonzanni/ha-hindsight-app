# Hindsight — contributor & AI-assistant guide

Hindsight is a **Home Assistant add-on**: it runs [Hindsight](https://github.com/vectorize-io/hindsight)
agent memory (REST/MCP API + Next.js control-plane UI + embedded PostgreSQL/`pg0`)
as an HA add-on, optimized for low-power amd64 hosts. The image is a **hybrid
build** — the prebuilt Python 3.11 API venv, the control-plane, and the
preloaded ML model caches are `COPY`-ed out of the digest-pinned upstream
`ghcr.io/vectorize-io/hindsight` image into an HA `base-debian:trixie` base,
supervised by **s6-overlay v3** with an **nginx** front for HA ingress.

## Where things are
- **Build:** `hindsight/Dockerfile` (hybrid COPY).
- **Upstream patches:** `hindsight/patches/*.patch` — applied with `patch -p1`
  to the COPY-ed API inside the Dockerfile (recall deadline, worker drain).
  Regenerate against the new source whenever `HINDSIGHT_IMAGE` is bumped; the
  build fails loudly if they no longer apply.
- **Add-on manifest:** `hindsight/config.yaml` (version lives here). User docs:
  `hindsight/DOCS.md`. Changelog: `hindsight/CHANGELOG.md`. AppArmor:
  `hindsight/apparmor.txt`.
- **Process model:** `hindsight/rootfs/etc/s6-overlay/` (init oneshot + app
  longrun + nginx longrun) and `hindsight/rootfs/etc/nginx/hindsight-ingress.conf`.
- **Tests:** `tests/` — `smoke.sh` (build + boot + pg0 persistence + ingress),
  `run-ingress.sh` + `ingress.spec.mjs` (Playwright ingress UI).
- **Internal engineering docs:** `docs/` — see the boundary note below.

## Build & test
Run once on a fresh checkout:
```bash
make setup        # installs the git hooks (core.hooksPath .githooks)
```
Then (both need an OpenRouter key in `OPENROUTER_KEY`):
```bash
make smoke        # build + boot: /health, pg0 persists across restart, ingress answers
make ingress      # Playwright: control-plane renders under an ingress prefix, no broken assets
make lint         # hadolint + shellcheck (via Docker)
```
Set `TEST_IMAGE=ghcr.io/bonzanni/hindsight:<version>` to make either runtime
harness pull and use that prebuilt image while skipping `docker build` (prefer
an immutable digest for release evidence). For a local build,
`hindsight/Dockerfile` is the source of truth and can be built directly with
`docker build -t hindsight-addon:dev hindsight/`; there is no `build.yaml`.
The OpenRouter key is in 1Password — `source ~/.op-token` then
`export OPENROUTER_KEY="$(op read 'op://Claude Code/66dekwvpd3g72nmztom55ivetm/credential')"`
(item "OpenRouter: ClaudeCode"; its colon title can't go in an `op://` path, so
it is referenced by ID).
Playwright runs inside the official image (the host lacks browser libs like
`libnspr4`); the ingress mimic runs in the add-on's network namespace so it
reaches the allow-listed `127.0.0.1:8099`.

## Critical build fact (don't regress)
The base MUST be `base-debian:trixie` (glibc 2.41), NOT bookworm. `pg0`
downloads a PostgreSQL 18 + pgvector bundle at runtime whose `vector.so` needs
`GLIBC_2.38`. Upstream is itself `python:3.11-slim-trixie`; the Dockerfile COPYs
upstream's `/usr/local` CPython 3.11 because trixie's *system* python is 3.13.

## Environment (WSL)
- Develop on **WSL2 on the native ext4 filesystem** (not `/mnt/c`) — needed for
  Docker perf and correct exec bits.
- **Container-bound files must be LF.** `.gitattributes` enforces `eol=lf` on
  `*.sh`, `Dockerfile`, and `hindsight/rootfs/**` — CRLF breaks shebangs and s6.
- `ls` may show `-rwxr-xr-x` on plain files — a WSL mount display artifact; git
  tracks the real mode. Don't commit spurious mode changes.

## Release flow
1. Branch from `main`.
2. Bump `version:` in `hindsight/config.yaml` and prepend an exact
   `## X.Y.Z` section to `hindsight/CHANGELOG.md`.
3. Commit `release: vX.Y.Z (<summary>)`, push, and merge after CI passes.
4. Merging to `main` auto-publishes the signed GHCR version/`latest` images,
   verifies the generic amd64 manifest, then creates `vX.Y.Z` and the GitHub
   Release from that changelog section. Do not tag manually.

The public image remains amd64-only. Do not add aarch64 to `config.yaml`, use
an `{arch}` image placeholder, or introduce legacy `build.yaml`; the upstream
CPython/native wheels and model artifacts need a separate aarch64 port first.
The HA app linter treats `ingress_port: 8099` as a redundant default and
`watchdog` as obsolete; keep nginx on 8099 and the Dockerfile `/health`
`HEALTHCHECK` instead of restoring those manifest keys.

Commit author email is the GitHub noreply (`3899230+bonzanni@users.noreply.github.com`),
not a private address — GitHub blocks pushing the private email.

## The `docs/` boundary — READ THIS
`docs/` is an **intentionally-private, separate inner git repo** (its own
`docs/.git` with the private remote `bonzanni/ha-hindsight-app-docs`). It is
**gitignored by this public add-on repo and is NEVER shipped here.** It holds
the internal design spec, implementation plan, and upstream recon notes.

- **Never `git add -f docs/` or otherwise commit `docs/` into this repo.** A
  `.githooks/pre-commit` guard refuses it; `make setup` installs that guard.
- Do **not** `git commit` inside `docs/` unless explicitly asked — it has its
  own history and remote.

## Working norms
- **Verify against whole files, not thin grep slices** — read around a symbol
  before asserting behaviour.
- Don't commit or push unless asked; if on `main`, branch first.
