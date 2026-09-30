module type PURE = sig
  module Issue : Issue.S

  type binding

  type request =
    | States of { id : Request_id.t; binding : binding; names : string list }
    | Ids of { id : Request_id.t; binding : binding; ids : Issue_id.Set.t }

  type reply = (Issue.t Issue_id.Map.t, Tracker_error.t) result

  val scope : binding -> Tracker_scope.t
  val equal : binding -> binding -> bool
  val secret_names : binding -> string list
end

module type CONFIG = sig
  module Contract : PURE with type Issue.t = Issue.t

  type t

  val configure :
    t ->
    env:Environment.t ->
    kind:string ->
    active:string list ->
    terminal:string list ->
    provider:Config_value.t ->
    (Contract.binding, Tracker_error.t) result
end

module type S = sig
  include CONFIG

  val execute : t -> Contract.request -> Contract.reply
end
