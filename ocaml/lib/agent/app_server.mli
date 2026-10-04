(** One owned stable stdio session over explicit process and clock instances. *)

type error =
  | Failure of Agent_runner.failure
  | Deadline of Agent_runner.timeout
  | Stopped of {
      interrupt : Agent_runner.interrupt;
      remote_error : Diagnostic.t option;
    }

type terminal =
  | Completed
  | Failed of Diagnostic.t
  | Interrupted of Diagnostic.t option
  | Input_required of Diagnostic.t

type ended = { turn : Turn_id.t; outcome : terminal }

module Make (Process : Agent_process.S) (Clock : Clock.S) : sig
  module Path : Workspace_path.S with type t = Process.Path.t

  type session

  val with_session :
    process:Process.t ->
    clock:Clock.t ->
    interrupt:Agent_runner.interrupt Eio.Promise.t ->
    cwd:Path.t ->
    env:Environment.child ->
    settings:Agent_settings.t ->
    version:string ->
    title:string ->
    (session -> ('a, error) result) ->
    ('a, error) result
  (** Initialize, create and name one thread before the callback. Use exactly
      the invocation's process/clock/path/environment. All reader/stderr fibers
      join before the process bracket closes. Expected failures remain values;
      unrelated cancellation and defects preserve identity/backtrace after
      closure. An already resolved interruption acquires no process. RPC
      deadlines include writes and never reset on unrelated output. *)

  val turn :
    session ->
    prompt:string ->
    emit:(Agent_runner.event -> unit) ->
    (ended, error) result
  (** Initial and continuation turns use the same thread and explicit policy.
      Stdout bytes reset active-turn silence; stderr does not. One protocol
      owner handles replies/notifications/server requests during pending calls,
      owns bounded correlation/replay records and serializes writes.
      Interruption wakes blocked IO, attempts bounded turn/interrupt and drain,
      then returns its local cause separately from remote diagnostics. A remote
      terminal is not a closed resource witness. *)

  val await : session -> (unit -> 'a) -> ('a, error) result
  (** After successful completion, observe late messages while awaiting the
      owner's continuation decision. The callback cannot call this session. One
      protocol owner sends replies and finishes each progress receipt before
      returning the callback result. Interruption cancels and joins a blocked
      callback; the completed turn has no active stdout silence deadline. *)
end
