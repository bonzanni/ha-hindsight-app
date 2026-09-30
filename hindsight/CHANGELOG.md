# Changelog

## 0.5.0

Update Hindsight from upstream v0.7.1 to v0.10.2. This spans three upstream
minor releases with many database migrations, which run automatically on
first start. **Take a Home Assistant backup of the add-on before updating.**

Upstream highlights relevant to this add-on:

- Recall: facts without an explicit event date now rank by when they were
  mentioned, instead of getting a neutral recency score, so newer memories
  outrank stale ones. The recency decay is configurable via
  `HINDSIGHT_API_RECENCY_DECAY_FUNCTION` (linear/exponential/none).
- New recall options: `prefer_observations`, `min_scores`,
  `temporal_window`. Results carry a per-stage `scores` object and
  `mentioned_at`.
- Recalls and reflects are cancelled when the client disconnects.
- Consolidation no longer creates duplicate observations, and its internal
  recalls skip the neural reranker natively.
- Whole-bank export/import for migrating between instances.
- The control plane drops the locale slug from URLs.

Add-on changes:

- New options `recency_decay`, `recency_halflife_days` and
  `recency_linear_window_days` control how memory age nudges recall ranking.
  **The add-on defaults to `exponential` decay with a 30-day half-life,
  not upstream's `linear` 365-day curve.** Upstream's curve separates facts a
  week apart by only about 0.4%, which is too little to reliably order a
  fact that changed recently. See DOCS for the trade-off, and set `linear` /
  `365` to match upstream exactly.
- Rebased both local patches onto v0.10.2. The bounded worker drain is
  unchanged. The reranker busy-degrade now uses upstream's native RRF ranking
  path. The consolidation reranker passthrough was removed because upstream
  now does this itself.
- The 18s recall deadline now covers the whole request, from arrival to
  response. v0.10 does work before and after the search: bank-alias lookups,
  an admission queue, and attachment lookups after every recall. A deadline
  around the search alone let a recall answer late, past the consumer's 20s
  budget. Timed-out requests show as 504 in the HTTP metrics, and a search
  cut off by the deadline is counted as a failed operation. A request that
  times out while queued for admission gives its slot back. Upstream leaked
  it, which would slowly shrink recall capacity until a restart.
- Upstream's new recall admission queue is limited to a 1s wait, down from
  30s. When the server is at capacity, a recall gets a fast 503 with
  `Retry-After` instead of an 18s timeout.
- Node 20 (end of life) is replaced by Node 24, matching upstream.
- Token counting uses upstream's bundled tokenizer, so the tiktoken cache is
  no longer shipped.
- The consolidation worker-slot setting was renamed to the non-deprecated
  `HINDSIGHT_API_WORKER_CONSOLIDATION_RESERVED_SLOTS`. The value is
  unchanged. It reserves a minimum number of slots and never capped
  consolidation.

## 0.4.2

Repository renamed to https://github.com/bonzanni/ha-hindsight-app (was
bonzanni/hindsight-ha-app; GitHub redirects the old URL, but new installs
should use the new one). Updated the OCI source label, the release
pipeline's label and signature-identity checks, and the documented store
URL to match. No functional changes to the add-on itself.

## 0.4.1

Raise the recall handler deadline from 15s to 18s. Live measurement of v0.4.0
showed the second admitted reranker recall in a burst completing at ~14.5s —
only half a second under the old deadline, so ordinary CPU jitter could still
turn it into a timeout. 18s keeps failures arriving as fast typed errors while
staying safely below consumers' 20s client budget. No image content changes
beyond this environment value.

## 0.4.0

Interactive recalls no longer time out en masse when background consolidation
runs or several recalls arrive at once. On low-power hosts the local reranker
is a single serialized lane (~6.5s per recall on an Intel N150), and both
consolidation's internal recalls and concurrent bursts could queue interactive
recalls past the 15s deadline (HTTP 504 for 75–80% of recalls during
consolidation windows).

- Consolidation's internal recalls now skip the neural reranker and use
  retrieval-fusion (RRF) ordering, so background batches no longer occupy the
  reranker lane interactive recalls depend on. Consolidation already runs at
  its own low recall budget and tolerates this ordering by design.
- A recall that would wait behind two or more unfinished reranker jobs now
  falls back to RRF ordering instead of queueing toward a certain timeout:
  slightly coarser ranking, but an answer instead of an error.
- Both behaviors ship as a new upstream patch (`rerank-contention.patch`),
  env-gated (`HINDSIGHT_API_CONSOLIDATION_RECALL_RERANKER`,
  `HINDSIGHT_API_RERANKER_BUSY_PASSTHROUGH_THRESHOLD`) and enabled in the
  image; unset, upstream behavior is unchanged. Build-time asserts verify the
  patch applied.

Updating preserves Supervisor options and the existing `/data` PostgreSQL
volume.

## 0.3.0

Hindsight now installs from prebuilt, Cosign-signed GHCR images instead of
compiling the hybrid image on the Home Assistant host.

- Publish `ghcr.io/bonzanni/hindsight:<version>` and `latest` through a generic
  OCI manifest. The release remains amd64-only; aarch64 needs a separate port
  of the pinned upstream artifacts.
- Add a versioned-main GitHub Actions release pipeline: pull requests validate
  the amd64 hybrid build, while a version bump merged to `main` publishes and
  verifies the signed image before creating the matching git tag and GitHub
  Release from this changelog section.
- Add OCI and Home Assistant image metadata, the current HA app linter, action
  dependency maintenance, and checks tying the manifest version to the image
  and release tag.
