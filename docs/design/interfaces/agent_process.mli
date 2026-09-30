(** Lower process/byte-stream driver. Actual protocol interpreter runs above it in
    both live operation and whole-service simulation. Trusted shell lives here. *)

module type S = sig
  module Path : Workspace_path.S
  type t
  type process
  type error = Diagnostic.t
  val with_process : t -> cwd:Path.t -> env:Environment.child -> command:string ->
    (process -> ('a, error) result) -> ('a, error) result
  (** Spec §10.1 requires bash -lc <trusted command>. Use argument arrays;
      never interpolate issue data. Child cwd uses the acquired directory handle.
      Bracket's nested scope closes/reaps/drains before returning on every path;
      it owns process group, pipes and TERM/KILL deadlines under the caller switch.
      Check lifetime and directory identity before launch; stale handles return Error. *)

  val read : process -> (string option, error) result
  (** Bounded byte chunk; None means EOF. No framing assumption. Cancelable. *)

  val write : process -> string -> (unit, error) result
  (** Write the whole supplied frame or Error; serialized by the protocol owner. *)

  val stderr : process -> (string option, error) result
  (** Separate bounded stream; it never enters the protocol decoder. *)

end
