type t
type error =
  | Parse_error of Diagnostic.t
  | Front_matter_not_map of Diagnostic.t

val parse : file:Workflow_path.t -> string -> (t, error) result
(** Exact front-matter/prompt split from §5.2. Parse all front matter;
    reject extra YAML documents, duplicate keys, and unterminated front matter. *)

val config : t -> Config_value.t
val prompt : t -> string
val file : t -> Workflow_path.t
