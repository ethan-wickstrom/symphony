# Status API

The current checkpoint implements the optional SPEC §13.7 API and a small
server-rendered dashboard. Local verification passes; hosted review is pending. Authenticated Codex/provider
acceptance and clean-host/static releases remain separate gates.

```text
native HTTP -> injected Status_surface.handle -> Status_source
                                                |
                                    one-use owner query
                                                |
                              paired clock sample -> Core.snapshot
```

`Snapshot.t` is checked immutable public data. Counts derive from its owner lists;
the owner derives runtime and token totals from canonical scheduling/observation
state. Every query uses one fresh clock sample. Wall projections outside the
supported RFC 3339 range remain null; wall time never controls scheduling.
Only acquired phases carry a checked session/thread/turn and positive turn count.
Workspace display comes from accepted `Workspace_ready`, never a guessed path or
a new configuration lookup. Cleanup ownership remains visible until release.

`Status_source.S` offers snapshot and coalesced refresh only. It exposes no
tracker, filesystem, process, configuration or raw secret capability. Expected
timeout, shutdown, clock and projection failures are four unavailable values.
A rejected read-side projection answers the query without killing the scheduler.
Successful reads do not emit scheduling commands; refresh queues the existing
poll/reconciliation control. HTTP fibers never invoke `Core.step` or reload a
workflow themselves.

| Route | Result |
| --- | --- |
| `GET /` | Escaped HTML from one fresh snapshot, with refresh form. |
| `GET /api/v1/state` | Running/retry/cleanup rows, derived counts, exact totals, rate limits and workflow error. |
| `GET /api/v1/<issue_identifier>` | Current owner details, including cleanup; released/unknown issues return 404. |
| `POST /api/v1/refresh` | 202 with queued/coalesced and poll/reconcile operations; no snapshot read. |

Refresh accepts an empty/whitespace body or `{}`; other bodies return 400 before
queuing work. Unknown routes return 404. Unsupported methods on defined routes
return 405 before accessing the source, with the exact `Allow` method: `POST` for
refresh, `GET` for reads. Unavailability and response-limit failures return
503 with fixed JSON error envelopes. Detail failures remain 503 rather than being
misreported as unknown issues. This corrects the Elixir presenter's conflation of
snapshot failure with 404. The presenter supplies baseline field conventions;
its configuration-derived workspace fallback is deliberately absent here.

Numeric JSON uses exact count lexemes and `Seconds.decimal`, including values
above floating-point precision. JSON composition returns `result` under the
existing one MiB checked-tree budget. HTML has an independent four MiB budget and
escapes every untrusted text field. No tracker-native metadata, credentials,
environment or guessed session/path is rendered. Rate-limit JSON and retained
agent display facts are observability data, never scheduling inputs.
Refresh acknowledgments omit `requested_at` because the narrow refresh result has
no paired wall sample; the state response supplies an actual `generated_at`.

H1 owns HTTP framing. Body closure alone does not grant handler authority: the
driver waits for parser classification, revokes rejected requests and invokes a
handler once outside parser callbacks. Rejected or handled connections only flush
their response and close. Hard wire/header limits may close a peer without a
response. Responses half-close the send side before bounded unread-input drainage.

Before body collection, the transport requires one loopback Host with the actual
bound port. A supplied Origin must match that Host's canonical HTTP origin;
Fetch metadata permits only same-origin or direct navigation. Foreign, null,
duplicate and malformed values return 403 with no handler authority. Clients
without browser metadata remain supported. This blocks cross-origin refresh and
DNS-rebinding requests where browser network policy permits local connections.
The policy follows [OWASP origin and Fetch metadata guidance](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html).

Each service owner has a private cancellation context. Caller failure closes its
source and preserves the primary outcome before canceling and joining the owner.
The outer native scope captures callback errors before joined closure; induced
cancellation retains the scope failure instead of replacing it with cancellation.

The scoped native listener defaults to loopback. `server.port` enables it;
`--port` overrides the checked configured port, and zero requests an ephemeral
port. Startup resolves listener settings once under the adapter's restricted
public environment. Runtime configuration never retains or validates them;
port-only edits cannot change policy identity, dispatch readiness or tracker-job
cancellation. Listener changes require restart. The host supplies the
listener/clock/query capabilities explicitly; the service also runs without HTTP.

| Boundary | Limit |
| --- | --- |
| Native concurrent clients | 64 |
| Request headers / body / total wire | 16 KiB / 64 KiB / 96 KiB |
| Native response / connection deadline | 8 MiB / 5 s |
| Outstanding owner queries / CLI query deadline | 64 / 1 s |
| JSON composition / HTML output | 1 MiB / 4 MiB |

These bounds control retained requests, replies and connection scopes; they do
not make a blocked operating-system call finite. Query capabilities are one-use,
and cancellation/rejection cannot leave reusable reply authority behind.

`status_test.ml` has independent owner-list laws and observable route-port checks,
exact numeric/null/session assertions, escaping, overflow, cleanup lookup, rate
health and a 1,000-row checked rendering fixture. The fixture makes no physical
performance claim. Core tests check canonical sample/phase/workspace projections;
service query tests check actual owner replies and closure. Local normal/optimized
gates pass 58 native lifecycle cases and 23 actual status CLI scenarios per mode,
including a 256-input public-server corpus. Regressions first failed for browser
authority and valid/invalid listener-only reloads; the corrected executable
dispatches through those reloads on its original listener. Hosted review and browser inspection
remain pending; see [conformance receipts](../../CONFORMANCE.md).
