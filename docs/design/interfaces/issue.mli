type t
type routing = Dispatchable | Unroutable
type blocker = {
  id : Issue_id.t option;
  identifier : Issue_identifier.t option;
  state : string option;
}

type input = {
  id : string;
  identifier : string;
  title : string;
  description : string option;
  priority : string option;
  state : string;
  branch_name : string option;
  url : string option;
  labels : string list;
  blocked_by : blocker list;
  created_at : string option;
  updated_at : string option;
  dispatchable : routing;
  native_ref : Json.t option;
}

val parse : input -> (t, string) result
(** Adapter-boundary constructor only. Required strings are nonempty. Labels are
    trimmed/lowercased, blank-free and unique. Optional bad metadata normalizes
    to null/empty. native_ref is a non-secret JSON object or null, attested by
    the adapter; a generic parser cannot discover every provider secret. *)

val id : t -> Issue_id.t
val identifier : t -> Issue_identifier.t
val title : t -> string
val state : t -> string
val state_key : t -> string
val labels : t -> string list
val priority : t -> int option
val created_at : t -> Utc.t option
val routing : t -> routing
val to_json : t -> Json.t
(** All §4.1.1 fields are present, including null/empty metadata. No credentials. *)

module type S = sig
  type nonrec t = t
  val id : t -> Issue_id.t
  val identifier : t -> Issue_identifier.t
  val state_key : t -> string
  val labels : t -> string list
  val priority : t -> int option
  val created_at : t -> Utc.t option
  val routing : t -> routing
  val to_json : t -> Json.t
end
