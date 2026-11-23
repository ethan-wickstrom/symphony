(** Actual pure native constructors and public H1 framing, without sockets,
    trust discovery, clock observations or crypto activation. Defects escape. *)

val pem_sample : string
(** Public CA bytes from the canonical conformance TLS fixture. *)

val endpoint : string -> unit
(** Repeated endpoint validation agrees; accepted credentials remain sealed. *)

val credential : string -> string -> unit
(** Header validation agrees with the independent byte predicate. *)

val trust : string -> unit
(** Repeated X509 trust parsing agrees; rejected input is redacted. *)

val framing : string -> int -> unit
(** Feed the same wire bytes whole and fragmented through H1's public client
    decoder. Both must agree on success, status and decoded body. EOF alone
    cannot establish success while a codec error is pending. *)
