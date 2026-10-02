(** Native HTTPS executable controls; no exported implementation.

    Rejected raw peers terminate with EOF or typed connection reset. Unrelated
    failures preserve exception identity and backtrace. Client TLS rejection and
    credential absence are independently required. *)
