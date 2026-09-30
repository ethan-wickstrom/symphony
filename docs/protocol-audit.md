# Codex protocol refresh

Audited on 2026-09-30: installed `codex-cli 0.159.2`, compared with the retained
0.153.4 stable and experimental schemas. These are design findings, not passing
client integration tests. No OCaml client exists yet. P01–P08 and D01–D13 were subsequently accepted;
Linear and the macOS/Linux targets are recorded in decisions.md. Signature approval remains open.

## Reproduction and artifacts

```text
codex app-server generate-json-schema --out /private/tmp/symphony-protocol-audit/0.159.2/stable
codex app-server generate-json-schema --experimental --out /private/tmp/symphony-protocol-audit/0.159.2/experimental
```

Both generators exited successfully. A PATH-alias permission warning did not prevent
generation. The previous bundles remain at `/private/tmp/symphony-protocol-audit/stable`
and `/private/tmp/symphony-protocol-audit/experimental`.

| Profile | Previous files | Current files | Added | Removed | Structural changes | Description/title only |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Stable | 304 | 314 | 12 | 2 | 46 | 3 |
| Experimental | 416 | 440 | 26 | 2 | 60 | 2 |

Counts refer to files, including aggregates and repeated definitions. Comparison
ignores ordering within `required` and `enum`; it retains other array changes and
separately identifies description/title-only edits. Those edits can change semantics,
as the interrupted-turn error description demonstrates.

All 754 current JSON files parsed without duplicate keys or unresolved local `$ref`s.
This checks artifact integrity, not every JSON Schema constraint or runtime behavior.

Detailed changes: `/private/tmp/symphony-protocol-audit/0.159.2/schema-diff.json`.
File digests: `/private/tmp/symphony-protocol-audit/0.159.2/manifest.json`.
Bundle SHA-256 hashes:

```text
stable       9dec03ab74e2e8a8e3b2948594c7183ee0565c3df33c792ea78d387e6824e093
experimental b2e4fc9780cd9012e8c0353a0b2907395ff05504f6295f02664520cc1f6dc34e
```

Each bundle hash covers sorted records of relative filename, NUL, the raw file's
SHA-256 hex digest, and newline. Conformance fixtures will also record the generator
flags and initialization capabilities; experimental and stable profiles stay distinct.

## Changes affecting the planned client

Schema paths below are relative to either generated bundle unless stated otherwise.

| Evidence | Change | Design consequence |
| --- | --- | --- |
| `v2/TurnCompletedNotification.json`: `Turn.error`, `CodexErrorInfo` | Interrupted turns may carry errors; `flexUnavailable` and `tooManyDenials` are valid failure reasons. | Preserve optional remote error details on interruption. Keep the local cancellation reason separate. Both new codes enter the existing failure outcome; no new orchestrator states. |
| `PermissionsRequestApprovalParams.json`: `cwd` | Reference changed from `AbsolutePathBuf` to `LegacyAppPathString`. | Treat inbound cwd as untrusted wire data. Only the workspace manager can supply the launch capability. Neither old nor new string schema proves physical containment. |
| `v2/TurnStartParams.json`, `v2/ThreadStartResponse.json`: `disabledPluginIds` | Omitted/null preserves the saved list; `[]` clears it. The response explicitly says it does not yet filter plugin capabilities. | Never use this field to promise tool isolation or secret protection. Leave it outside the core policy mechanism. |
| `v1/InitializeParams.json`: `explicitGatewayOauth` | Selects explicit gateway OAuth login; later connections cannot undo it for that gateway runtime. | Propose setting it on the owned subprocess to avoid automatic browser authorization. External auth provisioning and unattended behavior need deployment validation; see accepted D13. |
| Experimental `McpServerElicitationRequestParams.json` | New `openai/userVerification` mode requires a challenge, title, and description. | Under accepted P05, respond with valid cancellation and fail the attempt. Never invent a device proof. Bound turn interruption and subprocess shutdown. |
| `v2/AccountRateLimitsUpdatedNotification.json`, `v2/GetAccountRateLimitsResponse.json` | Nullable `normalModelSlug`; new plan `promax`; account reads add nullable `ordinaryUsageAllowed`. | Preserve metadata. Null permission means unavailable; percentages/reset times cannot prove recovery. Do not fabricate that field on notifications, which lack it. |
| `v2/TurnStartParams.json`: `UserInput`; raw content definitions | Images can use `url` or `fileId`; raw content uses `image_url` or `file_id`. The schemas allow both representations together. | Keep core outbound prompts text-only. Inbound item decoding must accept file-only images and must not invent exclusivity. Dynamic-tool image results still use `imageUrl`; keep their encoder distinct. |
| `v2/ItemCompletedNotification.json`: MCP item metadata | Optional `mcpAppUi` includes a resource URI and presentation preference. | Observational metadata only; no browser execution or scheduler transition. |
| `ServerNotification.json` | Adds `thread/attachment/updated` and `account/gatewayOAuth/changed`. | Neither completes a turn. Distinguish observational notifications from lifecycle events. |

