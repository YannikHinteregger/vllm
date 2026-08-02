#!/usr/bin/env bash
# Prefiller (P) for the C2 unposted-WRITE fault test. Runs inside the container.
set -euo pipefail

MODEL=${MODEL:-Qwen/Qwen3-0.6B}
PREFILL_TP=${PREFILL_TP:-1}
PREFILL_PORT=${PREFILL_PORT:-8100}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION:-0.6}
BLOCK_SIZE=${BLOCK_SIZE:-128}

# Unset means the injection is completely inert, so the same compose file
# serves the happy-path baseline run.
if [[ -n "${VLLM_PUSH_FAIL_ON_TP_RANK:-}" ]]; then
  echo "[prefiller] FAULT INJECTION ARMED on producer tp_rank=${VLLM_PUSH_FAIL_ON_TP_RANK}"
else
  echo "[prefiller] no fault injection (happy path)"
fi

exec vllm serve "$MODEL" \
  --port "$PREFILL_PORT" \
  --block-size "$BLOCK_SIZE" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --tensor-parallel-size "$PREFILL_TP" \
  --enforce-eager \
  --kv-transfer-config '{"kv_connector":"NixlPushConnector","kv_role":"kv_producer"}'
