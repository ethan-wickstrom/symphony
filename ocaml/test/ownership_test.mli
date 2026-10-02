val tests : unit Alcotest.test_case list
(** Equal-rank replacement, due/ID ties, refresh custody and retirement. *)

val properties : QCheck2.Test.t list
(** List-model agreement after each step of 2,000-operation streams, keyed
    replacement/removal laws, derived claims and retry-selection order laws. *)
