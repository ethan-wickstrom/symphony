type t
(** Bounded scoped Eio file loading. Expected IO failures are values;
    cancellation propagates to the owning switch. No pathname-derived authority
    is acquired. *)

val make : Eio.Fs.dir_ty Eio.Path.t -> t
val read : t -> file:Workflow_path.t -> (string, Workflow_loader.error) result
