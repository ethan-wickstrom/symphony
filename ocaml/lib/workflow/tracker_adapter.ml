module type CONFIG = sig
  type settings

  val kind : string
  val equal : settings -> settings -> bool
  val secret_names : settings -> string list

  val parse :
    env:Environment.t ->
    active:string list ->
    terminal:string list ->
    Config_value.t ->
    (settings, Tracker_error.t) result

  val scope : settings -> Tracker_scope.t
end

module type S = sig
  include CONFIG

  type io

  val states :
    io ->
    settings ->
    string list ->
    (Issue.t Issue_id.Map.t, Tracker_error.t) result

  val ids :
    io ->
    settings ->
    Issue_id.Set.t ->
    (Issue.t Issue_id.Map.t, Tracker_error.t) result
end
