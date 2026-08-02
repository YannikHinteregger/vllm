# PR draft: C2 unposted-WRITE reporting

Paste everything below the rule into the PR body. Fill the two link
placeholders first.

---

## Summary

Fixes row **C2** of the NixlPushMode reliability inventory (#48633).

In push mode the prefill node writes KV directly into the decode node's memory, one transfer per pair of ranks, and the decode node knows it has everything by counting the notifications that ride along with those transfers. If the prefill node cannot start one of those transfers, it currently logs the problem and moves on. The decode node is left counting toward a number it will never reach, so the request hangs until its lease expires while holding GPU blocks over a half-written cache. The prefill node meanwhile believes it succeeded and frees its own blocks, so the only trace is a single error line on the other machine.

This change has the prefill node tell the decode node about transfers it could not start, so the count always adds up and the decode node can act.

## The one design decision worth a look

The report is **counted like a normal notification** rather than treated as an immediate failure. This matters: when several prefill ranks feed the same decode rank, failing on the first report would let the decode node declare itself done and release its blocks while a sibling rank's transfer is still in flight — that transfer would then land in another request's cache. Today's hang has no such window, so the obvious fix would trade a hang for silent corruption. Waiting for the full count guarantees nothing is still in flight before anything is released.

Once the decode node knows, the existing KV load failure policy takes over: either fail the request or recompute the prefill locally.

## Question for @NickLucche

I used a **separate message type** for the report rather than adding a flag to the existing notification. An older peer that doesn't recognise the new type ignores it and degrades to today's hang, whereas a flag it didn't understand would let it think everything arrived and decode over a gap. Since silent corruption is rated worse than a hang in the inventory, I'd rather fail safe.

This is the only decision that changes the wire format, so I'd like to agree it before going further. I also chose not to bump the connector version, since a mismatch there is a hard handshake failure and that seemed strictly worse than the graceful degradation above. Happy to be overruled on either.

## Not covered

- A transfer that starts and then fails later — nothing is emitted for it either, so there is nothing to report.
- Failures during the handshake, where there is no channel to report on yet.
- Ranks that cannot be resolved at all, e.g. an engine evicted mid-flight. Reporting there would risk the same corruption described above.
- Retrying a failed transfer. That needs a give-up path, so this change is its foundation rather than its alternative.
- Hybrid and multi-group models are deliberately left to the existing timeout, because the recovery path can only invalidate a single group today and a partial invalidation would look like a successful load.

I also ran into two pre-existing problems while working on this, unrelated to the fix but worth reporting separately if useful: an engine crash when a transfer fails after being started, and a similar hang caused by partially delivered registration messages.

## Test plan

Added 10 unit tests covering both the success and failure paths.

The wider connector suite has 4 failures, all pre-existing and reproducing identically on the base commit:

```text
FAILED tests/v1/kv_connector/unit/test_nixl_connector.py::test_abort_timeout_on_prefiller[ray]
FAILED tests/v1/kv_connector/unit/test_nixl_connector.py::test_abort_timeout_on_prefiller[None]
FAILED tests/v1/kv_connector/unit/test_nixl_connector_hma.py::test_fewer_blocks_with_hma[google/gemma-3-1b-it-512]
FAILED tests/v1/kv_connector/unit/test_multi_connector.py::test_multi_example_connector_consistency
```

Also tested on a real deployment: two RTX 4000 Ada GPUs running a prefill and a decode instance, with a small local modification that simulates a NIXL transfer failure and provokes the bad path.

- Good path: output is byte-identical to the base commit, so the change is invisible when nothing fails.
- Bad path: the decode node is told, fails the request, and recovers by recomputing locally — it returns a normal response instead of hanging. On the base commit the same fault produces no report at all.

Logs: [good path](<LINK_BASELINE>) · [bad path](<LINK_FAULT>)

Caveats: both instances ran on one host, so this exercises the coordination logic rather than a real network transfer, and the failure is simulated rather than a genuine NIXL error.

No model evaluation needed — this path only runs when a transfer fails to start and cannot change output on any request that succeeds, which the byte-identical good-path result confirms.

## Not a duplicate

The open PRs referencing #48633 cover stale remote cleanup and prefix caching — different rows, no overlap. C2 is unclaimed and I asked for it on the issue.

## AI assistance

AI assistance was used for this change. I have reviewed every changed line, run the tests myself, and can defend the design end to end.
