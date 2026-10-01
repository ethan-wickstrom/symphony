val tests : unit Alcotest.test_case list
(** Ordered full snapshots, exact identities and duplicate-error precedence. *)

val properties : QCheck2.Test.t list
(** Sampled constructor/list-model, lookup, retraction and failure-absorption
    laws. Fixtures enter through Issue.parse once before batch operations. *)
