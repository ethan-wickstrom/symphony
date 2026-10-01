# H1 source custody

Upstream: [robur-coop/ocaml-h1](https://github.com/robur-coop/ocaml-h1),
version 1.1.1, commit `d5fff216c28fe379c3abaa355b679ffb35d98d07`.
The BSD license is retained in `LICENSE`. `SYMPHONY_SOURCE.json` records the
downloaded archive and every original file's SHA-256. No Git checkout is embedded.

Symphony uses only H1's public synchronous connection and body APIs. Its native
Eio driver owns networking, TLS, bounds, deadlines and cleanup. The upstream Lwt
examples and optional package are retained for source custody and are not runtime
dependencies of Symphony.

Three parser corrections in `lib/parse.ml`:

- Reject hexadecimal chunk lengths that overflow or decode to negative int64.
- Require exactly three status digits and a status in 100 through 599.
- Expose a pending parser failure before returning `Close` at EOF.

The public `Client_connection` regressions are
`ocaml/test/http_codec_test.{ml,mli}`; the wire model is
`ocaml/test/http_codec_model.{ml,mli}`. The unpatched source produced seven
failures among eleven examples. The patched source passes all eleven and 1,000
seeded list-model fragmentation cases (seed `20261001`) under OCaml 5.5.
These tests compile against public APIs; no private parser entry point is used.

The negative-size regression requires typed rejection of the known invalid
header prefix before receiving data or EOF. Angstrom already rejects some
negative-size cases after receiving data; the defect is allowing the invalid
size into body-parser state. Truncated bodies previously became successful EOF
or closed without their typed error. Both outcomes are regression failures.

No public API change, broad exception translation or framing wrapper was added.
The unmodified upstream parser rejects chunk extensions and trailers; this
patch does not claim to add that support. Input allocation, response limits,
TLS, redirects, callback-defect backtraces and deadlines belong to the native
driver and need separate tests.
