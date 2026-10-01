(** Process and byte streams beneath protocol interpretation. *)

module type S = sig
  module Path : Workspace_path.S

  type t
  type process
  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int

  val with_process :
    t ->
    cwd:Path.t ->
    env:Environment.child ->
    command:string ->
    on_error:(error -> 'e) ->
    (process -> ('a, 'e) result) ->
    ('a, 'e) result
  (** Spec section 10.1 requires bash -lc with the trusted command. Argument
      arrays never interpolate issue data; cwd comes from the acquired handle.
      The bracket closes pipes and its owned group before releasing the Path
      loan on every exit. TERM grace and drain have named bounds, but actual
      direct-child reaping has no finite POSIX bound. Descendants that leave the
      group require stronger host isolation. EOF never proves the group empty.
      Primary callback errors, cancellation and defects survive cleanup and
      reporting defects with their original exception identity and backtrace.
      Mechanism failures enter the caller's error algebra through [on_error];
      callback errors are never translated or hidden inside [Ok].

      Laws after all closure obligations: [finish (Error e) cleanup = Error e];
      [finish (Ok x) (Ok ()) = Ok x];
      [finish (Ok x) (Error d) = Error (on_error d)]. Shadowed cleanup failures
      never invoke [on_error]. A mapper defect after callback success propagates
      only after closure, with its backtrace. *)

  val read : process -> (string option, error) result
  (** Bounded byte chunk; None means EOF. No framing assumption. Cancelable. *)

  val write : process -> string -> (unit, error) result
  (** Writes the whole supplied frame or Error. The protocol owner serializes
      writes. For an active process, the empty frame is identity. *)

  val stderr : process -> (string option, error) result
  (** A separate bounded stream, safe concurrently with read. Its bytes never
      enter the protocol decoder or default logs. *)

  val await_exit : process -> (exit, error) result
  (** Repeated successful observations agree and never release group custody.
      Waiting is cancelable. Closed process methods return Error before IO. *)
end
