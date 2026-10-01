module type S = sig
  module Contract : Workspace_manager.PURE

  type t
  type lease
  type origin = Created | Reused

  val with_lease :
    t ->
    Contract.reference ->
    (origin -> lease -> 'a) ->
    ('a, Workspace_manager.error) result

  val with_existing :
    t ->
    Contract.reference ->
    (lease option -> 'a) ->
    ('a, Workspace_manager.error) result

  val reference : lease -> Contract.reference
  val path : lease -> (Contract.Path.t, Workspace_manager.error) result
  val remove : t -> lease -> (unit, Workspace_manager.error) result
end
