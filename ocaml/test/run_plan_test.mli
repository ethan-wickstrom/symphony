val tests : unit Alcotest.test_case list

val properties : QCheck2.Test.t list
(** Frozen binding/root/hooks/environment, no effects during planning, unnamed
    reference rejection, named request rejection and checked identity laws. *)
