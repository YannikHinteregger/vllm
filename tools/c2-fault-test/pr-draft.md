# PR draft: C2 unposted-WRITE reporting

Paste everything below the rule. Fill the two link placeholders first.

---

## Summary

Fixes row **C2** of #48633.

**Problem:** In push mode the prefill node writes KV straight into the decode node's memory. The decode node knows it has everything by counting the notifications that ride along. If the prefill node cannot start one of those transfers it just logs and moves on, so the decode node counts toward a number it never reaches. The request hangs until its lease expires while holding blocks over a half-written cache.

**Solution:** This PR introduces a new NIXL message that the prefill node sends when it cannot start a transfer. The decode node then still receives the number of messages it expects, so instead of waiting forever it can tell that one of the transfers failed. When that happens it falls back to the existing KV load failure policy, which either fails the request or recomputes the KV locally.

## Test plan

Added 10 unit tests. The 4 failures in the wider connector suite are pre-existing and reproduce on the base commit:

```text
FAILED tests/v1/kv_connector/unit/test_nixl_connector.py::test_abort_timeout_on_prefiller[ray]
FAILED tests/v1/kv_connector/unit/test_nixl_connector.py::test_abort_timeout_on_prefiller[None]
FAILED tests/v1/kv_connector/unit/test_nixl_connector_hma.py::test_fewer_blocks_with_hma[google/gemma-3-1b-it-512]
FAILED tests/v1/kv_connector/unit/test_multi_connector.py::test_multi_example_connector_consistency
```

Also tested on a real deployment: two RTX 4000 Ada GPUs running a prefill and a decode instance, with a small local modification that simulates a NIXL failure and provokes the bad path.

- **Good path:** output byte-identical to the base commit.
- **Bad path:** the decode node is told, fails the request, recomputes locally and returns normally. On the base commit the same fault produces no report at all and the request hangs.

Logs: [good path](<LINK_BASELINE>) · [bad path](<LINK_FAULT>)

Both instances ran on one host. This exercises the coordination logic rather than a real network transfer. The failure is simulated.

No model evaluation needed. This path only runs when a transfer fails to start. It cannot change output on any request that succeeds.

## Notes

Some cases are not covered: transfers that fail after starting, handshake failures, unresolvable ranks, hybrid and multi-group models. I can expand on any of them.

Not a duplicate. The open PRs on #48633 cover stale remote cleanup and prefix caching. C2 is unclaimed and I asked for it on the issue.

AI assistance was used for this change. I reviewed every changed line and ran the tests myself.
