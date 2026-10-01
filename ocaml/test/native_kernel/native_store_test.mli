val suite : unit Alcotest.test_case list
(** Observable ownership, lifetime and replacement attacks against production
    Store/Path sources. Closure faults occur only after the actual Path has
    canceled/joined its real loans, and cannot skip safe directory removal. *)
