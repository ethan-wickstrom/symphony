val parse : string -> (Issue.t, string) result
(** Local dry-run input only: §4.1.1 normalized issue JSON, not a tracker
    payload. Required id/identifier/title/state strings are checked by
    Issue.parse. *)
