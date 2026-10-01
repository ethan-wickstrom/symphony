val tests : unit Alcotest.test_case list
(** Frozen settings/environment examples, checked keys and identity observables.
*)

val properties : QCheck2.Test.t list
(** Constructor model, repeated observations, and later-input independence. *)
