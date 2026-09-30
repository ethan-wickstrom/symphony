# Testing design

Status: test plans for all slices. Slice 1 evidence is recorded in
[the worklog](../worklog.md); later slice plans are not passing results.
The accepted policies are [P01–P08 and D01–D13](../decisions.md).
The requirement baseline is [SPEC.md](../../SPEC.md), Sections 17 and 18;
the protocol target is [Codex 0.159.2](../protocol-audit.md).

## Evidence and test layers

[Alcotest](https://github.com/mirage/alcotest) supplies named examples from Section 17.
[QCheck](https://github.com/c-cube/qcheck) supplies generators, shrinking, algebra laws,
and comparisons with executable reference models. [Crowbar](https://github.com/stedolan/crowbar)
supplies boundary fuzz targets; a coverage-guided backend is accepted only after its
instrumented executable is shown to collect coverage on the selected OCaml 5 toolchain.
Random Crowbar runs remain useful but are not evidence of coverage-guided fuzzing.

Keep four kinds of evidence separate: pure model agreement, simulated service behavior,
portable external conformance, and real target-host integration. None substitutes for
the others. Each failure records the seed or input, fixture/schema versions, expected
observation, actual observation, and the shortest retained reproducer.

Reference models use lists, association lists, mathematical integers, and explicit
variants. They do not call production transition, sorting, backoff, or aggregation
helpers. Test generators may share checked identifier constructors; the oracle must
still express the requirement independently. Compare observations and commands after
normalizing generated request/run identities, without discarding meaningful ordering.

## Boundary design for slice 1

### YAML

Use the positioned event interface of
[yaml 3.2.0](https://github.com/avsm/ocaml-yaml/blob/v3.2.0/lib/yaml.mli#L208-L267),
not its JSON convenience layer. The latter represents numbers as floats; the raw
scalar/event APIs preserve lexemes. The high-level raw parser does not validate the
whole trailing stream. [Interfaces](https://github.com/avsm/ocaml-yaml/blob/v3.2.0/lib/yaml.mli#L31-L92),
[parser implementation](https://github.com/avsm/ocaml-yaml/blob/v3.2.0/lib/yaml.ml#L156-L203).

The wrapper consumes exactly one complete front-matter document through Stream_end.
It requires a map at the root, unique string mapping keys at every depth, bounded
bytes/depth/nodes, and positioned errors. One resolver distinguishes quoted strings
from plain null/boolean/number scalars. Integers retain exact lexemes until checked
conversion; unknown provider fields retain their scalar kinds. Standard core tags and aliases are resolved with explicit depth/node/expansion
bounds; cyclic aliases and unsupported application tags fail with positioned errors.
Unknown provider keys retain resolved scalar kinds. This profile requires design approval.

Generate typed trees with scalar styles, print supported YAML independently, and
compare parsed trees after semantic normalization. Mutate those trees into duplicate
keys, non-map roots, invalid scalars, extra documents, trailing syntax errors, and
over-budget inputs. Include quoted `"true"`, `"null"`, and large integers as explicit
examples. The workflow splitter model operates on lines and returns front matter plus
trimmed body; it does not invoke the YAML parser.

### Strict bounded Jinja profile

Section 5.4 requires a strict engine; Liquid compatibility is sufficient, not mandatory.
Reuse [Jingoo 1.5.4](https://github.com/tategakibunko/jingoo/tree/1.5.4), behind one
module. Do not promise full Jinja or Liquid portability. The proposed profile supports
literal text, interpolation, field/index access, conditionals, array/map iteration,
and the pure filters `length`, `join`, `lower`, `upper`, `trim`, `replace`, and
`default` (the latter handles known null, never undefined). It covers the interpolation and
conditionals in the [upstream workflow](https://github.com/openai/symphony/blob/main/elixir/WORKFLOW.md#L44-L69).

Jingoo's `strict_mode` is type checking, not strict missing-variable checking.
Use its [public AST and context types](https://github.com/tategakibunko/jingoo/blob/1.5.4/src/jg_types.mli#L44-L136)
and [parse-only function](https://github.com/tategakibunko/jingoo/blob/1.5.4/src/jg_interp.ml#L365-L400):

1. Parse source bytes, then validate the AST before any evaluation or template loading.
   Permit only the profile's statements, expressions, and filter applications. Reject
   include/import/inheritance, macros, assignment, function definitions, `eval`, dynamic
   callables, extension loading, and unsupported syntax with named errors.
2. Create a fresh explicit context with only normalized issue data, known-null or
   positive `attempt`, allowed pure filters, and private wrapper helpers. Do not use
   the [default function context](https://github.com/tategakibunko/jingoo/blob/1.5.4/src/jg_runtime.ml#L1719-L1732).
   No file, process, clock, environment, or raw tracker credential is available.
3. Rewrite every field/index access through a private strict accessor. Missing keys,
   out-of-range indexes, and lookup beneath null/scalar return Render_error. A defined
   null remains null and can be tested or rendered. Root lookup has the same distinction.
4. Instrument statements and every loop iteration, including empty loop bodies, with
   fuel checks. Bound source bytes, AST depth/nodes, executed steps, and output bytes.
   Check output limits before appending. Restrict filters to operations with bounded
   work/output under these limits; never expose the engine's open callable set.
5. Convert expected library failures and wrapper-private failures to typed diagnostics.
   The module names the workflow file and offending reference/filter or exhausted limit.
   Cancelled host fibers remain cancellation, rather than ordinary render failures.

Keep the default prompt decision outside the language algebra. An empty AST renders
empty text; D05 replaces an empty workflow prompt with the accepted literal before
compilation. Interpolated issue text is data and is never parsed again.

The template reference model is a small AST evaluator over association-list objects
and lists. Generate model ASTs, print profile syntax, compile with Jingoo, and compare
rendered bytes or classified errors. Check deterministic repeat rendering, known null
versus missing, loop scope and alpha-renaming, nonrecursive interpolation, and unknown
filters. AST sequence has identity and associativity; its render/concatenation equation
requires sufficient shared fuel and output budget. Test budget boundaries separately,
including nested loops with empty bodies. The model must not reuse Jingoo evaluation.

## Plans by vertical slice

| Slice | Reference model and properties | Section 17 examples and failure cases |
| --- | --- | --- |
| 1. Workflow/config/template | Line-based splitter; typed-tree YAML model; explicit environment association list; settings resolution as defaults then documented references then checked conversion. Reload model stores last good settings and latest validity. Error leaves effective settings unchanged, blocks every new-dispatch path, and keeps an operator error; a valid reload clears gating. Reapplying the same valid load is idempotent. Template model is described above. | §17.1 path precedence, missing/invalid/non-map workflow, watched and defensive reload, defaults, adapter validation, provider-key preservation, `$VAR`, `~`, verbatim shell commands, normalized per-state limits, issue/attempt rendering and strict failures. Test absent versus empty secrets; quoted scalar kinds; relative workspace roots anchored to the absolute selected workflow file; literal `$`, `~`, URIs and commands. A template failure affects its attempt, not global readiness. |
| 2. IDs/workspaces/hooks | Checked IDs round-trip through their printers. Workspace-key model sanitizes bytes and appends D03's 128-bit SHA-256 suffix only when changed. A filesystem model maps paths to directory identities and ownership records. Acquisition/reuse/release preserve ownership and containment; scope-finalization releases each resource once. Hook model is a four-phase trace with exit/timeout outcomes. | §17.2 new/reused directories, unchanged keys, same-sanitized-text identifiers, hash/literal aliases, case-folding aliases, non-directory entries, managed symlinks, dot/dot-dot and length limits. Check D02 fail-without-replacement, preparation rollback only for newly owned directories, hook order, fatal before_run, best-effort after_run/before_remove, actual cwd and containment before launch. Race/replacement and shell-environment checks also run on macOS and Linux. |
| 3. Linear/fake tracker | Independent provider-fixture normalizer returns required fields, normalized labels, optional null/empty metadata, opaque dispatch ID/native reference and dispatchable. Pagination model concatenates page lists in provider order. Empty queries cause zero driver calls. ID refresh is atomic for malformed requested records; state-list omission has a warning. Error table covers every §11.4 category. | §17.3 active-state/scope filtering, pagination, label deduplication/case, optional bad metadata, malformed required records, full ID snapshots, opaque IDs, provider routing/blocker rules, profile and portable errors. Inject authentication failures, non-success responses, malformed envelopes, cursor faults and rate limiting. Confirm D01's explicit state lists and D12's absence of provider-native tools. |
| 4. Core/Eio shell/simulator | List-based model of running owners and retries; claimed is their derived union. Retry model is a list keyed by issue ID and sorted by due time plus the named tie-breaker. Independent dispatch rank is priority bucket, creation time with null last, then identifier. Test comparator reflexivity/transitivity/totality and equivalence ties. Compare state observations and commands after every generated event; see the simulation plan below. | §17.4 eligibility, case-insensitive labels, reconciliation before dispatch, refreshed running snapshots, inactive cancellation without cleanup, terminal cancellation with cleanup, no-op reconciliation, normal continuation at attempt 1, abnormal increment/backoff/cap, stalls and capacity requeue. Include stale and duplicate exits/timers/results, pending retry refresh, invalid reload gates, scope drain and startup cleanup. |
| 5. App-server client | A scripted raw-byte peer validates outbound requests against pinned generated schemas and supplies inbound frames. Separate framing model splits/joins bytes independently; protocol model tracks request IDs, thread/turn identity and outcomes. Usage model stores last absolute counters per run/thread generation and sums accepted deltas; totals form a fieldwise natural-number monoid. | §17.5 launch argv/cwd, initialization capabilities, thread/turn setup, same-thread continuation, read/turn timeout, framing, stderr isolation, approvals, input/elicitation termination, unsupported-call failure and continued progress. Fragment/coalesce frames; reorder responses; duplicate usage; inject EOF, malformed frames, unknown notifications, interrupted errors and rate metadata. Regenerated schema validation is separate from client behavior. |
| 6. Logging/snapshot/HTTP | Snapshot model derives rows/counts/slots/durations from current owner state and the supplied time. Log model serializes escaped fields with secret redaction and bounded diagnostics. Aggregation tests reuse the independent absolute-counter model, not production delta helpers. HTTP model maps method/path to the baseline status/body semantics. | §17.6 validation visibility, required context, idle quietness, failing sink, repeated telemetry and status independence. Shipped §13.7 extension tests cover `/`, all three API routes, unavailable/timeout errors, unknown issues, JSON error envelopes, 405, refresh coalescing, loopback bind and CLI port precedence. Status consumers cannot change scheduling except through the defined refresh trigger. |
| 7. CLI/lifecycle/doctor/dry run | Command-line model selects explicit workflow path or cwd default, then maps startup and termination results to exit classes. Resource ledger records acquired/released fibers, timers, flows, subprocesses, watchers and workspace locks. Doctor/dry-run model lists validated steps and observable allowed effects. | §17.7 positional path, default path, missing files, clean startup/shutdown, startup error and abnormal exit. Signals cancel the Eio switch and release children. Doctor errors name file/key/issue and corrective action. Dry run validates configuration and eligibility without launching agents or executing mutating hooks; its tracker reads and allowed diagnostics are documented. |
| 8. Portable harness/benchmarks | External scenario oracle observes launch records, tracker traffic, protocol traffic, logs and declared status observations. Benchmark scenarios use fixed fixture sizes and session counts; compare metrics with a reviewed target-specific baseline. | Run the profiles below; map every §18.1 item in CONFORMANCE.md to concrete test/file evidence. Exercise 1,000 simultaneous simulated sessions, sustained churn, retries, slow peers, cancellations and bounded queues. Verify the Linux musl artifact's actual linkage and execute smoke cases from a clean environment. |

## Orchestrator model obligations

The independent backoff model uses §8.4's equations: continuation delay is 1,000 ms;
failure delay is `min(10,000 ms * 2^(attempt - 1), configured_cap)` for positive attempts.
Check monotonicity, the cap, exact early values, unit separation, and huge attempts that
must reach the cap without overflowing or computing unbounded powers.

After every event, running and retry IDs are disjoint and each derived claimed ID has
one current owner. A retry remains owned while its refresh is pending. Run, retry,
scope/config generation and request identities reject delayed results without changing
newer attempts. Duplicate terminal events cannot add usage/runtime twice or schedule
another retry. Retry replacement/cancellation is idempotent; no timer is an authority.

Capacity is an admission law under D11: each launch satisfies current global and
per-state limits. Lowering limits or refreshing an existing issue into a different
bucket may leave existing sessions above a cap; that is not a failing invariant.
Further admissions into saturated buckets fail. D10 prevents new-scope admissions
until old-scope runs drain, releases old retries, and retains each existing session's
adapter/auth/tool snapshot. No refresh sends an old ID to a new scope.

Generate events that are valid, stale, duplicated and reordered, plus tracker failures
and policy changes. Shrink streams while preserving only the prerequisites needed to
reach the failure. Keep independent model traces for ownership, due times, launches,
cleanup, usage and runtime. Counter-delta telescoping is tested on nondecreasing
absolute reports; a reset needs a new identity rather than a fabricated negative delta.
Retain the cumulative baseline across turns on the same thread; a changed turn or
display session ID does not reset it. Cached/reasoning subcounts are observations,
not extra tokens to add to the protocol's total.
Rate-limit percentages/reset dates never imply permission recovery (P08).

Protocol policy fixtures assert `never`, `workspace-write`, and P03's per-turn checked
writable root, network-off flag and both temporary-root exclusions. Test unexpected
approval denial, typed input/elicitation termination and unsupported-call failure.
Initialize with `experimentalApi=false` and `explicitGatewayOauth=true` (D13); fixtures
must never initiate login, enrollment or verification. Schema-correct payloads do not
prove OS sandbox enforcement or the actual login-shell environment.

## Whole-service deterministic simulation

Run the production service/Eio command shell and orchestrator under
[Eio_mock.Backend](https://ocaml-multicore.github.io/eio/eio/Eio_mock/Backend/index.html).
The mock backend supplies an event loop and deadlock detection; `run_full` can advance
mock monotonic time when idle. It is single-domain, not a model of parallel OS execution.
Use [mock clocks](https://ocaml-multicore.github.io/eio/eio/Eio_mock/Clock/Mono/index.html)
and [flows](https://ocaml-multicore.github.io/eio/eio/Eio_mock/Flow/index.html) where their
interfaces fit, plus project-owned fake lower drivers for capabilities they do not supply.

The service must use the actual workflow/YAML/template parser, Linear payload parser,
workspace policy logic, app-server framer/client and log/snapshot code. Replace only
lower filesystem/watch, HTTP/byte-flow, process and clock drivers. A fake tracker sends
provider JSON; a fake agent reads/writes actual app-server bytes. A fake process records
argv, cwd, child environment, exit and cancellation. Typed Agent/Tracker stubs are useful
for core tests but cannot count as whole-service simulation.

A seeded scenario chooses provider changes, workflow bytes, peer messages, byte
fragmentation, driver completion order, clock changes and cancellation points. It
controls readiness at lower drivers rather than claiming to randomize Eio's scheduler.
Record the seed, PRNG/version, scenario parameters, decision tape, fixture/schema hashes
and event trace. Replay consumes the retained tape; shrinking yields a short fixed case.
Keep monotonic and wall-clock controls distinct, including wall-clock jumps.

Monitor owner invariants, actual launches, deadline behavior, and the resource ledger
through every step. At shutdown, no owned process, timer, watcher, flow or lock survives;
deadlock, escaped exception, invariant mismatch or unfinished owned work fails the run.
The proposed full CI target is at least 2,000 bounded seeds plus every retained regression
seed. Report executed seeds/events and bounds; reaching a time budget is not a pass for
unexecuted seeds. OS-level filesystem and sandbox guarantees need the separate host tests.

## Fuzzing

Every parser has a bounded target: workflow splitting, YAML events/resolution, template
parsing/validation/rendering, JSON, identifiers, numbers/units/timestamps, environment
bindings, Linear envelopes/pages, CLI arguments and app-server frames/messages. Fuzz
hook/diagnostic byte escaping and truncation even where output is not interpreted as a
language. Seeds include valid examples, minimal invalid examples, real redacted payloads,
duplicate keys, invalid UTF-8, NUL, deep nesting, large exact integers and truncated frames.

Assert that inputs produce a checked value or classified error within documented limits.
Any crash, unexpected escaped exception, limit bypass or secret disclosure is a bug.
Accepted values are also fed to consumers: render contexts, config resolution, normalizers
and protocol dispatch. Frame fuzzing varies byte splits independently from message JSON.
Preserve and minimize each failure, add an Alcotest regression, and keep it in the corpus.
Campaign reports name the backend, instrumentation, elapsed time, executions and coverage;
a fixed number of random examples is not a completed coverage-guided campaign.

## Portable conformance profiles

Publish the harness as its own package, independent of the orchestrator library. A driver
manifest declares implementation launch/shutdown/readiness, workflow path/config mapping,
adapter and fake-provider encoding, Codex/schema version and digests, initialization
capabilities, approval/input/tool policy, observation channel and supported extensions.
It may parse documented logs or use a status API; HTTP is not required of another port.
Clock control is an optional driver capability, not a new Symphony requirement. Without
it, deadline cases use controlled peers and real elapsed time with documented tolerances.

The harness launches the implementation with a fake tracker and a fake stdio Codex peer.
Each scenario controls issues/pages/errors and inspects provider requests, protocol bytes,
agent cwd/environment, workspace effects, hook traces, logs and declared observations.
The first provider fixture is Linear; future adapters provide their own fixture drivers
instead of a cross-provider configuration schema. The harness itself must pass deliberate
faulty-implementation cases: duplicate dispatch, lost reload gate, ignored timeout, leaked
secret, permissive unknown variable, and malformed unsupported-tool response.

Use [Section 17's profiles](../../SPEC.md#17-test-and-validation-matrix) and
[Section 18's checklist](../../SPEC.md#18-implementation-checklist-definition-of-done):

- Core: all §17.1–§17.7 mandatory cases and every §18.1 requirement. An unobservable
  mandatory case is reported as unobservable, never passed; the driver must supply an
  adequate observation before the run earns a complete core result. Behavioral tests
  do not prove internal ownership or representation; white-box model/law evidence is
  reported separately.
- Extension: the HTTP/status profile ships here under D09/P07, so its conditional cases
  are required for this port. Provider-native tools are deferred under D12; those cases
  are not applicable, while unsupported-call handling remains core. Record optional
  features individually rather than hiding them in one aggregate pass.
- Real integration: §17.8/§18.3 require a separate opt-in credentialed job using isolated
  issues/workspaces. Report unavailable credentials/network/permissions as skipped.
  Failure in an enabled job fails that job. Check real Codex sandbox enforcement,
  login-shell child environment, hooks, paths and HTTP bind behavior on each target.

Reports retain a stable requirement ID, profile, policy parameters, pass/fail/not-applicable/
skipped/unobservable status, evidence and reproducer. Core skipped/unobservable cases
prevent a complete core-conformance claim. CONFORMANCE.md gains evidence only after the
implementation and named test exist and their recorded run passes.

## Performance and release gates

Measure real wall time and process memory while driving simulated peers; virtual time
is for behavior, not a speed result. Run fixed 1,000-session scenarios with bounded input,
output, event queues and retained telemetry, plus repeated session churn to expose leaks.
Report startup-to-ready time, idle and peak RSS, incremental bytes per live session,
allocation/collection data, owner tick latency distribution and sustained completion rate.
Separate active-session cost from retained retry/history data.

Record hardware, OS, compiler, lock file, backend, fixture sizes and repetitions. Establish
repeatability and a reviewed baseline before selecting regression thresholds; an unmeasured
threshold cannot gate a release. CI runs the same scenario and fails on its reviewed budget
or statistically supported regression. Report a 1,000-session simulated result as such,
not as proof of 1,000 external Codex processes.

CI also rejects warnings, missing .mli files, unused code, unsafe casts, partial core
operations, accidental object/Lwt/Async dependencies, and unformatted source. Structural
checks inspect syntax and module reachability, not comments containing prohibited words.
Linux musl must pass actual artifact linkage inspection and clean-host execution; macOS
ships a native executable using the platform runtime. Both still require the documented
external Codex and POSIX shell. No static, performance or host-safety claim precedes those
checks.

Sampled properties, fuzz coverage and finite simulation establish tested evidence, not
proof. A remaining algebra or ownership doubt is recorded with its counterexample search
and scope; propose Rocq/Lean only for a named unresolved law or invariant and let the user
choose that work.
