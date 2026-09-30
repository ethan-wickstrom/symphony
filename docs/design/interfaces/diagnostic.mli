type site =
  | Workflow of { file : string; key : string option; line : int option }
  | Issue of { id : Issue_id.t; identifier : Issue_identifier.t }
  | Protocol of { method_name : string; request_id : string option }
  | Host of string

type t
val make : site:site -> message:string -> remedy:string -> t
(** The boundary supplies redacted text. Rendering escapes control characters;
    secrets and raw provider/protocol payloads are never accepted as diagnostics. *)

val render : t -> string
val site : t -> site
