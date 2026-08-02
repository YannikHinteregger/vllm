#!/usr/bin/env bash
# Decoder (D) for the C2 unposted-WRITE fault test. Runs inside the container.
#
# D is the side under test: it is the one that hangs today when P drops a
# WRITE, and the one that must now fail the request instead.
set -euo pipefail

MODEL=${MODEL:-Qwen/Qwen3-0.6B}
DECODE_TP=${DECODE_TP:-1}
DECODE_PORT=${DECODE_PORT:-8200}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION:-0.6}
BLOCK_SIZE=${BLOCK_SIZE:-128}
# 'recompute' turns the failure into a local re-prefill, so a successful
# completion is itself the evidence. 'fail' surfaces an error finish reason.
FAILURE_POLICY=${FAILURE_POLICY:-recompute}

echo "[decoder] kv_load_failure_policy=${FAILURE_POLICY}"

exec vllm serve "$MODEL" \
  --port "$DECODE_PORT" \
  --block-size "$BLOCK_SIZE" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --tensor-parallel-size "$DECODE_TP" \
  --enforce-eager \
  --kv-transfer-config \
  "{\"kv_connector\":\"NixlPushConnector\",\"kv_role\":\"kv_consumer\",\"kv_load_failure_policy\":\"${FAILURE_POLICY}\"}"
