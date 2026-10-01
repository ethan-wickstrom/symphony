# Symphony in OCaml

Checked workflow loading, configuration, strict prompt rendering, last-good reload
and native owned workspaces/hooks are implemented. `doctor`, `dry-run` and
`workspace` work locally. Scheduling and app-server integration arrive in later
slices; this executable does not dispatch issues yet.

## Build

Install opam, a C compiler, pkg-config and GMP development files. From this directory:

```sh
opam switch create . ocaml-base-compiler.5.5.0 --no-install --yes
opam pin add yaml.3.2.0 ../vendor/yaml --no-action --yes
opam pin add crowbar.0.2.2 ../vendor/crowbar --no-action --yes
opam pin add eio.1.6 ../vendor/eio --no-action --yes
opam pin add eio_posix.1.6 ../vendor/eio --no-action --yes
opam install . --deps-only --locked --with-test --with-dev-setup --yes
opam exec --switch . -- dune build @all
```

All four pins are mandatory: YAML releases native parser/events and preserves
embedded NUL bytes; Crowbar fixes a random-input refill hang. Eio resumes callers
when worker acquisition fails; Eio POSIX retains child identity through cleanup.
The executable uses the POSIX backend on both target platforms.
[YAML provenance](../vendor/yaml/PATCHES.md),
[Crowbar provenance](../vendor/crowbar/PATCHES.md),
[Eio provenance](../vendor/eio/PATCHES.md). The lock records exact
transitive versions and excludes machine-specific local URLs. Pin these sources
before installing. macOS builds a native binary; fully static Linux musl
artifact verification remains a release gate.

## Inspect a workflow

For the bundled offline examples, use a fixture credential:

```sh
LINEAR_API_KEY=fixture _build/default/bin/main.exe doctor examples/WORKFLOW.md
LINEAR_API_KEY=fixture _build/default/bin/main.exe dry-run examples/WORKFLOW.md --issue examples/issue.json
LINEAR_API_KEY=fixture _build/default/bin/main.exe workspace examples/WORKFLOW.md --issue examples/issue.json
```

For a real configuration, supply the Linear credential through the explicit
`$LINEAR_API_KEY` reference and set the project slug/state lists in the workflow.
`dry-run` reads normalized issue JSON from a local file; `--attempt 2` renders a
retry. Fixtures require an explicit `dispatchable` boolean. Nullable `assignee_id`
is preserved for templates; unusable optional metadata becomes null.
Relative workspace paths anchor to the selected workflow directory.
The command and hook strings remain verbatim trusted configuration.

`workspace` validates ownership under the persistent key lock and reports an
informational label or absence. It never creates directories or runs hooks. A busy,
foreign, unowned or displaced directory returns an actionable error. The label
grants no launch authority; only scoped acquired paths can launch native processes.

## Check

`just check` runs builds, examples/model properties, CLI integration, formatting,
source gates, protocol snapshots and watchdog-bounded native ownership/hook suites.
The native suites include 1,000 seeded lifetime scenarios with replay via
`SYMPHONY_LIFETIME_SEED`. Retained logs/manifests are in `_build/native-evidence`;
optimized Python checks have a separate directory. `just fuzz` runs the seeded Crowbar
campaign. Without `just`, use the commands in [justfile](justfile).

The source gate parses OCaml ASTs, checks interface pairs and rejects prohibited
APIs/object syntax. It is not a proof of exception-freedom or resource safety.
Third-party dependencies are outside its scope. All enabled compiler warnings are
fatal; warning 42 alone is disabled because it asks for pre-4.01 compatibility.

The [design](../docs/design/README.md), [decisions](../docs/decisions.md),
[validation](../docs/slice-1.md) and [conformance map](../CONFORMANCE.md) distinguish
working behavior from future release requirements.
