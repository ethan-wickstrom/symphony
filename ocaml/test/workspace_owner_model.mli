(** Plain observations and a structural JSON model. No production owner
    constructor or parser computes expected results. *)

type t = {
  scope : string;
  issue_id : string;
  identifier : string;
  device : string;
  inode : string;
}

val of_json : Yojson.Safe.t -> t option
(** Accept exactly the six-field version-1 object with checked identity text, a
    valid key under the independent key model and canonical 64-bit hex text. *)

val equal : t -> t -> bool
(** Componentwise string equality. *)
