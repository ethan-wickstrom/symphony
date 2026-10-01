type t
(** Private semantic lifetime gate; descriptor reference counts alone cannot
    retain a workspace's exclusive owner. *)

module Public : Workspace_path.S with type t = t

val create :
  directory:Workspace_directory.directory ->
  validate:(unit -> (unit, Workspace_manager.error) result) ->
  report:(Workspace_manager.error -> unit) ->
  t
(** Only Store creates this authority after exact ownership verification. *)

val check : t -> (unit, Workspace_manager.error) result
(** Released/closing authorities fail before IO; held ones revalidate identity.
*)

val with_child :
  t ->
  (sw:Eio.Switch.t -> Eio_unix.Fd.t -> ('a, Workspace_manager.error) result) ->
  ('a, Workspace_manager.error) result
(** Admits one cancelable child scope while Held; lends cwd through that scope's
    complete closure. Closing rejects admission and cancels already admitted
    scopes. Every exit unregisters once, after all child fibers/resources close.
    Other cancellation and defects propagate with their original backtrace. *)

val close : t -> unit
(** Held -> Closing -> Released. Cancels and joins all admitted scopes before
    returning; repeated close is identity. Protected against caller
    cancellation. Raises an unexpected cancellation-handler defect after
    completing all joins. OCaml has no linear effect/lifetime type, so this one
    module enforces the gate. *)
