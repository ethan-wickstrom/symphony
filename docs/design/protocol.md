# App-server protocol profile

This is an interface proposal, not a working client or a conformance result.
The target is Codex CLI **0.159.2**, its generated **stable** JSON schema, and
stdio. P01–P05, P08, D07, D12, and D13 in [decisions.md](../decisions.md) govern
the policy. The [official app-server documentation](https://developers.openai.com/codex/app-server/)
governs transport behavior; the generated target schema governs wire shapes when
examples disagree. Selecting the stable API surface does not establish production
support for the app-server runtime.

## Provenance

The 2026-09-30 audit generated the target bundle before client implementation:

```text
codex app-server generate-json-schema --out /private/tmp/symphony-protocol-audit/0.159.2/stable
```

Its manifest is `/private/tmp/symphony-protocol-audit/0.159.2/manifest.json`.
The stable bundle contains 314 files and has SHA-256:

```text
9dec03ab74e2e8a8e3b2948594c7183ee0565c3df33c792ea78d387e6824e093
```

The hash covers sorted records of relative filename, NUL, raw-file SHA-256 hex,
and newline. [protocol-audit.md](../protocol-audit.md) records the comparison with
0.153.4 and the separate experimental bundle. Temporary paths are audit artifacts;
slice 5 must retain the selected schema manifest and fixtures in the repository.

The conformance profile is `codex-0.159.2-stable-stdio`. Each report records the
binary version, bundle hash, generator flags, initialization capabilities,
effective workflow policy, and host/runtime. A fake server passing this profile
proves client behavior against that contract; target-host integration separately
checks authentication, subprocess cleanup, and sandbox enforcement. Schema
generation is neither of those tests.

## Ports and ownership

The protocol layer has three responsibilities:

| Module | Pure/effect boundary | Contract |
| --- | --- | --- |
| Frame decoder | Pure | Incremental bounded JSONL framing; partial input is retained, malformed input is an error value. |
| Method codec | Pure | Checked wire IDs, selected request encoders, method-specific reply/notification decoders, denial/cancellation encoders. |
| App-server session | Eio edge | Scoped subprocess, reader/writer, pending RPC table, response deadlines, turn silence timer, interruption, stream drain and reap. |

These are real boundaries, not a mirror of the entire generated schema. The transport callback uses the closed checked `Agent_runner.event` type.
Before slice-5 implementation, refine method-specific codecs beneath that port. Raw method names, approval payloads, tool
arguments, and response correlation remain here. The runner exports normalized
progress and attempt outcomes; the orchestrator receives no wire messages.

The launcher accepts the workspace manager's live `Path.t` and an allowlisted
`Environment.child`, never an inbound protocol pathname. The workspace driver
owns containment, directory identity, launch validation, and release. Tracker
credentials do not enter the child environment. Shell execution is confined to
the trusted-config driver using the required `bash -lc` argument array.

An attempt owns its connection and all protocol resources under one child switch.
Continuations issue another turn on the same thread. After a successful turn,
the runner asks the owner for a generation-fenced tracker refresh; the owner
adopts the refreshed issue and decides continuation. The protocol layer does not
read the tracker or select issues. Completion is attested only after interruption
or normal termination, bounded cleanup, subprocess reap, and the required
`after_run` hook have finished. Terminal workspace removal is a separate owner
command, retaining ownership until its acknowledgement.

## Framing and identities

Stdio is newline-delimited JSON, without the `jsonrpc` header. A request has
`id`, `method`, and method-specific `params`; a response echoes `id` with exactly
one of `result` and `error`; a notification has no `id`.
[Official framing reference](https://developers.openai.com/codex/app-server/#protocol).

`RequestId.json` admits a string or signed 64-bit integer. Preserve the variant
and exact integer: `"7"` and `7` are different IDs. Outbound RPC IDs use generated
strings and are never reused within a connection. They have a distinct abstract
type from owner `Request_id`, `Run_id`, `Retry_id`, `Thread_id`, `Turn_id`, and
dynamic-tool `callId`. Client-originated pending calls and server-originated
requests have separate tables; a server request may numerically match a client ID.

The continuous reader handles notifications and server requests while a client
RPC is pending. Waiting for an initialization or turn-start response must not
stop that reader. Each pending call remembers its method-specific result decoder,
connection generation, and relevant thread/turn context. Unknown or repeated
response IDs cannot complete another call. A repeated terminal notification
cannot complete an attempt twice. Unknown notifications are bounded observational
data, never inferred lifecycle transitions; unknown server requests receive a
correlated method-not-found error.

The decoder rejects duplicate JSON keys, invalid JSON/UTF-8, ambiguous envelopes,
out-of-range numeric IDs, and oversized frames with explicit errors. EOF with an
unfinished frame is truncation. Stderr is drained separately and contributes
bounded redacted diagnostics, not JSONL messages. Parser laws include chunk
partition invariance and encode/decode agreement for every emitted message.

## Initialization and authentication

Wait for a successful `initialize` response, then send `initialized`, then start
the thread. Use a stable Symphony client name and the actual Symphony version.
Supply these capabilities explicitly:

```json
{
  "experimentalApi": false,
  "explicitGatewayOauth": true,
  "requestAttestation": false
}
```

`explicitGatewayOauth` is present in the stable
`v1/InitializeParams.json` schema. It selects explicit gateway authorization for
this app-server runtime; a later connection cannot reverse that choice. It does
not prove authentication is available. Provision authentication outside attempts.
Symphony does not invoke gateway login, browser authorization, device enrollment,
or verification. Unavailable authentication produces a bounded actionable failure.

Do not opt into MCP form extensions, experimental API methods, or attestation.
Unexpected token-refresh or attestation requests are unsupported in this profile:
return a correlated error and terminate the attempt rather than fabricate tokens.
Provider tools require a separately reviewed experimental profile after core
conformance. `experimentalApi=false` does not remove the need to handle the
stable server-request union.

## Thread and turn policies

The default `thread/start` request uses the checked workspace as `cwd`,
`approvalPolicy: "never"`, and `sandbox: "workspace-write"`. The thread enum uses
hyphens. The schema's approval strings are `untrusted`, `on-request`, and `never`;
its object alternative is `granular`. The reference README's outer `reject`
object and documentation examples using other spellings are not this profile's
wire contract.

`ThreadStartResponse.json` returns the thread ID and effective `cwd`, approval
policy, reviewer, and concrete sandbox policy. Check consumed fields and policy
agreement before starting a turn. A reported `AbsolutePathBuf` is only a string
with documented lexical guarantees; it does not prove existence or containment.
Only the workspace driver can validate its relationship to the live directory.

Under the default policy, every `turn/start`, including continuation, supplies `threadId`, text-only
`input`, checked `cwd`, `approvalPolicy: "never"`, and:

```json
{
  "type": "workspaceWrite",
  "writableRoots": ["/workspace/EX-123"],
  "networkAccess": false,
  "excludeTmpdirEnvVar": true,
  "excludeSlashTmp": true
}
```

The object is `sandboxPolicy`; its tag uses camel case. The illustrative root is
replaced by the workspace capability's validated path. Both temporary-root
exclusions default to false in the schema, so send them explicitly. The initial
thread shorthand is refined by this turn policy before agent work begins.
Explicit workflow overrides remain schema-validated, operator-visible, and part
of the recorded effective policy; they do not replace workspace launch authority.
Turn overrides become defaults for later turns, but re-encoding the accepted
policy avoids inherited drift. `turn/start` acknowledges a turn; it does not
attest completion or return an effective sandbox policy. Check relevant settings
notifications when received and verify enforcement on the target host.

The selected schema has no `readOnlyAccess` field despite its presence in current
documentation. It also cannot establish that MCP/app tools obey command-network
restrictions. `disabledPluginIds` is saved metadata; the response explicitly says
it does not yet filter plugin capabilities. No isolation or secret-protection
claim may depend on that list or on tool-exposure settings.

## Server requests

Reply using the enclosing RPC `id`, not `itemId`, `callId`, or an issue ID.
Validate thread/turn context without promoting any reported cwd into authority.
The core profile grants no additional permissions and creates no persistent
approval rule.

| Method | Selected handling |
| --- | --- |
| `item/commandExecution/requestApproval` | Reply `{"decision":"decline"}`. |
| `item/fileChange/requestApproval` | Reply `{"decision":"decline"}`. |
| `item/permissions/requestApproval` | Reply `{"permissions":{},"scope":"turn"}`; no requested grant is accepted. |
| `execCommandApproval`, `applyPatchApproval` | Reply with the schema's `denied` decision object and a bounded rejection reason; never use the v2 decision spelling. |
| `item/tool/call` | Reply with `success:false` and an `inputText` diagnostic in `contentItems`; continue the turn. |
| `item/tool/requestUserInput` | Mark input-required, interrupt the turn, and fail the attempt after bounded cleanup. Supply no invented answers. |
| `mcpServer/elicitation/request` | Reply `{"action":"cancel","content":null}`, interrupt, and fail the attempt as input-required. |

Legacy approval methods remain in the generated server-request union; handling
them does not require a compatibility client or legacy outbound protocol.
Their denial shape is:

```json
{"decision":{"denied":{"rejection":"Unattended policy denies approval"}}}
```

User-input results require an `answers` map and provide no cancellation decision.
The official docs state that interruption clears the pending request and emits
`serverRequest/resolved`; use that path rather than an empty or fabricated answer.
The notification also resolves answered approvals/elicitation. Its `requestId`
uses the wire ID type and is not an owner request token.
[Official server-request behavior](https://developers.openai.com/codex/app-server/#approvals).

Stable elicitation shapes include form and URL variants; a nullable `turnId` does
not change the request's RPC identity. Cancel a standalone elicitation and end
the owning attempt even if no current turn can be correlated. Experimental
`openai/userVerification` remains outside the negotiated profile; a defensive
cancel response never supplies a challenge proof or initiates enrollment.

Unsupported tools use the exact result keys `success` and `contentItems`, with
content tag `inputText` and field `text`. This is distinct from turn text input
(`type: "text"`). Tool argument data cannot select a host operation or reveal an
adapter token. Duplicate server requests replay their recorded response without
executing another effect. Bound outstanding requests and retain response records
only for the active turn/connection generation; expired requests cannot initiate
host operations or complete a newer attempt.

## Turns, timeouts, and metrics

Only matching `turn/completed` with status `completed` succeeds. `failed` and
`interrupted` terminate unsuccessfully; preserve optional remote error details,
including errors on interruption. `inProgress`, item completion, thread status,
attachment updates, and gateway-auth changes do not prove turn completion.
Local reconciliation, scope-change, stall, or shutdown reasons remain separate
from remote diagnostics. An unsolicited interruption is a failure, not evidence
that Symphony requested cancellation.

| Timer | Clock and reset rule | Canonical outcome |
| --- | --- | --- |
| `read_timeout_ms` | Monotonic deadline for each startup/synchronous RPC; unrelated output does not reset it. | `Timed_out Response_deadline` |
| `turn_timeout_ms` | Monotonic stdout-silence interval; each app-server output resets it while a turn is active. | `Timed_out Turn_silence` |
| `stall_timeout_ms` | Owner's monotonic event-inactivity check; disabled when configured nonpositive. | `Stalled` after stop and cleanup acknowledgement |

Thus timeout is represented once, rather than as both ordinary failure and timeout.
An interrupt acknowledgement is not resource completion. Bound interruption,
TERM/KILL escalation, pipe drain, and reap; scope cancellation must reach every
child. Runtime totals use local monotonic elapsed time, not optional server
timestamps or reported turn durations.

The usage notification is `thread/tokenUsage/updated`. Its required fields are
`threadId`, `turnId`, and `tokenUsage`. Account from
`tokenUsage.total.inputTokens`, `outputTokens`, and `totalTokens`; do not add
`tokenUsage.last` or generic usage maps. Schema breakdowns also carry cached and
reasoning counters; preserve their wire validity without inventing an equation
between total, input, and output.

Each watermark belongs to `(Run_id, Thread_id)`. A new turn changes the displayed
`Session_id = thread_id + "-" + turn_id`, not the cumulative accounting identity.
For a report `r`, use componentwise `next = max(previous,r)` and
`delta = next - previous`; the sum of deltas telescopes to the final watermark.
Repeated/reordered reports cannot charge the same tokens again. New worker/thread
generations start fresh watermarks. Counter decreases within one generation are
observational anomalies, not permission to reset and double-count.

Preserve the latest nullable rate-limit payload under P08. Account-read
`ordinaryUsageAllowed` does not exist on every notification; neither null nor a
percentage/reset time establishes permission or recovery.

## Slice-5 evidence required

- Validate every outbound example against the selected generated definitions.
- Exercise handshake ordering and both wire ID variants; interleave replies,
  notifications, approvals, and tool requests without reader deadlock.
- Test initial and continuation policy encodings, effective-policy disagreement,
  and actual host path/sandbox/authentication behavior.
- Test all terminal statuses, local cancellation races, interrupted errors, and
  duplicate terminal messages; completion follows resource teardown exactly once.
- Test each server-request branch, missing elicitation turn IDs, duplicate calls,
  and bounded input-required cancellation with no invented response.
- Check thread-total accounting across multiple turns, repeats, reordering, and
  new generations against the simple absolute-counter model.
- Fuzz framing and consumed payload alternatives: chunk boundaries, truncated
  UTF-8/JSON, duplicate keys, oversized frames, numeric precision, and invalid IDs.
- Record failures per protocol/conformance profile; fixture acceptance does not
  replace real subprocess or host-policy verification.
