val tests : unit Alcotest.test_case list
(** A pure settings fixture observes provider forwarding; it has no tracker IO.
*)

val properties : QCheck2.Test.t list
