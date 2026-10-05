(** Optional listener settings. Binding uses the initial resolved port until
    restart; these settings do not participate in scheduling authority. *)

val parse :
  env:Environment.public ->
  Config_value.t ->
  (Http_port.t option, Diagnostic.t Nonempty_list.t) result
