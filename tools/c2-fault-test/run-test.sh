#!/usr/bin/env bash
#
# End-to-end check for C2: P reports a WRITE it could not post so D stops
# waiting. Brings up prefiller + decoder + proxy in Docker, drives one
# request through, and reports what the decoder did with it.
#
#   ./run-test.sh              # fault armed on producer rank 0
#   ./run-test.sh --baseline   # no fault; proves the happy path still works
#   ./run-test.sh --keep-up    # leave the stack running for poking at
#   ./run-test.sh --no-docker  # bare processes; needs an active venv with vllm
#
# Everything lands in ./logs/. Copy that directory off the box for the PR.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL_RANK_DEFAULT=0
KEEP_UP=0
BASELINE=0
NO_DOCKER=${NO_DOCKER:-0}
for arg in "$@"; do
  case "$arg" in
    --baseline) BASELINE=1 ;;
    --keep-up)  KEEP_UP=1 ;;
    --no-docker) NO_DOCKER=1 ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

export MODEL=${MODEL:-Qwen/Qwen3-0.6B}
export PREFILL_TP=${PREFILL_TP:-1}
export DECODE_TP=${DECODE_TP:-1}
export PREFILL_GPUS=${PREFILL_GPUS:-0}
export DECODE_GPUS=${DECODE_GPUS:-1}
export PREFILL_PORT=${PREFILL_PORT:-8100}
export DECODE_PORT=${DECODE_PORT:-8200}
export PROXY_PORT=${PROXY_PORT:-8192}
export FAILURE_POLICY=${FAILURE_POLICY:-recompute}
export VLLM_IMAGE=${VLLM_IMAGE:-vllm-c2-test:local}
export HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
if [[ "$BASELINE" == "1" ]]; then
  export FAIL_RANK=""
else
  export FAIL_RANK=${FAIL_RANK:-$FAIL_RANK_DEFAULT}
fi

REPO_ROOT="$(cd ../.. && pwd -P)"
LOG_DIR="$PWD/logs"
RUN_LOG="$LOG_DIR/run.log"

compose() { docker compose "$@"; }

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }

# grep -c prints "0" *and* exits 1 when nothing matches, so a bare
# `|| echo 0` would yield "0\n0" and break every comparison below.
count_matches() {
  local n
  n=$(grep -c "$1" "$2" 2>/dev/null || true)
  echo "${n:-0}"
}

rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
: > "$RUN_LOG"

cleanup() {
  if [[ "$KEEP_UP" == "1" ]]; then
    log "--keep-up set; leaving the stack running."
    return
  fi
  log "tearing down"
  if [[ "$NO_DOCKER" == "1" ]]; then
    pkill -f toy_proxy_server.py 2>/dev/null || true
    pkill -TERM -f "vllm serve" 2>/dev/null || true
    sleep 3
    pkill -9 -f "vllm serve" 2>/dev/null || true
  else
    compose down -v >>"$RUN_LOG" 2>&1 || true
  fi
}
trap cleanup EXIT

log "model=$MODEL  P(tp=$PREFILL_TP gpu=$PREFILL_GPUS)  D(tp=$DECODE_TP gpu=$DECODE_GPUS)"
if [[ -n "$FAIL_RANK" ]]; then
  log "fault: producer tp_rank=$FAIL_RANK will post NO WRITEs"
else
  log "fault: DISABLED (baseline run)"
fi
log "decoder kv_load_failure_policy=$FAILURE_POLICY"

# --- preflight ------------------------------------------------------------
if [[ "$NO_DOCKER" == "0" ]]; then
  command -v docker >/dev/null || { echo "docker not found (try --no-docker)" >&2; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "'docker compose' plugin not found (try --no-docker)" >&2; exit 1; }
  if ! docker run --rm --gpus all "$VLLM_IMAGE" true >/dev/null 2>&1; then
    if ! docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
      log "image $VLLM_IMAGE not found; building from the repo (this takes a while)"
      docker build -f "$REPO_ROOT/docker/Dockerfile" --target vllm-openai \
        -t "$VLLM_IMAGE" "$REPO_ROOT" 2>&1 | tee -a "$LOG_DIR/build.log"
    else
      echo "image exists but 'docker run --gpus all' failed; is the NVIDIA container runtime installed?" >&2
      exit 1
    fi
  fi
else
  command -v vllm >/dev/null || {
    echo "vllm not on PATH. Activate the venv you installed it into, e.g.:" >&2
    echo "  source /workspace/vllm/.venv/bin/activate" >&2
    exit 1
  }
  log "no-docker mode: using $(command -v vllm)"
fi

# --- bring the stack up ---------------------------------------------------
PREFILLER_PID=""
DECODER_PID=""
PROXY_PID=""

# $6 is the fault rank and is only ever passed for the prefiller. It must go
# through `env` explicitly: `VAR=x some_function` sets a shell variable for the
# call, it does not export VAR into commands the function then runs.
start_native() {
  local name=$1 gpus=$2 sc_port=$3 internal_port=$4 script=$5 fail_rank=${6:-}
  log "starting $name (GPU $gpus)"
  env CUDA_VISIBLE_DEVICES="$gpus" \
      VLLM_NIXL_SIDE_CHANNEL_PORT="$sc_port" \
      VLLM_PORT="$internal_port" \
      VLLM_KV_CACHE_LAYOUT=HND \
      UCX_NET_DEVICES=all \
      VLLM_PUSH_FAIL_ON_TP_RANK="$fail_rank" \
      bash "$PWD/$script" > "$LOG_DIR/${name}.log" 2>&1 &
  case "$name" in
    prefiller) PREFILLER_PID=$! ;;
    decoder)   DECODER_PID=$! ;;
  esac
}

