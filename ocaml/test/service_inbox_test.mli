(** Public Inbox laws against an independent integer/list/status model. Real
    Eio_mock controls check single-domain wake/recheck and publication from a
    protected finalizer after owner failure. They do not attest Service's
    complete resource registry or native process closure. *)

val tests : unit Alcotest.test_case list
val properties : QCheck2.Test.t list
