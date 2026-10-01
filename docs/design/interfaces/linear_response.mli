(** Redacted GraphQL envelope boundary; provider messages are never diagnostic
    text. Parse errors before accepting any data, including non-success HTTP. *)

val parse : status:int -> body:string -> (Json.t, Tracker_error.t) result
(** Success requires HTTP 2xx, no GraphQL errors, and an object data field. HTTP
    429, or HTTP 2xx/400 with a nonempty errors array containing
    extensions.code=RATELIMITED, returns Tracker_rate_limited. Other non-success
    HTTP returns Tracker_status; malformed/partial successful payloads return
    Tracker_response.

    Adding usable data to an error envelope cannot turn failure into success.
    Malformed successful payloads never escape as exceptions. Returned data is
    checked Json.t; raw response bytes and provider error messages are
    discarded. *)
