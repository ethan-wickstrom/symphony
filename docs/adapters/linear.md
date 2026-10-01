# Linear adapter profile

This is a read-only adapter. The orchestrator sees normalized `Issue.t` and never
interprets `native_ref`. Provider tools, issue writes and OAuth inference are absent.

| Setting | Meaning |
| --- | --- |
| `tracker.kind` | `linear` |
| `tracker.provider.endpoint` | HTTPS GraphQL URL; default `https://api.linear.app/graphql`. Reject userinfo, fragment, malformed host/port and unsafe request-target bytes. |
| `tracker.provider.project_slug` | Required nonempty Linear project slug ID; exact provider-side filter, verified on returned records. |
| `tracker.provider.api_key` | Personal API key, literal or `$VAR`; absent uses `LINEAR_API_KEY`. Seal as destination-bound Authorization value. |
| `tracker.active_states`, `tracker.terminal_states` | Explicit nonempty disjoint lists required by D01; normalized Unicode lowercase names. |

Minimal workflow, with the credential supplied through the environment:

```markdown
---
tracker:
  kind: linear
  active_states: [Todo, In Progress]
  terminal_states: [Done, Canceled]
  provider:
    api_key: $LINEAR_API_KEY
    project_slug: your-project-slug
---
Work on {{ issue.identifier }}: {{ issue.title }}.
```

Configuration is pure: no clock sample, trust read, RNG initialization or request.
The adapter declares `LINEAR_API_KEY` and any referenced credential variable as
secret environment names. No token getter or printable credential exists. Public
settings and the child environment exclude declared sources, credential values and
value-equal aliases, including selected literal keys. Canonical paths, names,
numbers and protocol JSON are checked too. Equal legitimate values are rejected
conservatively; this is not substring taint tracking of trusted scripts or provider
text. Warnings expose only bounded id/identifier
projections and closed reasons; arbitrary provider error text is discarded.

Scope is `linear:` plus SHA256 of length-prefixed exact endpoint/project bytes,
excluding credentials. Credential rotation retains workspace ownership. Endpoint
or project changes fence old workspaces. The owner file contains no raw URL query.

## Reads and ordering

Constant named GraphQL documents carry all selections through JSON variables.
State reads filter project and case-insensitive state names. ID reads filter project
and requested opaque IDs without an active-state restriction. Both exclude archived
issues; invisible, deleted, moved or archived requested issues are absent from the
result. Assignees do not restrict reads. No request fabricates an identifier from ID.

Each issues, labels and inverseRelations connection is paged. Ordered output follows
the provider pages; ID chunks follow the explicit `Issue_id` order. The whole read
must succeed before delivery. This is complete bounded delivery, not a remote database
transaction: concurrent provider changes can cause membership/duplicate errors.

| Bound | Value | Exhaustion |
| --- | --- | --- |
| Page size and ID chunk | 50 | Continue/chunk automatically. |
| HTTP posts per read | 1,000 | Fail entire read. |
| Outer issue nodes | 10,000 | Fail entire read. |
| All connection nodes | 200,000 | Fail entire read. |
| Cumulative response bytes | 16,777,216 | Fail entire read. |
| Cursor bytes | 4,096 | Reject page. |
| Whole read deadline | 30,000 ms | Cancel/join outstanding work; request error. |
| HTTP POST deadline | 10,000 ms | Includes DNS, connect, TLS, headers and body. |
| Encoded request / decoded response | 1,048,576 bytes each | Reject before excess allocation/delivery. |
| Request / response headers | 16,384 bytes each | Reject excess. |
| Response wire | 2,097,152 bytes | Includes framing, not just decoded body. |

An empty state list or ID set performs no factory, clock, request or warning call.
Otherwise the transport factory runs at most once, after the initial clock sample
admits the deadline; an initial clock failure performs no factory or timer call.
A true `hasNextPage` needs nonempty nodes and a usable advancing cursor. Any cursor
cycle fails. Duplicate IDs fail as pagination errors; duplicate identifiers fail as
response errors. An ID returned outside its current requested chunk fails membership
validation before uniqueness. Missing/malformed required records are omitted with a
warning on state reads; ID reads fail because safe requested membership is unknown.

## Normalization and eligibility

Required id, identifier, title and state are checked once into `Issue.t`. Labels
are normalized and unique. Exact integral priorities, including `1.0` and `1e0`,
are accepted without floating-point rounding; fractions and overflow become null.
Unusable optional strings/timestamps become null; usable empty strings are preserved.
`native_ref` contains only constructed issue/project IDs and project slug metadata.

Only Todo routing depends on blockers. Incoming `blocks` uses relation `issue` as
blocker and `relatedIssue` as target; the target must match the current issue. Todo
is dispatchable only with complete evidence that every blocker is terminal.
Unknown states, missing IDs, self blockers, malformed/reversed relations and
incomplete connections cannot establish eligibility. Other states have no blocker
restriction. Best-effort `blocked_by` projection is separate from this proof;
dropping an unusable metadata entry cannot turn unknown eligibility into true.

Every read carries the current validated terminal policy. Provider scope,
credentials and IO stay frozen in its binding, so a reload can update blocker
decisions for an existing run without sending that run through new authentication.

## Failures and host trust

HTTP429 maps to rate limiting. GraphQL `RATELIMITED` on success/HTTP400 also maps to
rate limiting. Other non-success statuses remain status errors. Successful malformed
JSON/envelopes or GraphQL errors reject the whole read. No partial-data acceptance,
hidden retries or cooldown mutation occurs inside the adapter. Errors use §11.4
categories with redacted remedies; cancellation and defects keep identity/backtrace.

The host supplies network, clock, trust and crypto capabilities. The compiler's
macOS target defaults to `/etc/ssl/cert.pem`; its Linux target defaults to
`/etc/ssl/certs/ca-certificates.crt`. `tracker --ca-bundle FILE`
uses a different bounded PEM bundle, including the portable fake's CA. A missing
bundle names the file and fails closed. The bundle supplies explicit certificate
trust anchors; parsing checks certificate encoding, not anchor self-signature,
CA-only extensions or freshness. Operator-selected pins/intermediate anchors remain
valid trust choices. Certificate chain, peer DNS/IP and network peer validity
are checked by X509/TLS with the supplied wall clock. There is no HTTP fallback,
trust-all path, ambient proxy, redirect following or raw wire log.

Maintained H1 handles HTTP/1.1 framing. Its pinned parser fixes and independent
controls are documented in [patch provenance](../../vendor/h1/SYMPHONY_PATCHES.md).
Chunk extensions and trailers are unsupported and fail closed. TLS uses the library
global RNG. One host-owned deferred runtime is shared across reads and registry
reloads; first use adopts an existing generator or installs supported stateless
Getentropy when absent. Workflow/workspace inspection performs no activation.
This is explicit initialization, not per-client RNG isolation.

The driver preserves defects and the backtrace it receives at dependency boundaries.
TLS's best-effort control-write path can erase a backtrace internally; this driver
does not reconstruct erased frames. Such defects remain defects, never success or
a silently classified provider failure.

Provider contracts: [authentication/errors](https://linear.app/developers/graphql),
[filtering](https://linear.app/developers/filtering),
[pagination](https://linear.app/developers/pagination),
[rate limits](https://linear.app/developers/rate-limiting),
[official schema](https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql).
