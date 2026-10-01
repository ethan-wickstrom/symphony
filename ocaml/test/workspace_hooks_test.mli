(** Observable interpreter traces over fake process capabilities and Eio mock
    clocks, including result/error mapping, cleanup and exception precedence. *)

val tests : unit Alcotest.test_case list
