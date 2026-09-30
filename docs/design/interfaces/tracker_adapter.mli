(** Open adapter set. First-class packages hide provider settings and credentials. *)

module type CONFIG = sig
  type settings
  val kind : string
  val equal : settings -> settings -> bool
  val secret_names : settings -> string list
  (** Include fixed credential names and every resolved $VAR credential source.
      Example: api_key=$CUSTOM_LINEAR_TOKEN also denies CUSTOM_LINEAR_TOKEN. *)

  val parse : env:Environment.t -> active:string list -> terminal:string list ->
    Config_value.t -> (settings, Tracker_error.t) result
  (** Pure validation/defaults/$VAR resolution. No credential printer or getter. *)

  val scope : settings -> Tracker_scope.t
end

module type S = sig
  include CONFIG
  type io
  val states : io -> settings -> string list -> (Issue.t Issue_id.Map.t, Tracker_error.t) result
  val ids : io -> settings -> Issue_id.Set.t -> (Issue.t Issue_id.Map.t, Tracker_error.t) result
  (** Both empty inputs perform zero provider requests. All pages succeed or Error;
      ID refresh is complete, unique, scope-filtered, and fails malformed requested
      records. State reads may omit malformed records with a warning. Cancellation
      propagates; all other expected transport failures return Error. *)

end
