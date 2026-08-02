# PR draft: C2 unposted-WRITE reporting

Paste everything below the rule. Fill the two link placeholders first.

---

## Summary

Fixes row **C2** of #48633.

In push mode the prefill node writes KV straight into the decode node's memory, and the decode node knows it has everything by counting the notifications that ride along. If the prefill node can't start one of those transfers it just logs and moves on, so the decode node counts toward a number it never reaches and the request hangs until its lease expires, holding blocks over a half-written cache.

The prefill node now reports transfers it couldn't start, so the count adds up and the existing KV load failure policy can take over.

The report is **counted like a normal notification** rather than failing the request straight away. When several prefill ranks feed the same decode rank, failing on the first report would release blocks while a sibling's transfer is still in flight — turning today's hang into silent corruption.

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

Both instances ran on one host, so this exercises the coordination logic rather than a real network transfer, and the failure is simulated.

No model evaluation needed: this path only runs when a transfer fails to start, and cannot change output on any request that succeeds.

## Notes

Some cases are deliberately not covered — transfers that fail after starting, handshake failures, unresolvable ranks, and hybrid/multi-group models. Happy to expand on any of them.

Not a duplicate — the open PRs on #48633 cover stale remote cleanup and prefix caching. C2 is unclaimed and I asked for it on the issue.

AI assistance was used for this change. I've reviewed every changed line and run the tests myself.
