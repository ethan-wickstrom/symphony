(** Hook execution over the same checked reference and Path as the store. *)

type outcome = Completed of (unit, Workspace_manager.error) result | Cancelled
type event = Started | Finished of outcome

module type S = sig
  module Contract : Workspace_manager.PURE

  type t

  val run :
    t ->
    workspace:Contract.reference ->
    cwd:Contract.Path.t ->
    Workspace_settings.hook ->
    (unit, Workspace_manager.error) result
  (** No configured script is identity, including the event trace. Otherwise use
      the frozen script, environment and timeout, with bounded byte streams.
      Completion or cancellation emits one Finished after Started. Cancellation
      emits Finished Cancelled after child closure, then propagates with its
      original backtrace. Both readers finish or reach their named drain bounds.
      Defects are outside this outcome algebra and may propagate after cleanup.
  *)
end
