(** Section 3.1 component: read failures and invalid workflow are values. *)

type error =
  | Missing_file of Diagnostic.t
  | Read_error of Diagnostic.t
  | Invalid_document of Workflow_document.error

module type IO = sig
  type t
  val read : t -> file:Workflow_path.t -> (string, error) result
  (** Bounded read; expected filesystem failures return Error. Host cancellation
      propagates to the enclosing Eio scope, never into an ordinary reload. *)

end

module type S = sig
  type io
  val load : io -> file:Workflow_path.t -> (Workflow_document.t, error) result
  (** Same bytes and source produce the same parse result. No fallback on failure. *)

end

module Make (IO : IO) : S with type io = IO.t
