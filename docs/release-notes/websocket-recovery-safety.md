# WebSocket continuation recovery safety

## Behavior

WebSocket continuation remains a connection-local optimization over stateless
`store: false` requests (ADR 0019). The local Log remains authoritative; neither
response ids nor prompt-cache keys become durable conversation state.

A request that actually sent `previous_response_id` may recover **once** from an
exact structured `previous_response_not_found` code in an `error` or
`response.failed` envelope, provided no output or callback effects were observed.
Recovery sends the original full input on the same socket, preserves `store: false`
and the prompt-cache key, and uses only the original deadline's remaining time.
An exhausted deadline does not permit another send. Error message substrings and
error types alone do not authorize recovery; no message-only legacy compatibility
shape is retained.

Recovery is not safe after text (including an empty delta delivered to a callback),
reasoning, function-call progress or declaration, compaction items/callbacks,
Provider-hosted Web Search activity, or usage/terminal evidence. A private sticky
replay-safety flag carries this decision from the reducer to continuation recovery,
HTTP/SSE fallback, and the outer Provider retry loop. It also prevents a third
request after the one full-replay attempt fails. Callback exits retain an explicit
unsafe outcome because a callback can perform its effect before raising.

A caller deadline or connection-process loss is also **replay unsafe**: the
pre-stream accumulator returned to the caller cannot prove that no text or
committed-call callback was already delivered in the connection process. The
existing sticky flag vetoes both automatic HTTP/SSE fallback and the outer
Provider retry, retaining the original structured timeout/process-loss error.
The caller-side projection supplies only the known WebSocket identity, not
invented progress or reconstructed partial results, and supports map and keyword
transport accumulators. Timeout guidance asks for lifecycle inspection rather
than suggesting an automatic full replay.

The default caller deadline remains `:infinity`; stream watchdog policy is
unchanged. Explicit timeouts still kill the stale connection. A separately
initiated request can establish a fresh connection without a stale
`previous_response_id`. Pre-admission validation failures and authoritative clean
connect-failure returns do not acquire the ambiguous-call veto.

Transport completion is not semantic response success. A failed streamed response,
including a failed full replay with a response id, closes/resets the invalid
continuation rather than installing that id/input or clearing failure state. The
original structured Provider error is returned, and the partial accumulator is not
discarded in favor of another request. Already-delivered callback effects remain
single deliveries; this change does not add a new partial-result API.

Normal successful responses, successful-incomplete OutputTruncation evidence,
native compaction/reasoning, same-socket reuse, and clean transport-failure HTTP/SSE
fallback retain their existing contracts. Delivered `provider_metadata` fields
remain compatible. Generic Provider retry classification and the list of transport
failures eligible for fallback are unchanged; replay safety can only veto a retry.
No new canonical Event, Session/Log dependency, registry, or cooldown is introduced.
Prompt-contract, context-window configuration, and missing-usage pressure semantics
are separate work (ADR 0020).

## Deterministic evidence

The initial 16 regression tests were run against unchanged production code by the
parent before implementation: **4 passed, 12 failed**. They adapted only the
WebSocket cases from the supplied reproduction. The observed duplicate effect was
a function-call **declaration callback**, not execution of a real local Tool.

The expanded regression suite exercises `Provider.stream/2` with an injected
scripted WebSocket client. Payload/socket counts, reducer evidence, callback counts,
and connection state are asserted without live Provider calls or timing sleeps.
Coverage includes both error envelopes, zero/default outer retry settings,
observable progress variants, exact-code negatives, failed response-id rejection,
callback exits, exhausted deadlines, transient failures after progress/replay,
transport-failure fallback vetoes, and successful-incomplete compaction recovery.

Verification commands:

```bash
mix test test/pixir/provider_continuation_safety_test.exs
mix test test/pixir/provider_transport_policy_test.exs test/pixir/provider_continuation_safety_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix escript.build
git diff --check
```

The combined focused run passed **111 tests**. Real-network probes were not run.
Repeated-reset observability and broader context/RAM work remain deferred; no cache
hit, latency improvement, or real-Tool duplication claim is made here.

### Connection-call loss regression

Eight additional offline tests exercise actual `Provider.stream/2` with text or a
committed-call callback delivered before the connection is killed or held past an
explicit caller deadline. They also exercise generic map/keyword transport
accumulators. The fixture acknowledges reducer progress before process loss;
unexpected retries complete rather than hanging, making duplicate sends visible.
Against the unchanged call-loss implementation, **all 8 failed**: timeouts fell
back to HTTP/SSE, process exits retried Provider calls, and generic accumulators
lost their replay-safety evidence. After the fix, **all 8 passed**.

The existing explicit-timeout test now rejects automatic fallback while retaining
fresh-process identity and continuation-reset proof on a separately initiated next
request. The combined call-loss, transport-policy, and continuation-safety run
passed **119 tests**, including ordinary clean continuation resets and connect
failure fallback:

```bash
mix test test/pixir/provider_call_loss_safety_test.exs
mix test test/pixir/provider_call_loss_safety_test.exs test/pixir/provider_transport_policy_test.exs test/pixir/provider_continuation_safety_test.exs
```

Full-suite verification and binary builds remain parent-owned release checks; no
live probes were used for this fix.
