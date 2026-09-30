(** Interpreter for the finite schema fragment in generated Codex policy
    definitions. Unknown schema keywords fail closed. This is not a general JSON
    Schema engine. *)

val validate : definition:string -> Json.t -> (unit, string) result
