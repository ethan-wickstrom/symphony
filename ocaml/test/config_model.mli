(** Independent reload oracle: the last valid value and latest load error. No
    production configuration code or containers are used. *)

type ('config, 'error) reload

val initial : 'config -> ('config, 'error) reload
(** [effective (initial c) = c] and [latest_error (initial c) = None]. *)

val apply :
  ('config, 'error) reload ->
  ('config, 'error) result ->
  ('config, 'error) reload
(** [effective (apply r (Error e)) = effective r].
    [latest_error (apply r (Error e)) = Some e]: failure gates new dispatch.
    [effective (apply r (Ok c)) = c]. [latest_error (apply r (Ok c)) = None]:
    success clears the gate. Identical successful loads are idempotent. Invalid
    loads are not identity on the complete state because their operator-visible
    errors are retained. *)

val effective : ('config, 'error) reload -> 'config
val latest_error : ('config, 'error) reload -> 'error option

val limits : (string * int option) list -> ((string * int) list, unit) result
(** ASCII-name reference model: positive values survive; absent and nonpositive
    values are ignored. Names are trimmed and lowercased. Two surviving bindings
    for the same normalized name are invalid. The model uses a list, not a map.
*)

val state_limit : global:int -> (string * int) list -> string -> int
(** A missing binding observes the global limit. Lookup normalizes ASCII names.
*)
