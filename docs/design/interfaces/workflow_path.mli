(** Workflow source identity, distinct from an acquired workspace capability. *)

type t
val resolve : base:Absolute_path.t -> string -> (t, string) result
(** Resolve a CLI path against the explicitly supplied host directory. Reject NUL.
    Relative configuration paths subsequently resolve against this file's directory. *)

val absolute : t -> Absolute_path.t
val display : t -> string