- Keep ingress on its Home Assistant default port 8099 while removing the
  redundant manifest value, and replace obsolete Supervisor `watchdog`
  metadata with the current Docker `HEALTHCHECK` against the same `/health`
  endpoint. API port 8888 and health supervision remain in place.
- Let the smoke and Playwright ingress harnesses consume an exact prebuilt
  image through `TEST_IMAGE`, while retaining direct local `docker build`
  testing and the pinned `base-debian:trixie` hybrid Dockerfile.
- Strengthen AppArmor validation to require both signal directions and add a
  real HAOS acceptance/reproducer procedure for the Supervisor compiled-profile
  cache defect. The app profile is not broadened and the container never
  mutates host AppArmor state.

Updating from 0.2.2 preserves Supervisor options and the existing `/data`
volume, including pg0 memory data.

## 0.2.2

No functional change from 0.2.1 — a version bump whose sole purpose is to make
the Supervisor re-run its AppArmor profile load.

Background: 0.2.1's correct `signal (send,receive)` profile was stored and
validated by the Supervisor, but the host kept enforcing the old send-only
profile. Root cause was a stale AppArmor **compile cache** on the host
(`/data/apparmor/cache/<kernel-features>/5884eb17_hindsight`): the running
kernel loaded a months-old send-only binary and never recompiled from the
updated text, so update/restart/reinstall/reboot all failed to apply the fix.
Clearing the stale cache entries plus an add-on update (which is the only
operation that reliably re-invokes `apparmor_parser`) forces a recompile from
the corrected text. See the AppArmor note in `apparmor.txt`.

## 0.2.1

Fix the real cause of the SIGKILL-on-stop (exit 137) that 0.2.0's shutdown
tuning did not resolve. The AppArmor profile granted `signal (send)` but not
`signal (receive)`. Every add-on process (s6-supervise, start-all.sh, the API,
pg0) runs inside the one `hindsight` profile, and AppArmor checks a signal at
both ends — so a send-only rule made the kernel return EPERM to the sender and
SIGTERM never reached `start-all.sh`. On stop, s6 could not signal the app;
nothing shut down until the Supervisor's kill grace expired (137), which is why
nightly cold backups always ended in a hard kill. Confirmed on-device: even
`docker exec -u root … kill -TERM <start-all pid>` returned "Operation not
permitted". The fix is `signal (send,receive)` in `apparmor.txt`; the 0.2.0
grace/drain/`timeout` changes are correct and now actually take effect, giving
a clean ~10s stop. (The 0.2.0 smoke test missed this because a plain
`docker run` is unconfined — no AppArmor profile is applied.)

- `make lint` now syntax-validates `apparmor.txt` with `apparmor_parser` and
  asserts the signal rule permits `receive`, so a send-only regression can't
  ship again.

## 0.2.0

Recall latency + graceful shutdown, tuned for low-power (N150-class) hosts.
Measured on-device at 0.1.1: one recall reranked 300 candidates in ~6.3s idle
(96% of handler time); two concurrent recalls degraded superlinearly to ~25s
each (thread oversubscription), silently blowing consumers' 20s client budget
— the server kept working on requests whose callers had already disconnected.

- Rerank depth capped at 100 candidates (was 300) — the cross-encoder now
  scores the RRF top-100. ~3x less CPU per recall; final results still
  token-filtered the same way.
- Cross-encoder calls serialized (`RERANKER_LOCAL_MAX_CONCURRENT=1`) and
  upstream's quality-identical length-bucketed batching enabled; OpenMP idle
  spinning disabled (`OMP_WAIT_POLICY=PASSIVE`). Kills the superlinear
  collapse under concurrency.
- New recall handler deadline (patched into the pinned upstream API,
  `HINDSIGHT_API_RECALL_HANDLER_TIMEOUT=15`): a recall that cannot finish in
  15s returns 504 immediately instead of overrunning the caller's timeout
  invisibly. No more accepted-but-never-answered requests.
- Background consolidation limited to one worker slot so it can no longer
  gang up with interactive recalls on the 4 cores.
- Clean SIGTERM: worker drain is now bounded (8s, patched-in
  `HINDSIGHT_API_WORKER_SHUTDOWN_TIMEOUT`), `S6_KILL_GRACETIME` dropped from
  30s to 5s (s6 sat out the full 30s *after* services had already stopped
  cleanly — the container could never stop within the Supervisor's default
  10s grace, so every nightly cold backup ended in SIGKILL/137), and the
  add-on now declares `timeout: 60` as extra headroom for loaded shutdowns.
  Measured stop time: 35s → ~9s.
- Smoke test now asserts the recall deadline returns 504 and that
  `docker stop` exits 0 (clean shutdown) — guards both regressions.

## 0.1.1

- Fix the in-sidebar UI: opening a memory bank no longer 404s. The upstream
  control-plane is built with an empty Next.js basePath, so its App Router
  emitted root-absolute navigation/RSC URLs that escaped Home Assistant's
  dynamic ingress prefix. The control-plane is now rebuilt from the pinned
  upstream source with a placeholder basePath, which nginx rewrites to the live
  ingress path; client `fetch()` and public-asset paths are rewritten too.
- Add the Hindsight brand icon (`icon.png`) and logo (`logo.png`); README now
  shows the control-plane UI.

## 0.1.0

- Initial release: Hindsight agent memory (API + control-plane UI + embedded
  pg0) as a Home Assistant add-on. Local embeddings/reranker, OpenRouter
  reasoning LLM, in-sidebar ingress, memory persisted under /data.