The proposed protocol boundary remains a narrow projection: typed IDs, request
correlation, lifecycle outcomes, token totals, safe request responses, and bounded
diagnostics. It does not need an OCaml mirror of every generated account, plugin,
history, or UI type. Known methods still require validation of the fields we consume;
an unknown notification cannot silently become a scheduler event.

## Policies and mechanisms that remain valid

- Approval values and response shapes are unchanged. `never` remains valid.
  The Elixir README's outer `reject` object remains invalid; the schema admits
  `granular` instead.
- Thread sandbox values remain `read-only`, `workspace-write`, and `danger-full-access`.
  Turn sandbox uses the distinct `workspaceWrite` tagged object. Proposed P03 still
  supplies the checked workspace, network off, and both temporary-root exclusions on.
- Both temporary-root exclusions default to false. Supply the policy explicitly on
  every turn, including continuations. `readOnlyAccess` is absent from these schemas.
- Command/file approvals, permissions responses, user-input responses, and dynamic-tool
  request/results are unchanged. Stable inbound requests still include tool calls and
  MCP elicitation; `experimentalApi=false` is not a substitute for handling them.
- `dynamicTools` declarations remain experimental. The deferred provider-tool extension
  would require a separate, explicitly negotiated experimental profile.
- Thread token-usage notifications are unchanged. Aggregate from absolute `total`
  counters with idempotent accounting; `last` is not another contribution.
- JSONL stdio framing and the initialize/initialized handshake remain the planned transport.
  No new core RPC is required by this update.

## Added, removed, and unused surfaces

Stable request additions are `account/gatewayOAuth/{read,login,cancel}` and
`thread/attachment/{add,list,remove}`. Experimental adds `userVerification/{status,enroll,
delete,verify,cancel}`, `memory/status`, and `rollout/compress` too. No top-level inbound
request method was added or removed.

`thread/rollback` and its parameter/result schemas were removed from both profiles.
Do not add a compatibility path. `thread/revert` remains a separate, unused operation.
The retained `threadRollbackFailed` error value does not establish method availability.

Other reviewed changes do not justify expanding the core:

- Thread originator and experimental environment metadata describe the thread;
  they do not prove connection health. Experimental daybreak settings and model access
  program metadata do not grant authorization.
- Item-history cursors now accept a string, an item anchor, or null. The item anchor's
  nonempty-turn requirement is documented in prose, not enforced by its local schema.
  If history becomes necessary, its boundary must enforce that cross-field requirement.
- Model names, service tiers, and some raw execution statuses remain open strings.
  Do not force them into the high-level turn-status enum.
- Personality is deprecated as a style control. Raw response items add configuration
  reasoning metadata. Neither belongs in scheduling policy.
- Managed configuration adds login/provider and browser/network requirements, and changes
  Windows sandbox requirements. A future doctor must honor managed restrictions; an
  empty allowed-login list permits none, while unavailable data is a separate case.
  Provider diagnostics must remain redacted. Experimental application-network domain
  requirements are separate from the turn command sandbox's `networkAccess` policy.
- Connector `omit_tools_from` controls model-facing exposure, not authorization or OS
  isolation. Guardian review paths also became legacy strings; review metadata cannot
  construct a trusted workspace capability.
- MCP resource targeting/status, plugin onboarding, feedback, account routing, and
  presentation metadata remain outside the requested agent lifecycle.

## Required tests when slice 5 starts

1. Decode completed, failed, and interrupted turns, with and without optional error
   details; include both new error codes and duplicate terminal notifications.
2. Answer approval, user-input, unsupported-tool, and elicitation requests with valid
   responses. Include experimental verification cancellation; verify bounded teardown.
3. Reject promotion of inbound permission cwd to workspace authority. Test the launcher
   against actual target-host path and sandbox behavior.
4. Encode the explicit turn policy on initial and continuation turns. Demonstrate that
   disabled-plugin metadata is never an isolation premise.
5. Decode nullable quota/model metadata and `promax`; preserve unknown availability.
   Do not synthesize account-read permission from notification percentages.
6. Decode file-only image items and new optional item metadata without changing text
   prompt encoding or the dynamic-tool image-result wire shape.
7. Keep new observational notifications out of terminal transitions. Fuzz all new
   alternatives alongside malformed frames, correlation IDs, and truncated JSONL.
8. Compare token accounting to its absolute-counter reference model under duplicates,
   out-of-order messages, and session changes.
9. Exercise the selected initialization capabilities and authentication behavior on the
   chosen host. Schema acceptance alone does not prove an unattended session.

These cases are proposed coverage, not tests that have already passed.

## Documentation discrepancies

The [official app-server documentation](https://developers.openai.com/codex/app-server/)
supports JSONL framing and explicit experimental negotiation. Its thread/start example
uses `workspaceWrite`, whereas the installed `SandboxMode` enum requires
`workspace-write`. The tagged turn policy uses `workspaceWrite` correctly.

The documentation still lists `thread/rollback`, now absent from both installed bundles.
It also labels some history methods experimental although the generated stable request
union contains them. Method presence alone does not prove runtime gating behavior;
integration tests must settle that if these unused methods become relevant.

Context7's official Codex index was checked. Its returned snippets predate these new
fields. Use the generated 0.159.2 shapes for this client target and live documentation
for behavior, recording conflicts instead of borrowing an obsolete example.
