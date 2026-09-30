(** Positioned YAML boundary tree, preserving scalar lexemes and integer precision.
    Maps have unique string keys. Exactly one complete YAML document is accepted. *)

type t
type view =
  | Null
  | Bool of bool
  | Number of string
  | String of string
  | Sequence of t list
  | Mapping of (string * t) list

val parse : string -> (t, string) result
(** Resolve YAML 1.2 core scalars, preserving quoted strings and numeric lexemes.
    Reject unsupported tags and nonfinite numbers. Never round integers through float. *)

val view : t -> view
val location : t -> int * int
(** Positive line/column in the workflow front matter. *)

val field : t -> string -> t option
(** Map model: [field m k] is the unique binding of k, or None. *)
