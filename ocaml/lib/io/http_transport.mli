(** Destination-bound adapter HTTP capability. Construction and credential
    sealing are pure; only post may use supplied host authority. *)

type response = { status : int; body : string }

module type S = sig
  type t
  type endpoint
  type credential
  type scheme = Authorization_value | Bearer
  type nonrec response = response

  val endpoint : string -> (endpoint, Diagnostic.t) result
  (** Strict absolute HTTPS URL; reject userinfo, fragments and repaired syntax.
      The fake uses HTTPS with explicit trust through the normal driver. *)

  val credential :
    endpoint ->
    scheme:scheme ->
    token:string ->
    (credential, Diagnostic.t) result
  (** Seal a nonempty header-safe secret to its checked destination. No getter.
  *)

  val equal : credential -> credential -> bool

  val redacted : credential -> string
  (** Equality is an equivalence relation over effective destination/auth
      values; redacted is constant for all credentials. *)

  val post : t -> credential -> body:Json.t -> (response, Diagnostic.t) result
  (** Scoped bounded request, headers/body and deadline; reject all redirects.
      No ambient proxy or raw wire logging. Expected transport/TLS/framing
      failures return redacted Error. Cancellation and defects retain their
      identity/backtrace after all owned flows close. *)
end
