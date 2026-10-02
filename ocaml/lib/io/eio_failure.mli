val leaves : exn * Printexc.raw_backtrace -> (exn * Printexc.raw_backtrace) list
(** Expand Eio cleanup aggregates into first-observed order. A leaf maps to a
    singleton with its saved backtrace; expansion distributes over nested
    aggregates. [Multiple] stores newest first; [Multiple_io] stores oldest
    first. IO leaves retain their error/context identities, though Eio rebuilds
    exception wrappers. No payload is rendered here. *)
