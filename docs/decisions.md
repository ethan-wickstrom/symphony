# Decisions

Status: P01–P08 and D01–D13 accepted by the user on 2026-09-30.
Linear is the first adapter. Deploy and develop on macOS; also produce a static
Linux musl release. Component signatures, laws and package recommendations are approved.

Development destination: `ethan-wickstrom/symphony` only. `origin` is the sole Git
remote and the GitHub CLI default; GitHub operations also name this repository
explicitly. Clone hooks, PR cleanup and package metadata use this destination.
Upstream specification links remain provenance, never publication targets.
The user detached the GitHub fork; the API confirms `isFork=false` and `parent=null`.

Evidence baseline: [SPEC.md](../SPEC.md) at upstream commit
`be10a1b79df723d6d7612b5651c8522704dafb2e`, checked against live upstream main.
The full specification and both READMEs were read before this audit.
Protocol evidence: installed Codex 0.159.2 generated schemas, compared with the retained
0.153.4 baseline, and
[current app-server documentation](https://developers.openai.com/codex/app-server/).

## Spec summary

Symphony is a tracker reader and agent scheduler. Its eight components are the
workflow loader, typed config layer, tracker adapter, orchestrator, workspace manager,
agent runner, optional status surface, and logging. Repository-owned WORKFLOW.md
supplies configuration, hooks, and a strict issue/attempt prompt. Changes reload
without restart; failed loads retain the last good configuration and emit an error,
while dispatch preflight blocks new work until the workflow is valid.

One authority owns polling, claims, running workers, retries, reconciliation, and
metrics. Internal states are Unclaimed, Claimed, Running, RetryQueued, and Released;
Claimed is derived from Running or RetryQueued. Attempts prepare a workspace, build
a prompt, launch and initialize the agent, stream turns, and finish with success,
failure, timeout, stall, or reconciliation cancellation. A clean worker exit schedules
a short continuation retry, not permanent completion. Failures use capped exponential
backoff. Workers continue on the same thread while issues remain active and routable,
subject to the turn limit. Reconciliation precedes dispatch and refreshes full snapshots.

Section 9.5 requires three safety invariants: launch only with the issue workspace as
cwd; keep its normalized path inside the normalized workspace root as a directory
descendant; use only A–Z, a–z, digits, dot, underscore, and hyphen in workspace keys,
adding a stable original-identifier hash of at least 64 bits when sanitization changes
the identifier. Workspaces persist across runs; terminal observations trigger cleanup.
Tracker identity remains opaque. Tracker writes stay outside the orchestrator and are
typically performed through agent tools. Tracker credentials stay out of the child environment.

## Every literal implementation-defined occurrence

There are 15 case-insensitive occurrences, counting the definition, duplicate cheat-sheet
entries, the population heading, and the repeated failure description.

| ID | Occurrences in SPEC.md | Accepted choice |
| --- | --- | --- |
| Definition | Normative Language, lines 12–14 | Keep selected policies here and in the appropriate adapter/release profile. |
| P01 | Approval default: §5.3.6 line 480; §6.4 line 628 | `never`; deny unexpected approval requests. Do not auto-approve sandbox escapes. |
| P02 | Thread sandbox default: §5.3.6 line 482; §6.4 line 629 | `workspace-write`; supply the checked workspace as cwd. |
| P03 | Turn sandbox default: §5.3.6 line 484; §6.4 line 630 | `workspaceWrite`, current issue workspace as the sole additional writable root, network off, both temporary-root exclusions on. Explicit workflow overrides remain schema-validated. |
| P04 | Workspace preparation: §9.2 line 886; population heading/body: §9.3 lines 888, 892; population failure: §14.1 line 1646 | Hooks own VCS/bootstrap; no built-in checkout or destructive reset. Remove an owned newly created directory after failed preparation, using the cleanup hook contract. Preserve reused workspaces. |
| P05 | Approval/sandbox/user input behavior: §10.5 line 1067 | Apply P01–P03. User-input and elicitation requests immediately end the attempt with an explicit reason. Cancel elicitation using its valid response, including experimental device-verification requests; never fabricate answers or proofs. Unsupported tools return protocol-valid failure and the session continues. No extra indefinitely blocked claim state. |
| P06 | In-memory timestamp type: §11.3 line 1272 | Abstract UTC instants backed by Ptime; separate monotonic instants and duration units. Wall time never schedules retries or measures elapsed runtime. Package feasibility remains to be checked. |
| P07 | Human-readable status: §13.4 line 1414 | Minimal server-rendered `/` in the requested HTTP slice, using the same snapshot as JSON. No separate TUI or compiled browser application in core. |
| P08 | Human-readable rate limits: §13.5 line 1448 | Preserve the latest protocol payload, including nullable model/quota metadata; show bounded formatted JSON initially. Do not infer recovery from reset times or percentages. Account-read permission fields remain distinct from notification data. |

P03's accepted generated-schema-valid turn policy is:

```json
{
  "type": "workspaceWrite",
  "writableRoots": ["<absolute checked issue workspace>"],
  "networkAccess": false,
  "excludeSlashTmp": true,
  "excludeTmpdirEnvVar": true
}
```

The default policy's writable root is filled from the checked workspace capability for
every turn request, including continuations. Explicit operator overrides retain their
schema-valid mode and roots, which may grant broader access. Thread defaults must not
silently broaden the selected turn policy.
This wire shape does not prove OS enforcement, broad-read restriction, or immunity to
filesystem mutation. Target-host tests must verify actual behavior. Package downloads
require an explicit network-enabled workflow policy or a trusted preparation hook.

## Other choices the spec leaves open

§5.2 says "starts with `---`" without naming a delimiter line. Require an
unindented line whose trimmed contents are exactly `---` at both boundaries;
`---instructions` remains a prompt. This follows Markdown front-matter intent
and avoids treating ordinary prompt prefixes as YAML. Suggested wording:
"If the first line is an unindented `---` delimiter, parse until the next such
delimiter line as YAML front matter. Trailing whitespace and CRLF are allowed."

These are not additional literal implementation-defined occurrences.

| ID | Source | Accepted choice and reason |
| --- | --- | --- |
| D01 | §5.3.1, §11.2 | Require explicit active and terminal state lists for the first adapter. Do not guess provider-specific workflows. Reject overlapping normalized state sets. |
| D02 | §17.2 | Physically resolve the configured root. Fail on non-directory or symlink managed workspace entries, dot/dot-dot keys, overlong names, or failed containment. Never replace an existing path. Ordinary repository symlinks remain permitted under the selected sandbox. Keep unchanged valid identifiers' keys unchanged. |
| D03 | §4.2, §9.5 | Changed keys append a hyphen and the first 128 bits of SHA-256 over the original identifier bytes, encoded as lowercase hex. Protected ownership metadata binds the opaque issue ID, original identifier and tracker scope, detecting historical identifier reuse, hash/literal and filesystem aliases before reuse. Collisions fail safely. |
| D04 | §5.3, §6.1 | Ignore unknown core keys and preserve adapter-owned provider keys. Expand explicit environment references and filesystem paths only; preserve shell commands verbatim. Duplicate YAML mapping keys fail instead of selecting a parser-dependent winner. |
| D05 | §5.4 | Empty prompt uses the spec's literal minimal fallback. Missing/invalid workflow never falls back. Unknown template variables and filters fail the affected attempt. |
| D06 | §11.1, §11.3–11.4 | Omit malformed state-list records with a warning; malformed requested ID records fail the atomic refresh. Normalize optional metadata to null/empty, deduplicate labels, and retain every required normalized field. Use the listed stable error categories. |
| D07 | §9.4, §10.1, §15.3–15.4 | Trusted shell execution is confined to one module using argument arrays for `bash -lc`. No issue data interpolation. The environment supplied to the shell is allowlisted and excludes all adapter-declared secret names; hooks use the same input environment. Login initialization is trusted configuration and must not restore excluded secrets. Target-host checks verify the resulting agent environment. Permitted nonsecret variables are documented. |
| D08 | §13.1–13.2 | Structured `key=value` stderr logs; escaped values, redacted secrets, bounded hook and diagnostic output. Remain quiet when idle. Log sink failure never controls scheduling. Exact size bounds are selected and justified with the logging interface. |
| D09 | §13.7 | Loopback HTTP, all three baseline API routes, minimal `/`, coalesced refresh triggers, JSON error envelopes and 405 responses. Listener configuration changes require restart. |
| D10 | §6.2, §10.5, §11.2 | Tracker kind/scope changes drain old-scope runs before new-scope admissions, release old retries, and preserve workspaces. Existing sessions retain their adapter/tool/auth snapshot through termination. Never refresh an old ID through a new provider or scope. |
| D11 | §6.2, §8.3 | Admission limits: no launch can exceed current global or per-state capacity; existing sessions may temporarily exceed newly reduced limits or moved state buckets. Accepted in place of the original stronger after-every-step limit assertion. Test every admission and prevent launches into saturated buckets. |
| D12 | §10.5, §18.2 | Defer provider-native tools until core conformance. Implement unsupported-call responses in core. Any later tool extension has its own scope and authorization profile. |
| D13 | Codex 0.159.2 InitializeCapabilities | Use `experimentalApi=false` and `explicitGatewayOauth=true` for the owned subprocess. The latter selects explicit login for its gateway runtime; later connections cannot undo it. Require authentication provisioning outside runs; Symphony does not initiate gateway login or device enrollment/verification. Verify target-host behavior. |

The user selected Linear first, macOS deployment/development, and Linux static release.
The macOS deliverable is a single native executable using the platform's system runtime;
the Linux musl deliverable must pass an actual static-link artifact check. Do not claim
that macOS supports the same fully static linkage.

## Gaps and proposed specification wording

### Reload validity and last-good settings

Sections 5.5 and 6.3 block new dispatch on an invalid workflow, while 6.2 retains
last-good settings. They can be implemented together; configuration and dispatch
readiness must remain distinct facts.

Proposed wording: “An invalid reload preserves last-good effective settings for existing
work and reconciliation, while blocking all new-dispatch paths, including retry dispatch,
until a valid load succeeds.”

### Retry prose versus reference algorithms

Section 7.3 describes refreshing active candidates, but 8.4 and 16.6 specify ID refresh.
Section 16.6 omits the explicit terminal cleanup in 8.4. Follow 8.4's ordered branches:
ID refresh, missing, terminal with cleanup, inactive/unroutable release, capacity requeue,
then dispatch.

Proposed wording: “Retry timers refresh the specific dispatch ID. Terminal snapshots
trigger workspace cleanup before claim release. Capacity rejection requeues; eligibility
rejection releases.”

### Ownership during asynchronous work

Popping a retry entry before its asynchronous refresh completes would remove its owner
from derived `claimed = running IDs ∪ retry IDs`. Keep it owned until the refresh result
causes dispatch or release. Timer, fetch, and worker events need attempt/config generation
identities so delayed events cannot affect a newer attempt. This is a design consequence
of asynchronous effects, not a new tracker policy.

### Workspace aliases and mutable filesystem state

The allowed character set admits `.` and `..`. Case-folding filesystems alias otherwise
distinct identifiers. A changed identifier's suffixed key may equal an unchanged literal
identifier. Hashes provide collision resistance, not injectivity.

Proposed wording: “Workspace keys MUST be nonempty single directory components other than
`.` and `..`. Workspace reuse MUST verify original identifier ownership and physical
containment; aliases or unsafe filesystem entries MUST fail without replacement.”

A parsed pathname alone cannot prove containment after a hook or external process changes
the filesystem. The workspace module must own the OS checks, directory identity, lifetime,
and launcher integration. Its invariant must describe the threat boundary it can enforce.
Do not claim safety by construction from an abstract string.

### Concurrency after reload or state changes

The spec requires updating future admission decisions, without requiring existing sessions
to restart. A lower cap or a refreshed state can exceed the new capacity. D11 selects
admission semantics; tests must state that law rather than impose active cancellation.

Proposed wording: “Concurrency caps govern admission. A new dispatch MUST satisfy both caps.
Existing workers MAY exceed a newly lowered cap or a changed per-state distribution; no
new work may enter a saturated capacity bucket.”

### Blocker metadata

Best-effort `blocked_by` is not necessarily a partial order: references can be absent or
cyclic. The core must use adapter-derived `dispatchable`. Topological sorting is justified
only inside an adapter whose profile defines reliable blocker semantics and cycle handling.

### Portable conformance observability

The spec does not standardize a fake tracker, deterministic clock control, or a mandatory
status interface. Internal typed errors, timers, and totals are not all observable through
the existing mandatory external contract. A portable harness therefore needs a documented
driver manifest: implementation launch/readiness, tracker fixtures, target protocol,
supported policy profile, and observation channel. White-box laws remain a separate layer.
Inapplicable optional checklist items are reported as not applicable, not passed.

### Static binary scope

The release target must be selected before claiming static linking. The single Symphony
binary still launches an external Codex executable and a POSIX shell; Git is needed only
when the workflow uses it. Static-link feasibility and native TLS/Eio dependencies require
a target-specific artifact check. Linux musl static release and macOS native deployment
are accepted targets; dependency and packaging details remain under review.

## Protocol audit

Regenerated with installed Codex 0.159.2 on 2026-09-30:

```text
codex app-server generate-json-schema --out /private/tmp/symphony-protocol-audit/0.159.2/stable
codex app-server generate-json-schema --experimental --out /private/tmp/symphony-protocol-audit/0.159.2/experimental
```

- AskForApproval, SandboxMode, SandboxPolicy, approval/input responses, dynamic-tool
  call/results, and thread token accounting are unchanged from 0.153.4.
- Stable ThreadStartParams AskForApproval still admits `untrusted`, `on-request`,
  `never`, or an object with `granular`. The Elixir README's `reject` shape remains invalid.
- Stable SandboxMode still admits `read-only`, `workspace-write`, and `danger-full-access`.
- TurnStartParams defines workspaceWrite temporary exclusions as false by default;
  P03 sets them explicitly to true.
- Stable generation excludes dynamicTools; experimental generation includes it.
  Any later provider-tool extension must explicitly opt into and pin that surface.
- The stable inbound request union still contains tool calls and MCP elicitation:
  `experimentalApi=false` does not remove the obligation to answer requests safely.
- Interrupted turn outcomes can carry errors. Preserve their optional error details;
  `flexUnavailable` and `tooManyDenials` are valid protocol failure reasons.
- Permissions-request cwd now references LegacyAppPathString, not AbsolutePathBuf.
  Never promote a server-supplied path to a checked Workspace_path. This is a wire-type
  change, not evidence of weaker runtime sandbox enforcement.
- disabledPluginIds records a list but explicitly does not filter plugin capabilities.
  It cannot implement tool isolation, session tool allowlists, or secret protection.
- thread/rollback is absent in both profiles. Do not add it or an obsolete fallback.
- The proposed portable conformance profile will record the targeted Codex schema/version
  and test the updated terminal outcomes, metadata, and request policies. No additional core
  methods or orchestration states are needed.
- Protocol schema generation verifies shapes, not transport scheduling or sandbox enforcement.

The full delta inventory, artifact hashes, and proposed boundary cases are in
[protocol-audit.md](protocol-audit.md). The previous 0.153.4 bundles remain unchanged
at `/private/tmp/symphony-protocol-audit/{stable,experimental}` for comparison.

## Design reference access

The OCaml 5.5 [module/manual chapter](https://ocaml.org/manual/5.5/moduleexamples.html)
was read, including functors and sharing constraints. The original unversioned URLs
were unavailable. The user supplied the [full Algebra-Driven Design manuscript](https://github.com/isovector/algebra-driven-design/tree/118aa81a48fb46255dfe4503cbcdee6d893098c9/prose),
replacing the initial sample-only reference. The main prose chapters have been read;
[coverage and concrete corrections](design/book-review.md) distinguish that review
from building the book or companion code. The user's algebra rules remain requirements.

## Toolchain and dependencies

The user approved these choices with the component design. Slice 1 has an isolated
project switch, package file and transitive lock. Future HTTP/TLS/workspace packages
remain planned until their slice needs them.

Use dedicated project OCaml **5.5.0** switches for macOS and Linux musl. This host's
PATH compiler is 5.5.0, while its unrelated `ortac-tools` opam switch is 5.3.0. Both
checked the original interfaces. The project switch now builds the slice 1 dependency
stack; the existing switch remains untouched. Pin the compiler, opam repository revision, package
versions and source digests in the release build record.

Dune builds; opam manages packages. Current `opam lock --help` names the artifact
`symphony.opam.locked`, not `.opam.lock`. Resolve/install the approved set in a clean
switch, then generate the real lock including test/dev dependencies. CI installs
with the lock and rejects drift; preserve target-conditioned entries/source metadata
and run a fresh solve/build on both targets. Dune's `dune.lock` belongs to its separate
package manager and is not the selected management workflow.
[Dune locking documentation](https://dune.readthedocs.io/en/stable/explanation/lockdir.html),
[opam lock](https://opam.ocaml.org/doc/man/opam-lock.html)

Approved direct runtime package families:

| Package | Purpose / why a smaller substitute is insufficient |
| --- | --- |
| `eio`, `eio_posix` | Structured direct-style concurrency with one POSIX backend on both hosts. Pin both 1.6 sources: worker-admission errors resume the caller; process identity survives exit observation until cleanup/reap. `eio.mock` ships in `eio`; no second scheduler or mock package. See `vendor/eio/PATCHES.md` for the narrow delta and host evidence. |
| `yaml` | Existing parser with positioned event/scalar access and vendored static libyaml archive. Audited 3.2.0; wrap events to preserve kinds/precision and validate complete input, duplicates and bounded aliases. |
| `jingoo` | Existing template parser/interpreter, behind one bounded strict Jinja wrapper. Audited 1.5.4. No full Liquid claim; see the template choice below. |
| `re` | Direct import of Jingoo's existing dependency for literal replacement at the template boundary. Use `Re.str` only; no user regular expressions or regex core logic. Pinned 1.14.0. |
| `yojson` | Existing JSON parser/encoder. Lexeme-preserving checked wrapper for exact numbers, duplicate keys, UTF-8, size/depth and standard JSON. Locked 3.0.0. |
| `ptime` | Parsed RFC 3339/UTC values and range-checked wall projection; no ambient clock inside domain code. Locked 1.2.0. |
| `zarith` | Exact natural token/runtime totals, preserving monoid laws beyond machine integer range. Locked 1.14; its GMP static archive must pass Linux artifact checks. Avoid saturation or hand-written big integers. |
| `digestif` | SHA-256 workspace suffix/ownership digest, not Stdlib MD5. Slice 2 pins 1.3.1; eqaf 0.10 is its transitive equality helper. The selected certificate/TLS stack also requires it. |
| `uucp` | Unicode lowercase/property tables for states/labels. Locked 17.0.0; already required by Jingoo. Normalization cases are tested. |
| `cohttp-eio`, `uri` | One existing HTTP client/server stack for Linear and the operator listener. Uri 4.4.0 is needed now to validate HTTPS endpoints; cohttp-eio 6.3.0 remains planned. No hand-written HTTP or GraphQL framework. |
| `angstrom` | Direct use of Uri's existing parser dependency for full-input URI/IPv6 parsing. A small raw-syntax guard rejects the malformed input that Uri canonicalizes. Locked 0.16.1; no HTTP implementation. |
| `tls-eio`, `tls`, `x509`, `mirage-crypto-rng` | Eio TLS flow, configuration, verified peer certificates/trust anchors and explicit seeded crypto runtime. Named direct imports even where transitively required. Candidate tls-eio/tls 2.1.3. Fail closed on trust/hostname errors; destination-bound credentials never redirect across origins. |
| `cmdliner` | Existing argument parsing, help and exit handling for run/doctor/dry-run; locked 2.1.1. |

Do not call `ca-certs`' ambient helpers: its
[interface](https://github.com/mirage/ca-certs/blob/v1.0.3/lib/ca_certs.mli) explicitly
uses global environment/OS detection and `Ptime_clock.now`. The small trust-loading
boundary instead reads host-selected PEM bundles through the supplied filesystem
capability, parses with X509, and uses the supplied clock for validation. Honor
explicit host environment/settings from the captured snapshot, with an actionable
missing-bundle error; pin macOS/Linux defaults in the target profile. No replacement
certificate or TLS implementation. This avoids one direct package and preserves
capability control.

The TLS family is the largest dependency cost; preserving HTTPS verification is preferable
to replacing it with custom cryptography or a shell network helper. The driver alone
sees these types. Stdlib handles UTF-8 validation/decoding; do not add `uutf` solely
for that. Scalars remain exact through parsing and JSON output.
[Cohttp Eio API](https://mirage.github.io/ocaml-cohttp/cohttp-eio/Cohttp_eio/Client/index.html),
[TLS package](https://opam.ocaml.org/packages/tls-eio/),
[Certificate validation](https://mirleft.github.io/ocaml-x509/doc/),
[Zarith](https://opam.ocaml.org/packages/zarith/),
[Stdlib UTF-8](https://ocaml.org/manual/5.5/api/String.html#utf8)

Build/test/dev entries each have one purpose:

| Package/tool | Purpose |
| --- | --- |
| `ocaml`, `dune` | Compiler and build graph; locked compiler 5.5.0 and Dune 3.24.0. |
| `alcotest` | Named Section 17 examples and retained regressions. |
| `qcheck-core` | QCheck2 properties, shrinking and independent model comparisons; no OUnit or extra state-machine framework. |
| `crowbar` | Native fuzz targets/corpus runs; AFL instrumented Linux campaigns after an instrumentation smoke check. |
| `ocamlformat` | Formatting gate, installed in the project switch and locked to 0.28.1. |

No Base/Core application framework, PPX derivation, regex dependency for core logic,
database, frontend toolchain or extra queue package. Reuse Stdlib Map/Set/List with
explicit named orders. Third-party transitives are locked and inventoried; package
presence of `lwt-dllist` is not Lwt concurrency, but no Lwt/Async runtime may be linked.
Slice 1 resolver/build/format checks pass locally. Static TLS/native stub linkage
and the future dependency families remain unverified.

### Strict template choice

The audited `liquid_ml` strict flag tightens syntax but does not reject missing variables;
it also exposes loader/callable effects and adds a large Base/Core dependency stack.
It does not meet this boundary as-is. Recommend the smallest wrapper around Jingoo:
AST allowlist, strict root/property/index lookup with missing distinct from known null,
explicit fresh contexts, finite pure filters, and fuel/output/depth limits. No custom
parser, template loader, interpreter fork, arbitrary functions, clock or filesystem.

The supported dialect is bounded Jinja, covering the reference workflow. Liquid is
sufficient under §5.4, not mandatory; do not claim Liquid compatibility. Empty template
renders empty; Config_layer selects the literal fallback before compilation.
The [interface](design/interfaces/template.mli), [laws](design/algebras.md) and
[implementation/test design](design/testing.md#strict-bounded-jinja-profile) are the
reviewable proposal. If implementation cannot enforce those semantics with the public
library API, stop and revise the interface/choice before introducing a workaround.

### Target constraints

macOS ships one native Symphony executable linked to platform system libraries.
Linux musl ships one actually static executable: no ELF interpreter or dynamic
requirements, clean-host startup and DNS/TLS/process/hook/API tests. Each architecture
has its own build/benchmark baseline; initially validate macOS arm64 and Linux x86-64.
The release still requires external Codex and Bash; workflow hooks may require Git.
CA trust/authentication are explicit host inputs, not magically supplied by static linking.
[Apple runtime/linking reference](https://developer.apple.com/library/archive/documentation/Porting/Conceptual/PortingUnix/compiling/compiling.html)

A pure abstract pathname cannot prove safety against filesystem replacement. A scoped
directory handle, atomic no-symlink acquisition, ownership lock/metadata, launch identity
check and protected-root host assumption form the documented boundary. No full hostile
process-tree isolation claim precedes a container/VM extension.

### Parser profile

YAML 1.2 core scalar kinds preserve quoted strings and exact numbers. Consume one full
mapping document; reject duplicate keys, unsupported application tags, cycles and exceeded
bounds. Resolve standard aliases/core tags within expansion bounds. The template's finite
filters are `length`, `join`, `lower`, `upper`, `trim`, `replace`, `default`; `default`
handles known null, never missing. Budget failures name the exhausted limit and remedy.
Input byte/depth/node/output budgets and Unicode normalization fixtures are selected with
slice 1/3 models before implementation; no undocumented magic constants.

## Slice 1 refinements

- Configuration requires pure adapter settings, not tracker IO. `Tracker.CONFIG`
  owns that contract; `Tracker.S` extends it with reads. First-class registry entries
  carry a generative `Type.Id` equality witness, so credentials participate in reload
  equality without casts, printers or a second parse.
- The host supplies an explicit environment snapshot, base directory and temp directory.
  Relative settings anchor to the selected workflow file. Path expansion runs once;
  resolved HOME contents remain literal. Trusted hook/agent strings are not expanded.
- YAML 3.2.0's streaming API lacks deterministic native destruction and truncates scalar
  values containing NUL. The small maintained patch adds scoped close and length-aware
  access, with regression tests. [Provenance](../vendor/yaml/PATCHES.md).
- Crowbar 0.2.2 undercounts bytes returned by a partial random refill, hanging the
  seeded campaign. A public-API regression times out before the one-line fix and
  completes afterward. The development-only pin retains source, license and
  [reproduction](../vendor/crowbar/PATCHES.md).
- Bounded Jingoo uses public AST/context APIs. Its finite profile rejects unsupported
  syntax instead of inheriting ambient functions or silently coercing numbers.
  [Interface and budgets](../ocaml/lib/workflow/template.mli).
- JSON numeric equality compares normalized coefficient/exponent values exactly,
  without expanding huge exponents. Typed YAML integers follow the 1.2 core schema;
  `1_7` is a string, not an integer. Numeric laws use a separate rational model.
- JSON composition charges wire bytes/nodes before encoding. A failing allocation
  regression exposed repeated checked children allocating an oversized output before
  rejection; streaming budget checks eliminate that allocation class.
- The actual dependency solve selects ocamlfind `1.9.9~preview`: the released 1.9.8
  metadata excludes OCaml 5.5.0. The lock records this choice. Both CI targets must
  build it before a portability claim.
- All enabled warnings are fatal. Warning 42 alone is disabled: it reports dependence
  on post-4.01 record/constructor disambiguation, which this OCaml 5 design uses.
  Partial/fragile matches and unused code remain fatal. Compiler-AST source checks
  supplement typing; they do not prove absence of all partiality or escaping defects.
- Exact counters remain unbounded internally. Decimal rendering is explicitly bounded
  before expensive conversion; token/runtime monoid laws do not saturate at machine size.
- `doctor` validates offline; `dry-run` renders a checked local issue fixture. These
  commands expose useful slice 1 behavior without pretending to run a live service.
- Offline fixtures require explicit boolean `dispatchable`; the fixture parser
  cannot infer tracker eligibility. The normalized projection includes all §4.1.1
  fields, including nullable `assignee_id`, with no tracker-specific accessor.

Native dependency pins are part of the source build, not optional local fixes. Their
URLs are excluded from the portable lock; setup and CI pin checked-in sources before
locked installation. No global opam switch is modified. The Elixir PR-description
validator accepts the review bot's complete badge region; all other HTML comments
and incomplete/repeated markers remain invalid.
