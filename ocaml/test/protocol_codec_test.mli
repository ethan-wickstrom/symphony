type fixture = { name : string; schema : string; value : Json.t }

val fixtures : unit -> fixture list
(** Actual codec output paired with the pinned generated schema filename.
    Includes full RPC envelopes and method-specific server-response results,
    with string IDs and both signed 64-bit endpoints. *)

val tests : unit Alcotest.test_case list
