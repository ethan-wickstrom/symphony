# Symphony

An OCaml 5/Eio implementation of Symphony: tracker issues, isolated workspaces,
and coding agents, governed by explicit module contracts and executable models.
Development and pull requests belong to `ethan-wickstrom/symphony`.

Workflow loading, strict templates, last-good reload, owned workspaces and hooks
are implemented. The executable polls Linear and dispatches closed Codex
app-server attempts. Inspection commands validate workflows, render local issue
fixtures and inspect workspace ownership.

```sh
git clone https://github.com/ethan-wickstrom/symphony.git
cd symphony/ocaml
```

Follow the [locked build instructions](ocaml/README.md#build), then:

```sh
LINEAR_API_KEY=fixture _build/default/bin/main.exe doctor examples/WORKFLOW.md
LINEAR_API_KEY=fixture _build/default/bin/main.exe dry-run examples/WORKFLOW.md --issue examples/issue.json
LINEAR_API_KEY=fixture _build/default/bin/main.exe workspace examples/WORKFLOW.md --issue examples/issue.json
just check
just fuzz
```

For live dispatch, configure a workflow and run `symphony [WORKFLOW]` (the build
path is `_build/default/bin/main.exe`). The default is `./WORKFLOW.md`. SIGINT
and SIGTERM stop admission and join active resources before exit. See the
[operator instructions](ocaml/README.md#run-the-service).

Workspace inspection creates nothing and runs no hooks. Native ownership tests
exercise filesystem identities, permanent locks, process closure and cancellation;
seeded models and fuzz campaigns complement those tests.

[Conformance](CONFORMANCE.md) records working behavior and remaining requirements.
[Design](docs/design/README.md), [decisions](docs/decisions.md) and
[slice evidence](docs/slice-2.md) explain the contracts, laws and validation.
Authenticated Codex acceptance, the operator HTTP API and clean-host/static
releases remain delivery targets.

The [specification](SPEC.md) and [Elixir reference](elixir/README.md) retain source
provenance; they are not evidence that this OCaml port conforms.

[Apache License 2.0](LICENSE).
