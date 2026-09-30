# Hindsight for Home Assistant

Hindsight is an agent memory add-on for Home Assistant. It gives AI agents a
persistent, queryable memory store backed by a local vector database and an
embedded PostgreSQL instance. Agents call the Hindsight API to retain facts and
to recall them later; Hindsight handles embedding, storage, and reasoning
entirely on your Home Assistant host.

## Requirements

- **Architecture**: amd64
- **RAM**: 2 GB minimum; 4 GB recommended when the reranker is enabled
- **Storage**: 1 GB base + data growth
- **OpenRouter account**: Required — get a key at https://openrouter.ai

Hindsight is amd64-only. The pinned upstream image, copied CPython/native
wheels, and embedded ML assets do not currently provide an aarch64 build.

## Installation and updates

Home Assistant installs the prebuilt, Cosign-signed
`ghcr.io/bonzanni/hindsight:<version>` image. It does not build the Dockerfile
on the Home Assistant host. Versioned releases and `latest` are generic OCI
manifest references that currently resolve to the single supported platform,
`linux/amd64`.

Updating from `0.2.2` to `0.3.0` changes the delivery mechanism only. Existing
options remain managed by Supervisor and all Hindsight/pg0 state remains under
the same `/data` volume, so the update does not reset memory or configuration.

## Configuration

### OpenRouter API Key (required)

- **openrouter_api_key**: Your OpenRouter API key. Hindsight uses OpenRouter
  for its reasoning steps (fact extraction on retain, dialectic reasoning on
  recall). The add-on will not start without a valid key.

### Reasoning Model

- **llm_model**: OpenRouter model ID used for all reasoning steps. Default is
  `google/gemini-2.5-flash`, which balances speed and cost well for most
  workloads. Change this to any model available on OpenRouter.
- **llm_reasoning_effort**: Effort hint passed to models that support it.
  `low` (default) is fastest; `medium` and `high` trade latency for more
  thorough reasoning. Ignored by models that do not support the hint.

### Performance Toggles

- **reranker_enabled**: When `true` (default), Hindsight runs a local
  cross-encoder model to rerank candidates before returning recall results.
  This improves recall quality at the cost of a small latency increase.
  Disable on low-power hosts where the extra compute is unacceptable.
- **enable_ui**: When `true` (default), Hindsight serves a control-plane
  memory-browser UI accessible from the Home Assistant sidebar. Disable for a
  headless, API-only deployment; this reduces the add-on's memory footprint
  slightly.

### Recall Recency

Hindsight nudges recall ranking by memory age. The nudge is small and bounded:
the reranker's relevance score is multiplied by at most ±10% (fresh memories
up, old ones down), so recency mostly decides between memories that are about
equally relevant. The typical case is the same fact at two points in time
("the thermostat is set to 19°C" vs "… 21°C"), which the reranker scores
identically.

- **recency_decay**: `exponential` (default), `linear`, or `none`.
- **recency_halflife_days**: For `exponential`, the age at which a memory is
  neutral (no boost or penalty). Default `30`.
- **recency_linear_window_days**: For `linear`, the number of days over which
  the boost falls to its floor. Default `365`.

The add-on default differs from upstream's (`linear`, 365 days). Under
upstream's curve, facts one week apart differ by only about 0.4%, which is
often less than the reranker's noise between two phrasings of the same fact,
and anything older than about 330 days ties exactly. An exponential curve with
a 30-day half-life gives about 2.7% between 1 and 8 days old and about 8.6%
between 7 and 37 days old, and keeps even old memories ordered. The cost is
that a durable fact from several months ago sits up to about 20% below a very
recent memory of similar relevance. It is still returned, just ranked lower
among near-ties. For a slower, more even effect choose `exponential` with 90
days, or `linear` with 365 days to match upstream exactly.

Recency cannot fix a stale fact that the reranker clearly prefers. For
example, "the provider is Enel" can outscore "switched to Octopus" by about
30%. Use `prefer_observations` and the dates returned with each recall result
for that case.

### Logging

- **log_level**: Controls application log verbosity. One of `debug`, `info`
  (default), `warning`, `error`, or `critical`.

## Recall Latency and the `budget` Parameter

The add-on is tuned for low-power CPU-only hosts (e.g. Intel N150):

- The recall `budget` request parameter (`low`/`mid`/`high`) controls
  *retrieval breadth* — how many candidates each retrieval method fetches
  (100/300/1000).
- Reranking depth is capped separately at **100 candidates** (the RRF
  top-100), regardless of `budget`. On a grown memory bank all budgets
  therefore cost roughly the same in rerank CPU; pick `budget` by how wide
  you want retrieval to look, not by latency.
- A recall that cannot complete within **15 seconds** returns HTTP 504
  instead of silently overrunning. Design API clients with a timeout a few
  seconds above that (e.g. 20s) and treat 504 as "degrade now, retry later".

Expected recall latency on an N150-class host at a few-thousand-memory bank:
~2-4s, worst case under concurrent background work well below 15s.

## Sidebar UI

When `enable_ui` is enabled the Hindsight memory browser appears as a sidebar
panel (brain icon). Use it to inspect stored memories, browse the knowledge
graph, and manually delete entries. No separate browser tab is required.

## Network Access

Other Home Assistant add-ons can reach the Hindsight API on the internal Docker
network at:

```
http://hindsight:8888
```

Use this URL when configuring agent add-ons or MCP servers that need to read
from or write to Hindsight memory. The API is also optionally exposed on the
host network via port 8888 (set a host port in the add-on network configuration
to enable LAN access).

The `/health` endpoint is used by the image's Docker health check and can also
be polled by dependent add-ons to verify Hindsight is ready.

## Data Persistence and Backups

All memory data — the vector store and the embedded PostgreSQL database — is
stored under `/data` on the add-on's persistent volume. This
directory is included in Home Assistant cold backups automatically. Restore a
backup to move the entire memory store to a new host.

Maintainers performing the real-HAOS AppArmor release gate should follow
[`APPARMOR_ACCEPTANCE.md`](APPARMOR_ACCEPTANCE.md). Its host cache recovery is
an exceptional maintainer procedure, not a user troubleshooting step.
