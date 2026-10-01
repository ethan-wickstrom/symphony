val tests : unit Alcotest.test_case list
(** Regression laws for the crypto operations reached by TLS/X509.

    For checked RSA keys and signature integers [0] and [1], PKCS1/PSS
    verification returns [false]; raw transformation raises only its documented
    [Insufficient_key] exception.

    For each NIST curve, both compressed prefixes and every short coordinate
    length return [Error `Invalid_format] from public-key decode and exchange
    under the locked upstream profile. A correctly sized compressed point
    decodes and exchanges successfully.

    These are rejection laws, not a proof of constant-time implementation. *)
