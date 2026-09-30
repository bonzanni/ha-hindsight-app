#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Hindsight init: read HA options -> /data/hindsight/env, prep pg0, gen token.
# Supports both Supervisor (bashio) and standalone (env vars) modes.
# ==============================================================================
set -e

declare CONFIG_DIR="/data/hindsight"
declare ENV_FILE="${CONFIG_DIR}/env"
declare PG0_DIR="/data/.pg0"
mkdir -p "${CONFIG_DIR}" "${PG0_DIR}"

# pg0 + the app run as the non-root 'hindsight' user (Postgres refuses root).
chown -R hindsight:hindsight /data
chmod 700 "${PG0_DIR}"

declare SUPERVISED=false
if bashio::supervisor.ping 2>/dev/null; then
    SUPERVISED=true
fi

# --- gather config (supervised: bashio; standalone: environment) -------------
declare OPENROUTER_KEY LLM_MODEL LLM_EFFORT LOG_LEVEL RERANKER_ENABLED ENABLE_UI
declare RECENCY_DECAY RECENCY_HALFLIFE RECENCY_WINDOW WORKER_ID=""
if bashio::var.true "${SUPERVISED}"; then
    OPENROUTER_KEY=$(bashio::config 'openrouter_api_key')
    LLM_MODEL=$(bashio::config 'llm_model')
    LLM_EFFORT=$(bashio::config 'llm_reasoning_effort')
    LOG_LEVEL=$(bashio::config 'log_level')
    RERANKER_ENABLED=$(bashio::config 'reranker_enabled')
    ENABLE_UI=$(bashio::config 'enable_ui')
    # Defaults repeated here so an install updated from <0.5.0 whose stored
    # options predate these keys still gets the add-on default.
    RECENCY_DECAY=$(bashio::config 'recency_decay' 'exponential')
    RECENCY_HALFLIFE=$(bashio::config 'recency_halflife_days' '30')
    RECENCY_WINDOW=$(bashio::config 'recency_linear_window_days' '365')
    # Stable worker id for upstream's task recovery (recover_own_tasks matches
    # tasks left in 'processing' by this id). Unset, upstream defaults to
    # socket.gethostname() and warns that a container hostname may change on
    # recreation. Under the Supervisor it does not: the Supervisor names the
    # container after the app's slug, which is fixed per install. Pin exactly
    # the kernel hostname -- the value socket.gethostname() returns -- so the id
    # is byte-identical to the one earlier versions used on THIS install and no
    # in-flight task is orphaned by the switch. Nothing install-specific is
    # hardcoded here.
    WORKER_ID=$(cat /proc/sys/kernel/hostname)
else
    bashio::log.info "Not under Supervisor; using environment variables."
    OPENROUTER_KEY="${HINDSIGHT_API_LLM_API_KEY:-}"
    LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-google/gemini-2.5-flash}"
    LLM_EFFORT="${HINDSIGHT_API_LLM_REASONING_EFFORT:-low}"
    LOG_LEVEL="${HINDSIGHT_API_LOG_LEVEL:-info}"
    RERANKER_ENABLED="${RERANKER_ENABLED:-true}"
    ENABLE_UI="${ENABLE_UI:-true}"
    RECENCY_DECAY="${HINDSIGHT_API_RECENCY_DECAY_FUNCTION:-exponential}"
    RECENCY_HALFLIFE="${HINDSIGHT_API_RECENCY_DECAY_HALFLIFE_DAYS:-30}"
    RECENCY_WINDOW="${HINDSIGHT_API_RECENCY_DECAY_LINEAR_WINDOW_DAYS:-365}"
fi

if [ -z "${OPENROUTER_KEY}" ]; then
    bashio::log.fatal "OpenRouter API key is required. Set it in the add-on configuration."
    exit 1
fi

# --- reranker knob (value confirmed in RECON-NOTES.md Task 1) ------------------
# Enabled  -> local cross-encoder. Disabled -> 'rrf' (RRF passthrough; no model).
declare RERANKER_LINE
if bashio::var.true "${RERANKER_ENABLED}"; then
    RERANKER_LINE="HINDSIGHT_API_RERANKER_PROVIDER=local"
else
    RERANKER_LINE="HINDSIGHT_API_RERANKER_PROVIDER=rrf"
fi

# --- write env ----------------------------------------------------------------
{
    echo "HINDSIGHT_API_LLM_PROVIDER=openai"
    echo "HINDSIGHT_API_LLM_BASE_URL=https://openrouter.ai/api/v1"
    echo "HINDSIGHT_API_LLM_API_KEY=${OPENROUTER_KEY}"
    echo "HINDSIGHT_API_LLM_MODEL=${LLM_MODEL}"
    echo "HINDSIGHT_API_LLM_REASONING_EFFORT=${LLM_EFFORT}"
    echo "HINDSIGHT_API_HOST=0.0.0.0"
    echo "HINDSIGHT_API_PORT=8888"
    echo "HINDSIGHT_API_LOG_LEVEL=${LOG_LEVEL}"
    echo "HINDSIGHT_ENABLE_API=true"
    echo "HINDSIGHT_ENABLE_CP=${ENABLE_UI}"
    echo "HINDSIGHT_CP_DATAPLANE_API_URL=http://localhost:8888"
    echo "HINDSIGHT_API_EMBEDDINGS_PROVIDER=local"
    echo "${RERANKER_LINE}"
    echo "HINDSIGHT_API_RECENCY_DECAY_FUNCTION=${RECENCY_DECAY}"
    echo "HINDSIGHT_API_RECENCY_DECAY_HALFLIFE_DAYS=${RECENCY_HALFLIFE}"
    echo "HINDSIGHT_API_RECENCY_DECAY_LINEAR_WINDOW_DAYS=${RECENCY_WINDOW}"
    # Standalone mode: a HINDSIGHT_API_WORKER_ID from the container environment
    # already reaches the API (the env file only adds to it), so write nothing.
    if [ -n "${WORKER_ID}" ]; then
        echo "HINDSIGHT_API_WORKER_ID=${WORKER_ID}"
    fi
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
chown hindsight:hindsight "${ENV_FILE}"

if bashio::var.false "${ENABLE_UI}"; then
    bashio::log.info "Control-plane UI disabled (API-only mode); sidebar panel inactive."
fi

bashio::log.info "Hindsight init complete. Model: ${LLM_MODEL}, reranker: ${RERANKER_ENABLED}, UI: ${ENABLE_UI}, recency: ${RECENCY_DECAY}"
