# Symphony YAML patch

This directory is `ocaml-yaml` 3.2.0 from the maintainer's
[v3.2.0 release](https://github.com/avsm/ocaml-yaml/tree/v3.2.0).
The ISC license remains in `LICENSE.md`; bundled libyaml retains its own notices.

Source archive:

```text
https://codeload.github.com/avsm/ocaml-yaml/tar.gz/refs/tags/v3.2.0
sha256: 471f6582cf98e035df3f68bf98680fa60cc2a299b6d25dea6ad3ad7080518c14
```

`symphony.patch` contains the complete delta from that release. Pin the existing
`yaml.3.2.0` package to this directory. This is a dependency patch, not a new YAML
implementation.

The patch adds two public operations to `Yaml.Stream`:

```ocaml
val close : parser -> unit
val with_parser : string -> (parser -> 'a) -> 'a res
```

`close` releases native parser state once. Parsing a closed parser returns an
error. `with_parser` closes after successful return or a callback exception;
callback exceptions propagate. Legacy unscoped parser users have a finalizer.
The parser copies each successful native event before deleting its C storage.
Scalar copying uses the declared byte length, preserving embedded NUL bytes.
Unsupported version directives become expected parse errors.

Changed upstream files:

- `ffi/bindings/yaml_bindings.ml`: bind `yaml_event_delete`.
- `types/bindings/yaml_bindings_types.{ml,mli}`: expose the scalar pointer and
  length consistently. The matching interface is required by the package build.
- `lib/stream.ml`: scope parser/event ownership and copy scalar bytes by length.
- `lib/yaml.mli`: document the public parser lifecycle.

`ocaml/test/workflow_parser_test.ml` checks closed-parser behavior, idempotent
close, cleanup on a callback exception, and NUL scalar fidelity. These are
observable lifecycle regressions; they do not prove native heap leak freedom.
Native leak instrumentation is a separate release check.
