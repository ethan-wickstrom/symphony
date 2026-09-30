# Slice 1: workflow boundaries

The executable loads a selected `WORKFLOW.md`, validates core/Linear settings,
renders checked local issue data, and exposes `doctor`/`dry-run`. The pure reload
function retains the last good config and reports invalid-load dispatch gating.
Scheduling, live tracker reads, subprocess launch and the filesystem watcher are
later slices. There is no fully conforming service or static release artifact yet.

## Composition and reading order

```text
main (captured environment + Eio filesystem)
  -> cli -> Workflow_loader.Make(Workflow_file)
         -> Workflow_document -> Config_value -> scoped libyaml events
         -> Config_layer.Make(Tracker_config)
              -> scheduling / workspace / agent settings
              -> first-class Linear_settings + generative Type.Id witness
         -> Template -> bounded Jingoo AST/interpreter
```

Start with the workflow, configuration and tracker interfaces, then
`config_layer.ml`, `workflow_document.ml`, and `fields.ml`. `domain/` owns checked
identities, exact totals, environment inputs and JSON. `io/` owns scoped file reads.
Template syntax/capability rewriting is confined to `template.ml`; its strict
finite dialect and resource budgets are documented in `template.mli`.

The first registry is settings-only. It implements `Tracker.CONFIG`, never a fake
network adapter. A live adapter later implements the larger `Tracker.S`; the same
configuration functor is instantiated over it. Registry-scoped `Type.Id` witnesses
prove existential settings equality, including credential changes, without casts
or parsing a second time. Orchestrator/adapter equalities remain unchanged.

## Models and laws

- Workflow parsing: independent generated typed trees/YAML printers and prompt line
  model; aliases agree with copied trees, duplicate keys fail, whole stream required.
- Reload: independent last-good/latest-error record; errors preserve effective config,
  valid loads clear gating, repeated equivalent valid settings are idempotent.
- State limits: independent list model; normalized valid collisions fail, invalid
  entries are ignored, blank required labels remain unmatchable.
- Template: finite independent AST interpreter, scope renaming, composition under
  common budgets, exact rational numeric oracle, strict missing/null distinction.
- Naturals/JSON: sum/delta model and monoid laws; JSON preserves decimal lexemes,
  exact numeric equality uses a rational oracle, object order is irrelevant.
- Registry: test-only settings profile observes the complete unknown provider tree.

Concrete laws sit beside operations in `.mli` files. Sampled properties are evidence,
not proofs. No Rocq/Lean proof is claimed for this slice.

## Validation record

Local target: macOS arm64, OCaml 5.5.0, Dune 3.24.0, ocamlformat 0.28.1. Independent
review observed failing regressions before path/coercion/policy/diagnostic fixes.
Core example/property tests, actual CLI/file IO, source gates, protocol snapshots,
formatting and the seeded Crowbar campaign are recorded in the final worklog.
The GitHub workflow defines Linux/macOS checks; hosted runs have not been executed.

`just check` passes: 66 tests (45 examples, 21 properties; 15,500 generated
cases), 14 actual CLI scenarios, 96 source/interface files, 34 source-gate controls,
formatting and generated policy snapshot checks. Crowbar seed `20260930` passes
13 groups × 10,000 invocations after all production fixes. Locked installation with both dependency pins
reports no changes. The campaign's random generator required a reproduced
[Crowbar fix](../vendor/crowbar/PATCHES.md); no parser exception is swallowed.

Native YAML lifecycle tests establish observable close behavior and NUL fidelity.
They do not prove native leak freedom. Linux leak instrumentation, instrumented AFL
coverage, static musl linkage and the whole-service simulation/benchmark remain gates.

## Boundary profile

Workflow/JSON inputs are at most 1 MiB; JSON depth is 64 and nodes 32,768. YAML
expansion is separately bounded. Numeric scalar coercion follows YAML 1.2 core:
decimal, hexadecimal and octal integer scalars; quoted integers are signed decimal.
`1_7` is a string, so it is rejected as an integer. This corrects an early assumption
about underscores. [YAML 1.2 core resolution](https://yaml.org/spec/1.2.2/#1032-tag-resolution).

Environment references are one pass. Typed string fields recognize whole `$NAME`
tokens. Paths additionally support embedded `$NAME`/`${NAME}`, then leading `~`;
HOME must be absolute and its contents are not expanded again. System temp is an
explicit host input. No core settings module calls `getenv`, the clock or filesystem.

Approval, thread sandbox and turn sandbox are independently validated against the
retained generated Codex 0.159.2 schema. A read-only thread alone does not override
the default workspace-write turn; supply an explicit read-only turn policy as well.
Schema-permitted unknown policy fields are retained; permission enforcement is
Codex's responsibility and requires later live integration tests.

Linear endpoints use ASCII RFC3986 syntax and fully consumed Uri parsing, with
a raw-syntax guard against the repairs Uri otherwise permits. Errors name the
provider key without printing endpoint/credential values. Tracker-kind errors
also omit substituted values. Explicit CLI attempt errors name `--attempt` and
the correction. Independent regressions verify these boundaries.