if [[ "$NO_DOCKER" == "1" ]]; then
  start_native prefiller "$PREFILL_GPUS" "${PREFILL_SIDE_CHANNEL_PORT:-5559}" \
    20000 serve-prefiller.sh "$FAIL_RANK"
  start_native decoder "$DECODE_GPUS" "${DECODE_SIDE_CHANNEL_PORT:-5659}" \
    30000 serve-decoder.sh
else
  log "starting prefiller + decoder"
  compose up -d prefiller decoder >>"$RUN_LOG" 2>&1
fi

alive() {
  local name=$1 pid=""
  if [[ "$NO_DOCKER" == "1" ]]; then
    # serve-*.sh ends in `exec vllm serve`, so the pid we captured is the
    # server itself and kill -0 is a real liveness check.
    case "$name" in
      prefiller) pid=$PREFILLER_PID ;;
      decoder)   pid=$DECODER_PID ;;
    esac
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
  else
    [[ "$(docker inspect -f '{{.State.Running}}' "c2-${name}" 2>/dev/null)" == "true" ]]
  fi
}

wait_for() {
  local name=$1 port=$2 deadline=$((SECONDS + ${3:-900}))
  log "waiting for $name on :$port"
  until curl -sf "http://localhost:${port}/health" >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      log "TIMEOUT waiting for $name; see logs/${name}.log"
      return 1
    fi
    if ! alive "$name"; then
      log "$name exited; see logs/${name}.log"
      return 1
    fi
    sleep 3
  done
  log "$name is up"
}

wait_for prefiller "$PREFILL_PORT" || exit 1
wait_for decoder   "$DECODE_PORT"   || exit 1

log "starting proxy"
if [[ "$NO_DOCKER" == "1" ]]; then
  python3 "$REPO_ROOT/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py" \
    --port "$PROXY_PORT" \
    --prefiller-hosts localhost --prefiller-ports "$PREFILL_PORT" \
    --decoder-hosts localhost --decoder-ports "$DECODE_PORT" \
    > "$LOG_DIR/proxy.log" 2>&1 &
  PROXY_PID=$!
else
  compose up -d proxy >>"$RUN_LOG" 2>&1
fi
sleep 5

# --- drive one request ----------------------------------------------------
# Long enough to be worth pushing, short enough to stay quick.
PROMPT="Explain in two sentences why disaggregated prefill reduces tail latency."
log "sending request through the proxy on :$PROXY_PORT"

REQ_START=$SECONDS
set +e
curl -sS --max-time "${REQUEST_TIMEOUT:-180}" \
  "http://localhost:${PROXY_PORT}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"max_tokens\":48,\"temperature\":0}" \
  -o "$LOG_DIR/response.json" -w '%{http_code}' > "$LOG_DIR/http_code" 2>>"$RUN_LOG"
CURL_RC=$?
set -e
REQ_ELAPSED=$((SECONDS - REQ_START))
HTTP_CODE=$(cat "$LOG_DIR/http_code" 2>/dev/null || echo "000")

log "curl rc=$CURL_RC http=$HTTP_CODE elapsed=${REQ_ELAPSED}s"

# --- verdict --------------------------------------------------------------
sleep 3   # let the decoder flush its log
echo | tee -a "$RUN_LOG"
log "================ RESULT ================"

REPORTED=$(count_matches "Producer could not write all KV" "$LOG_DIR/decoder.log")
# Must not match the "FAULT INJECTION ARMED" banner serve-prefiller.sh
# prints at startup, or every run over-reports by exactly one.
INJECTED=$(count_matches "FAULT INJECTION: not posting" "$LOG_DIR/prefiller.log")

log "prefiller: $INJECTED dropped WRITEs"
log "decoder:   $REPORTED failed-push reports"

if [[ "$BASELINE" == "1" ]]; then
  if [[ "$CURL_RC" == "0" && "$HTTP_CODE" == "200" && "$REPORTED" == "0" ]]; then
    log "PASS: happy path still works, no spurious failure reports"
  else
    log "FAIL: baseline did not complete cleanly (rc=$CURL_RC http=$HTTP_CODE reports=$REPORTED)"
  fi
else
  if [[ "$INJECTED" == "0" ]]; then
    log "INCONCLUSIVE: the fault never fired. Did the request actually get pushed?"
  elif [[ "$REPORTED" == "0" ]]; then
    log "FAIL (this is the bug): P dropped a WRITE and D never reported it."
    log "  On the fixed branch D should log 'Producer could not write all KV'."
    log "  If you are on the base commit, this is the expected hang."
  elif [[ "$CURL_RC" != "0" ]]; then
    log "PARTIAL: D reported the failure but the request did not return (rc=$CURL_RC)."
  else
    log "PASS: P dropped a WRITE, D reported it, request returned in ${REQ_ELAPSED}s"
    log "  (policy=$FAILURE_POLICY -> http $HTTP_CODE)"
  fi
fi

log "logs: $LOG_DIR"
ls -la "$LOG_DIR" | tee -a "$RUN_LOG"
