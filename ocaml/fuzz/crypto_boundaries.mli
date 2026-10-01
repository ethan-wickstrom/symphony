(** Pure crypto rejection boundaries, with no crypto RNG initialization or I/O.
*)

val register : unit -> unit
(** Register three curve campaigns and one RSA verification campaign. Arbitrary
    octets, signatures and [Message] payloads have at most 256 bytes. Curated
    empty/zero/one inputs and both compressed point prefixes remain reachable
    alongside arbitrary inputs.

    For P256, P384 and P521, short compressed encodings return [Invalid_format]
    from public decoding and fixed-scalar DH exchange. Accepted public encodings
    are stable under compressed decode/encode; shared coordinates have the
    curve's byte length. RSA PKCS1/PSS verification returns a boolean, and
    curated malformed and zero/one signatures reject.

    Fixtures pass the public smart constructors. Expected errors remain values;
    every escaped exception fails the campaign. These sampled laws do not prove
    cryptographic correctness. *)
