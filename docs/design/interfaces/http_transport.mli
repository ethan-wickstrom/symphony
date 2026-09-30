(** Narrow adapter HTTP capability. Authentication belongs to this driver, never a tool. *)

module type S = sig
  type t
  type endpoint
  type credential
  type scheme = Authorization_value | Bearer
  type response = { status : int; body : string }
  val endpoint : string -> (endpoint, Diagnostic.t) result
  (** Checked HTTPS origin/path; loopback HTTP only in the declared test profile. *)

  val credential : endpoint -> scheme:scheme -> token:string ->
    (credential, Diagnostic.t) result
  (** Nonempty checked secret sealed together with its destination. No token getter. *)

  val equal : credential -> credential -> bool
  val redacted : credential -> string
  (** Redacted output is constant for all credentials. Equality reveals no bytes. *)

  val post : t -> credential -> body:Json.t -> (response, Diagnostic.t) result
  (** Send only to the credential's bound endpoint. Explicit network/TLS/clock
      capability; bounded response/time and no cross-origin credential redirect.
      Cancellation propagates, expected failures return Error. *)

end
