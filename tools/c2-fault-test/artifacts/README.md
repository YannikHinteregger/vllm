# Hardware run artifacts, 2026-08-02

RunPod, 2x RTX 4000 Ada (20 GB each), driver 550 with the image's CUDA 13
forward-compat libs. `Qwen/Qwen3-0.6B`, P TP=1 -> D TP=1 on one host,
`block_size 128`, `--enforce-eager`, greedy (`temperature=0`, `seed=0`),
decoder `kv_load_failure_policy=recompute`.

| dir | branch | fault | result |
| --- | --- | --- | --- |
| `main-baseline/` | `main` | none | reference output |
| `baseline/` | fix | none | completion **byte-identical** to `main` |
| `fault/` | fix | rank 0 posts nothing | 1 dropped WRITE -> 1 report -> HTTP 200 in 2s |

## Happy path is unchanged

`main-baseline/response.json` and `baseline/response.json` carry the same
completion text (sha256 `015b57f871544ba0…`, 48 tokens); the files differ only
in the `id` and `created` fields. Greedy decoding makes this output
equivalence, not merely "no errors logged". `main` was run twice and produced
identical text both times, so the reference is stable.

## The failure path

From `fault/`:

```text
prefiller.log  FAULT INJECTION: not posting WRITE from tp_rank 0 to remote rank 0
decoder.log    Producer could not write all KV for request ...; failing it.
decoder.log    Skipping KV post-processing for failed request ...
run.log        prefiller: 1 dropped WRITEs / decoder: 1 failed-push reports
```

One edge, one report. On `main` the same fault emits no report at all and the
request waits out its lease. Under `recompute` the decoder re-prefills locally
and the request returns 200.

The request ids differ between the two logs (`…a51874ab` on P, `…94d92883` on
D) because each engine has its own local id; `remote_request_id` maps them.

## What this does not cover

Single host, so UCX uses shm/cuda_ipc — this exercises the control path, not
RDMA. TP=1 -> TP=1, so every edge fails rather than the partial-failure case
the design is shaped around. The failure is injected, not a genuine NIXL
submission error. The in-flight-sibling race remains unit-test-only.

## Unrelated observation

Transferred KV and recomputed KV give different deterministic completions
(`baseline/` vs `fault/`). Identical on `main`, so nothing in this change
caused it; most likely a benign numerical difference from different prefill
chunking on P versus D. Noted, not chased.
