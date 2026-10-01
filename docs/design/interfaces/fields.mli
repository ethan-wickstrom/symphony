(** Shared boundary coercions. Numbers never pass through floating point. *)

val get : Config_value.t -> string list -> Config_value.t option

val credential_text : Environment.t -> Config_value.t -> (string, string) result
(** Privileged whole-variable resolution for credential/bootstrap parsing only.
    Public settings cannot consume the raw environment type. *)

val text : Environment.public -> Config_value.t -> (string, string) result
(** Resolve whole references; guard literals and resolved values. *)

val reference : string -> string option
(** Recognizes only a whole [$NAME] token with an environment identifier. *)

val integer : Environment.public -> Config_value.t -> (Z.t, string) result
(** Exact integer parsing; quarantine applies to input and canonical decimal
    output, so alternate radices/leading zeros cannot bypass it. *)

val strings :
  Environment.public -> Config_value.t -> (string list, string) result

val mapping : Config_value.t -> ((string * Config_value.t) list, string) result

val json : Environment.public -> Config_value.t -> (Json.t, string) result
(** Preserve JSON semantics without interpolation. Guard string values, object
    keys and canonical numeric output recursively before protocol use. *)

val path :
  Environment.public ->
  base:Absolute_path.t ->
  string ->
  (Absolute_path.t, string) result
(** Embedded references and HOME use guarded lookup. Guard literal, expanded and
    final canonical path bytes. No filesystem access. *)

val diagnostic : key:string -> string -> Diagnostic.t
val sequence : ('a, 'e) result list -> ('a list, 'e) result
