(** Explicit trusted host snapshot; no process-global getenv operation. *)

type t
type child

val of_bindings :
  temp_dir:Absolute_path.t -> (string * string) list -> (t, string) result
(** Rejects duplicate names, invalid names, and NUL-containing values. *)

val lookup : t -> string -> string option

val temp_dir : t -> Absolute_path.t
(** Explicit host capability; settings never inspect ambient temporary-directory
    state. *)

val child : t -> allow:string list -> deny:string list -> child
(** [names(child e a d)] is a subset of [a \ d]. Denial dominates allowance.
    Repeated allow/deny entries have no effect. Never inherit by subtraction
    alone. *)

val bindings : child -> (string * string) list
(** Only the sanitized child environment is observable; no raw snapshot printer.
*)
