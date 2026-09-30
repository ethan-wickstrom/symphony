(** Shared boundary coercions. Numbers never pass through floating point. *)

val get : Config_value.t -> string list -> Config_value.t option
val text : Environment.t -> Config_value.t -> (string, string) result

val reference : string -> string option
(** Recognizes only a whole [$NAME] token with an environment identifier. *)

val integer : Environment.t -> Config_value.t -> (Z.t, string) result
val strings : Environment.t -> Config_value.t -> (string list, string) result
val mapping : Config_value.t -> ((string * Config_value.t) list, string) result
val json : Config_value.t -> (Json.t, string) result

val path :
  Environment.t ->
  base:Absolute_path.t ->
  string ->
  (Absolute_path.t, string) result

val diagnostic : key:string -> string -> Diagnostic.t
val sequence : ('a, 'e) result list -> ('a list, 'e) result
