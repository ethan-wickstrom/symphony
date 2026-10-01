val tests : unit Alcotest.test_case list
(** Public H1 connection regressions for malformed status, signed chunk sizes,
    EOF failure precedence, and valid fixed/chunked/close-delimited controls. *)

val properties : QCheck2.Test.t list
(** The parsed body agrees with a list model under arbitrary fragmentation.
    Parser-rejected messages never become a successful EOF outcome. *)
