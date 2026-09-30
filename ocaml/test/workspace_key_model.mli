(** Independent list-based key policy model; the SHA-256 primitive is shared
    with the implementation. Whole-output Python hashlib vectors independently
    check hash input, hex representation, and truncation. This is not an
    independent cryptographic implementation or an injectivity proof. *)

type error = Invalid_component | Too_long

val derive : string -> (string, error) result
(** Raw-byte model. Callers separately enforce the Issue_identifier boundary.
    Alphabet lookup, candidate assembly, and rejection operate on byte lists. *)
