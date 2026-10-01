include Workspace_store.S with module Contract = Workspace_contract_posix
(** Native ownership policy over the descriptor mechanism. *)

val create :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  report:(Workspace_manager.error -> unit) ->
  close_path:(Workspace_path_posix.t -> unit) ->
  t
(** No IO at construction. Roots/settings/environments come from each frozen
    reference. Callback defects/cancellation take precedence over release
    defects; secondary failures are reported after every release obligation is
    attempted. The opaque callback value always survives: release/reporting
    defects cannot replace it. OCaml cannot inspect that value to distinguish
    success from a caller's expected error. A defective secondary reporter is
    therefore suppressed. [close_path] revokes admission and joins every loan
    before returning or raising; repeated closure is identity. This private
    capability separates removal policy from authority discharge. The public
    host supplies Path.close. OCaml cannot express the temporal join law; it is
    checked at this boundary. *)
