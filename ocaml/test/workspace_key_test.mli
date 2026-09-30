val tests : unit Alcotest.test_case list
(** Golden vectors generated with Python hashlib and explicit boundary cases. *)

val properties : QCheck2.Test.t list
(** List-model agreement and sampled identity, canonicalization, and order laws.
*)
