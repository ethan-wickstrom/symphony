(** Checked Codex 0.159.2 JSONL message envelope; no [jsonrpc] header. *)

type rpc_error = { code : int64; message : string; data : Json.t option }
type reply = Success of Json.t | Failure of rpc_error

type view =
  | Request of { id : Protocol_id.t; method_ : string; params : Json.t option }
  | Notification of { method_ : string; params : Json.t option }
  | Response of { id : Protocol_id.t; reply : reply }

type t

type error =
  | Not_object
  | Ambiguous
  | Invalid_id of Protocol_id.error
  | Invalid_method
  | Invalid_rpc_error
  | Forbidden_header
  | Invalid_json

val decode : Json.t -> (t, error) result
(** Check the consumed core fields, including signed-int64 error codes. Reject
    mixed request/response fields and response params. Checked Json already
    rejects duplicate keys. Unknown additive fields remain opaque and bounded.
*)

val view : t -> view

val encode : t -> (Json.t, error) result
(** Preserve the complete decoded value, including additive top-level and error
    object fields. [decode] then [encode] agrees under semantic Json equality.
*)

val request :
  id:Protocol_id.t ->
  method_:string ->
  params:Json.t option ->
  (t, error) result

val notification : method_:string -> params:Json.t option -> (t, error) result
(** Method names are nonempty and limited to 256 UTF-8 bytes. [None] omits
    params; [Some null] keeps an explicit null. Constructors return checked
    values. *)

val response : id:Protocol_id.t -> reply:reply -> (t, error) result
(** Echo the exact wire ID. Diagnostics expose categories, never raw payloads.
*)
