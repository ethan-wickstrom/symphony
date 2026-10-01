(** Lower process/byte-stream driver. Actual protocol interpreter runs above it in
    both live operation and whole-service simulation. Trusted shell lives here. *)

module type S = sig
  module Path : Workspace_path.S
  type t
  type process
  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int
  val with_process : t -> cwd:Path.t -> env:Environment.child -> command:string ->
    (process -> ('a, error) result) -> ('a, error) result
  (** Spec §10.1 requires bash -lc <trusted command>. Use argument arrays;
      never interpolate issue data. Child cwd uses the acquired directory handle.
      Bracket's nested scope closes/reaps/drains before returning on every path;
      it owns process group, pipes and TERM/KILL grace/drain deadlines under the caller
      switch. Actual direct-child reaping waits for the kernel; POSIX provides no
      finite bound after SIGKILL. Descendants that leave the group require stronger
      host isolation. Pipe EOF is not evidence that the process group is empty.
      Check lifetime and directory identity before launch; stale handles return Error. *)

  val read : process -> (string option, error) result
  (** Bounded byte chunk; None means EOF. No framing assumption. Cancelable. *)

  val write : process -> string -> (unit, error) result
  (** Write the whole supplied frame or Error; serialized by the protocol owner. *)

  val stderr : process -> (string option, error) result
  (** Separate bounded stream; it never enters the protocol decoder. *)

  val await_exit : process -> (exit, error) result
  (** Observe the direct child's exit; cleanup is still owned by with_process.
      Repeated observation yields the same status. Exit does not release the group
      identity; signaling and reaping remain serialized under one private custody.
      Waiting is cancelable; cancellation propagates after protected cleanup. *)

end
