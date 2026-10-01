# Crypto dependency boundary

The previously locked Mirage1.2.0 family is affected by
[OSEC-2026-14](https://github.com/ocaml/security-advisories/blob/main/advisories/2026/OSEC-2026-14.md),
[OSEC-2026-15](https://github.com/ocaml/security-advisories/blob/main/advisories/2026/OSEC-2026-15.md) and
[OSEC-2026-17](https://github.com/ocaml/security-advisories/blob/main/advisories/2026/OSEC-2026-17.md).
TLS2.1.3/X5091.2.0 reach the RSA verification and NIST decode/exchange/scalar paths.
This is source reachability; constant-time behavior is not proved by sampled tests.

Keep `Native_http` and its expected-error classifier unchanged. Upgrade the four
Mirage packages together to2.4.1, retaining existing TLS/X509 versions if the actual
solver and builds agree. The release archive SHA256 is
`332886c365c6035077e3ce676a63da8f7500c15a1628b3c07e139b0e551f1f6f`;
the annotated tag peels to `1712bcb7b0b42ec3b67b3948d0e34b20beaf349b`.

## Laws and checks

`crypto_boundary_test.mli` states the RSA and NIST rejection laws. Test integer0/1
under PKCS1/PSS and documented raw failure. Exhaust both compressed prefixes and
every short coordinate length on P256/P384/P521, with valid compressed controls.
Retain old-version failures and repeat their input vectors after the upgrade.
The first2.4.1 run rejected short points as `Invalid_format`, whereas
the initial test expected `Invalid_length`. Pinned upstream `Point.of_octets`
classifies wrong-size compressed encodings as `Invalid_format`; align the law with
that checked result. This differs from1.2.0's escaped `Invalid_argument`.
Use the existing loopback TLS server to serve a same-size malformed
RSA certificate fixture: the client must return its checked failure, send no
credential and close the socket. No replacement DER parser or crypto implementation.

Run formatting, core/property/fuzz, CLI, source/protocol and native normal/optimized
gates, then hosted Linux/macOS checks. Independently review the lock and evidence.
Historical macOS1.2.0 recipe/link observations cannot certify a2.4.1 binary. Preserve
their provenance and require fresh qualification before any release claim.

Local validation passes:256 core tests (61 properties),83 native cases per mode,
63 CLI scenarios per mode,239 source/interface files,39 source controls and26
Crowbar groups ×10,000 inputs at seed20260930. The classifier control went red
before tightening the assertion; both malformed peers now return the exact TLS
diagnostic and reach raw socket EOF before fixture closure. The required Elixir
gate passes302 tests with six explicit skips, coverage/lint/format/Dialyzer green.
The archival materializer passes22 controls per mode and preserves all13 historical
recipes/profile bytes. [Observation and record hashes](crypto-security-observation.json).

Context7 returned unrelated entries in two Mirage library lookups. Pinned upstream
interfaces, changelog, archive metadata and official advisories supply the evidence.
