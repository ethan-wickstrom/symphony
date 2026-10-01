type response = { status : int; body : string }

module type S = sig
  type t
  type endpoint
  type credential
  type scheme = Authorization_value | Bearer
  type nonrec response = response

  val endpoint : string -> (endpoint, Diagnostic.t) result

  val credential :
    endpoint ->
    scheme:scheme ->
    token:string ->
    (credential, Diagnostic.t) result

  val equal : credential -> credential -> bool
  val redacted : credential -> string
  val post : t -> credential -> body:Json.t -> (response, Diagnostic.t) result
end
