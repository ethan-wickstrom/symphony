(** An immutable observation record plus a key from the independent key policy
    model. No production reference constructor computes expected observations.
*)

type input = {
  root : string;
  after_create : string option;
  before_run : string option;
  after_run : string option;
  before_remove : string option;
  timeout_ms : string;
  environment : (string * string) list;
  scope : string;
  issue_id : string;
  identifier : string;
}

type t

val make : input -> (t, Workspace_key_model.error) result
(** Constructor model: valid derived key freezes the supplied observations;
    invalid key returns the key model's error without creating a reference. *)

val input : t -> input
(** [input r] equals the successful constructor input. Later construction cannot
    change it. *)

val key : t -> string
(** Equals the successful key-policy model projection of the identifier. *)

val equal_input : input -> input -> bool
(** Explicit equality of every observation, using named string equality. *)
