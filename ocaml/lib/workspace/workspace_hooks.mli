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

module Make
    (Contract : Workspace_manager.PURE)
    (Process : Agent_process.S with module Path = Contract.Path)
    (Clock : Clock.S) : sig
  include S with module Contract = Contract

  val create :
    process:Process.t ->
    clock:Clock.t ->
    emit:(Contract.reference -> Workspace_settings.hook -> event -> unit) ->
    t
  (** Capture ports without effects. Live and simulated execution share this
      interpreter. Output is discarded in bounded chunks, never logged raw;
      readers yield so deadlines cannot starve under continuous output. *)
end
