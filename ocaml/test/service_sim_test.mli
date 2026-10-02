(** Actual Service.Make scenarios over resource-owning Eio mock ports. The
    oracle sees only delivered Initial/Transition observations. Fake scopes
    certify their own closure; no native process/lease closure is claimed. *)

val tests : unit Alcotest.test_case list
val properties : QCheck2.Test.t list

val replay : seed:int -> prefix:int -> (unit, string) result
(** Replay the causal prefix and always run the joined shutdown tail. Negative
    seed/prefix values return [Error]. A scenario defect raises with its seed,
    prefix and ordered causal trace; it cannot be reported as success. *)
