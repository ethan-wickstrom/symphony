(** Observable scheduling coverage through actual checked Core commands:
    normalized required labels, creation-time/identifier ordering, Todo routing,
    current-policy capped exponential retries and attempts beyond sixteen. *)

val tests : unit Alcotest.test_case list
