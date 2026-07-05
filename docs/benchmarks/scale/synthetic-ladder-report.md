# subagent-duel report

## Fanout

| arm | N | reps | unit wall ms | child wall ms | peak RSS MB | procs | input tok | uncached tok | calls | transports | exits |
|---|---|---|---|---|---|---|---|---|---|---|---|
| codex-exec | 1 | 3 | 7028 | 7005 | 114.8 | 13 | 48472 | 16472 | 1 | http_sse | 0 |
| codex-exec | 2 | 3 | 10028 | 9925.0 | 211.0 | 20 | 98372 | 34110 | 2 | http_sse | 0 |
| codex-exec | 4 | 3 | 14297 | 8497.5 | 397.5 | 42 | 195080 | 11831 | 4 | http_sse | 0 |
| codex-exec | 8 | 3 | 17267 | 9806.0 | 793.5 | 87 | 468653 | 139309 | 8 | http_sse | 0 |
| pixir-delegate | 1 | 3 | 6446 | 6400 | 129.2 | 6 | 16171 | 12587 | 2 | websocket | 0 |
| pixir-delegate | 2 | 3 | 9373 | 9331 | 147.1 | 6 | 34138 | 12634 | 4 | websocket | 0 |
| pixir-delegate | 4 | 3 | 11183 | 11140 | 163.4 | 6 | 66246 | 39085 | 8 | websocket | 0 |
| pixir-delegate | 8 | 3 | 20722 | 20678 | 181.1 | 6 | 165669 | 61221 | 19 | http_sse,websocket | 0 |
| pixir-oneshot | 1 | 3 | 7000 | 6953 | 130.4 | 8 | 15387 | 8731 | 2 | websocket | 0 |
| pixir-oneshot | 2 | 3 | 9685 | 8266.0 | 266.8 | 16 | 32574 | 17726 | 4 | websocket | 0 |
| pixir-oneshot | 4 | 3 | 10056 | 8681.5 | 531.3 | 32 | 63105 | 12929 | 8 | websocket | 0 |
| pixir-oneshot | 8 | 3 | 13757 | 9463.5 | 1070.9 | 64 | 126983 | 27143 | 16 | websocket | 0 |

Marginal peak RSS per extra child (least-squares over N):

- codex-exec: 96.8 MB/child
- pixir-delegate: 6.5 MB/child
- pixir-oneshot: 134.2 MB/child

## Resume chain

| arm | turns | reps | unit wall ms | turn wall ms | peak RSS MB | input tok | uncached tok | calls | transports | exits |
|---|---|---|---|---|---|---|---|---|---|---|
| codex-exec | 5 | 3 | 78742 | 8192 | 120.5 | 901313 | 134971 | 5 | http_sse | 0 |
| pixir-oneshot | 5 | 3 | 66437 | 8364 | 141.7 | 103092 | 34584 | 9 | websocket | 0 |

### Per-turn cache hit rate

- codex-exec: turn_1=0.67, turn_2=0.78, turn_3=0.84, turn_4=0.86, turn_5=0.89
- pixir-oneshot: call01=0.97, call02=0.78, call03=0.77, call04=0.76, call05=0.54, call06=0.66, call07=0.82, call08=0.00, call09=0.95

## Caveats

- RSS figures are SAMPLED process-tree peaks (500ms poll): sub-interval spikes and non-descendant helpers are not captured; slopes carry bootstrap CIs (see plan), not point certainty.
- Token units differ per side: Pixir logs one provider_usage per API call; codex emits one turn.completed per invocation (aggregating its internal loop). Totals are billed-input sums; call counts are NOT comparable one-to-one.
- Workload is read-only doc-analysis fanout/resume; conclusions are scoped to that shape until a write-mode benchmark exists.
- RSS is local process pressure of the sampled process tree, not provider memory.
- Harness system prompts differ by design; cache evidence measures each harness's own prefix discipline.
- codex desktop app must be closed during runs; sampler tracks only harness descendants either way.
