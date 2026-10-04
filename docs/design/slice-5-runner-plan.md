# Closed Codex runner

The merged service and capacity gates own fake worker scopes. This checkpoint
adds the actual stable JSONL interpreter and closed runner beneath that same
owner. It does not add a dispatch command or claim real-host authentication or
sandbox enforcement from fake-server evidence.

## Contracts before implementation

Reuse Agent_process.S and the existing native process-group bracket. The runner
receives the actual clock/workspace per invocation; its constructor captures only
the process driver and Symphony version. No new private native API escapes.
App_server owns initialization, one named thread, explicit policy on every turn,
response correlation, bounded framing and server-request replay. The selected
314-file stable bundle still hashes to the recorded 0.159.2 manifest.

The process callback ends before native pipe/group closure. The workspace callback
ends after the process bracket; after_run and lease release follow it. Only then
can Codex_runner construct its opaque completed value. Service publishes it after
the enclosing worker switch closes. A wire turn terminal never attests closure.
After Preparing is acknowledged, the runner checks interruption before acquiring
the workspace; watcher scheduling cannot authorize a stopped invocation.

```text
Service owner → checked request → Codex_runner
                                  workspace / hooks
                                       ↓
                                  App_server
                                 JSONL / codec
                                       ↓
                                  Agent_process
                                 pipes / group / reap
```

## Owner observations

Embed one Agent_observation value alongside Life.owned in the canonical owner
PSQ. Preserve it only for the same run; clear it when the run closes. It holds
sequence/emission time, preparation/protocol phase, current session/turn, success
and answer barriers, activity, bounded display facts and one run/thread watermark.
Known turn IDs are bounded by the frozen turn cap. Completed or older known-turn
usage advances accounting and emission fences without refreshing activity or
current display. Only the current In_turn report has activity authority.

Worker_progress carries its emission clock stamp. The owner rejects future or
regressing stamps; stale sequence cannot become fresh activity at dequeue.
Worker_continue follows an accepted successful-turn barrier. Its request uses
the original binding and current read policy, with issue/run/turn/epoch fences.
An older outstanding read closes before the new continuation read starts.
Only its correlated Continue_worker reply can authorize another turn.

One owner-granted update ticket per worker bounds acknowledged progress. Publish
without suspension, then wait for receipt or invocation interruption. The owner
acknowledges after its transition/observer succeeds and grants the next ticket.
Continuations register their reply capability before owner delivery. Entry and
closure slots remain independent. Fatal drainage resolves worker interruptions
before joining, so blocked callbacks cannot retain resource custody indefinitely.
Overlapping callbacks serialize publication through receipt; the tracker reply
waits outside that mutex.

Stall is a typed interruption. Check current policy with exact monotonic time:
elapsed strictly greater than the limit; nonpositive disables it. Stopping keeps
its slot until closure. Disposition joins Retry < Release < Cleanup so terminal
reconciliation still cleans during a stall/continuation race.
One retained poll timer checks stalls through pending reads; explicit refreshes
perform the same check without replacing that timer. Busy ticks cannot start an
overlapping reconciliation cycle.
Canceled continuations retain original-binding reconciliation in the request
ledger. Worker closure retargets that obligation to its exact retry receipt.
Fresh terminal reconciliation can clean either closure order without shortening
nonterminal backoff. Scope drain and shutdown discard deferred authority.
The observational Idle/Busy cycle projection drives capacity timing. A sample
ends after full cycle closure; a held-read regression rejects timer rearming as
a completion boundary.

## Protocol bounds and evidence

The profile caps a frame at 1 MiB, matching checked Json; it deliberately chooses
a smaller bound than the spec's recommended 10 MB. Immutable geometric fragments
avoid quadratic accumulation from one-byte reads. Parse failures retain the
accepted prefix independent of chunking. Stdout silence and fixed RPC deadlines
are distinct; every write is bounded. Stderr drains separately and never becomes
a frame or raw default log.
Continuation replies preserve accepted read errors after the losing operation
joins; captured callback defects retain their identity and backtrace.
The captured session body survives reader cancellation/join faults; a successful
body still exposes a closing defect.

Initialize → initialized → thread/start → thread/name/set → turn/start; repeat
turn/start on the same thread, and turn/interrupt on stop. Handle all ten stable
server-request branches, deny approvals, fail unsupported tools, cancel MCP/input
without fabricated answers, and reject auth/attestation requests. Separate client
and server correlation identities; completion and interruption acknowledgments do
not release resources. Pending and active turns reject conflicting terminal
outcomes; identical replays retain one completion barrier. Initialization, input,
continuation and terminal handoffs settle the accepted batch before return.
Input cleanup retains typed protocol faults. Every preparation/protocol receipt
checks interruption after its callback returns. Closing preserves its fixed deadline
and local interruption while recording buffered protocol faults; it never waits
for a future packet after a terminal.

Required evidence: independent framing/observation/accounting models; outbound
fixtures against retained generated schemas; causally fenced service scenarios;
real owned fake-server subprocesses with backpressure, interleaving, timeouts and
closure failures; relevant full local and hosted gates. Live authentication,
actual agent behavior and Codex sandbox enforcement remain separate host gates.
