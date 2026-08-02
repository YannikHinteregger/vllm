# C2 fault test — do not merge

Throwaway tooling for exercising the unposted-WRITE path by hand. This branch
carries a **fault injection in `push_worker.py`** and must never be merged or
opened as a PR against upstream.

## What it does

`vllm serve` a prefiller and a decoder in two containers plus the repo's toy
proxy, then drives one request through and reports what the decoder did.

The fix only runs when a WRITE fails to post, which a healthy cluster never
does — hence the injection. `VLLM_PUSH_FAIL_ON_TP_RANK=<n>` makes producer TP
rank `n` skip `_xfer_blocks` entirely, so no WRITE is posted and no completion
notif is armed for those edges. It has to skip the call, not discard its
result: `_xfer_blocks` posts the transfer and arms the notif before returning,
so nulling the handle afterwards would double-notify the edge and manufacture
an over-report the design says cannot happen.

Unset, the injection is completely inert, so the same compose file runs the
baseline.

## Run it

```bash
cd tools/c2-fault-test
./run-test.sh --baseline   # happy path still works
./run-test.sh              # fault armed on producer rank 0
```

First run builds `vllm-c2-test:local` from `docker/Dockerfile`, which is slow
and needs well over 40 GB of disk. Point `VLLM_IMAGE` at an existing image to
skip it — it must have NIXL (`requirements/kv_connectors.txt`) and be close
enough to `5fa015444` that the patched `push_worker.py` still matches its APIs.

### Without Docker

A RunPod pod is itself a container and usually cannot run Docker, and the
image build wants more disk than a small pod has. `--no-docker` runs the same
three processes natively, with the same env wiring, `logs/` layout and verdict:

```bash
export HF_HOME=/workspace/hf UV_CACHE_DIR=/workspace/uv-cache
export XDG_CACHE_HOME=/workspace/.cache
uv venv --python 3.12 && source .venv/bin/activate
VLLM_USE_PRECOMPILED=1 uv pip install -e . --torch-backend=auto
uv pip install -r requirements/kv_connectors.txt

cd tools/c2-fault-test
./run-test.sh --no-docker --baseline
./run-test.sh --no-docker
```

The change is Python-only, so `VLLM_USE_PRECOMPILED=1` fetches a wheel instead
of compiling — a few GB rather than tens. Set the cache vars *before* the first
install, or they fill the container disk instead of the volume.

Logs land in `./logs/` (`prefiller.log`, `decoder.log`, `proxy.log`,
`run.log`, `response.json`). Copy that directory off the box.

## Knobs

| var | default | note |
| --- | --- | --- |
| `MODEL` | `Qwen/Qwen3-0.6B` | |
| `PREFILL_TP` / `DECODE_TP` | `1` / `1` | |
| `PREFILL_GPUS` / `DECODE_GPUS` | `0` / `1` | `CUDA_VISIBLE_DEVICES` per side |
| `FAIL_RANK` | `0` | producer TP rank that posts nothing |
| `FAILURE_POLICY` | `recompute` | decoder `kv_load_failure_policy` |
| `VLLM_IMAGE` | `vllm-c2-test:local` | |

`recompute` makes D redo the prefill locally, so a **successful completion is
the evidence**: the hang became a recovery. `fail` surfaces an error finish
reason instead.

## The topology that matters

The default is P TP=1 → D TP=1 on 2 GPUs, where the injection fails *every*
edge. That proves the hang is gone but not the counted design.

With 3+ GPUs use **P TP=2 → D TP=1**:

```bash
PREFILL_TP=2 PREFILL_GPUS=0,1 DECODE_GPUS=2 FAIL_RANK=1 ./run-test.sh
```

Both producer ranks write the same decoder rank, so D expects two notifs and
gets one real completion plus one `PUSH_FAIL`. That is the case the fix is
actually shaped around.

## Before/after

The contrast worth putting in the PR:

The branch is rebased onto `main`, so `main` is the "without the fix" side.

```bash
git stash                                   # park the tooling
git checkout main                           # no fix
git stash pop                               # tooling back
./run-test.sh --no-docker                   # request hangs to the timeout
git checkout test/nixl-push-fault-injection
./run-test.sh --no-docker                   # D reports, request returns
```

## What this does and does not prove

Proves the report reaches D and converts a hang into the configured policy.

Does **not** exercise real RDMA — on one host UCX uses shm/cuda_ipc, so this
is the control path, not the transport. It also cannot demonstrate the
in-flight-sibling race; that window is what the unit tests pin. Say so in the
PR rather than implying hardware coverage.
