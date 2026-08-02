# PR draft: C2 unposted-WRITE reporting

Paste everything below the rule. Fill the two link placeholders first.

---

## Summary

Fixes row **C2** of #48633.

**Problem:** In push mode the prefill node writes KV straight into the decode node's memory. The decode node knows it has everything by counting the notifications that ride along. If the prefill node cannot start one of those transfers it just logs and moves on, so the decode node counts toward a number it never reaches. The request hangs until its lease expires while holding blocks over a half-written cache.

**Solution:** This PR introduces a new NIXL message that the prefill node sends when it cannot start a transfer. The decode node then still receives the number of messages it expects, so instead of waiting forever it can tell that one of the transfers failed. When that happens it falls back to the existing KV load failure policy, which either fails the request or recomputes the KV locally.

## Tested through

```bash
.venv/bin/python -m pytest tests/v1/kv_connector/unit/test_nixl_push_connector.py -q
# 47 passed
```

```bash
.venv/bin/python -m pytest \
  tests/v1/kv_connector/unit/test_nixl_connector.py \
  tests/v1/kv_connector/unit/test_nixl_connector_hma.py \
  tests/v1/kv_connector/unit/test_nixl_heartbeat.py \
  tests/v1/kv_connector/unit/test_multi_connector.py -q
# 157 passed, 1 skipped, 4 failed
```

All 10 new tests pass. `test_abort_timeout_on_prefiller[ray]`, `test_abort_timeout_on_prefiller[None]`, `test_fewer_blocks_with_hma[google/gemma-3-1b-it-512]` and `test_multi_example_connector_consistency` also fail on main at the same commit this branch is rebased onto.

Also tested this on a real deployment: two RTX 4000 Ada GPUs running a prefill and a decode instance, with a small local modification that simulates a NIXL failure to provoke the bad path.

- **Good path:** output is the same as main.
- **Bad path:** the decode node is told, fails the request, recomputes locally and returns normally. On main the same fault produces no report at all and the request hangs.

Logs: [good path](<LINK_BASELINE>) · [bad path](<LINK_FAULT>)

Both instances ran on one host. This exercises the coordination logic rather than a real network transfer. The failure is simulated.

## Notes

AI assistance was used for this change. I reviewed every changed line and ran the tests myself.
