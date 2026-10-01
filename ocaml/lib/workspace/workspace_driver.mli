(** Compose ownership and hook ports without duplicating manager policy. *)

module Make
    (Store : Workspace_store.S)
    (Hooks : Workspace_hooks.S with module Contract = Store.Contract) : sig
  (** Acquisition, lookup, path and removal preserve Store results. Hook
      execution requires a successful Store.path and receives Store.reference
      unchanged. cleanup_scope runs its callback once in a fresh protected Eio
      switch, preserving its result or exception after that scope closes. *)
  include
    Workspace_manager.DRIVER
      with module Contract = Store.Contract
       and type lease = Store.lease
       and type origin = Store.origin

  val create :
    store:Store.t ->
    hooks:Hooks.t ->
    report:(Workspace_manager.error -> unit) ->
    t
  (** Assemble explicit capabilities. Reporting calls the supplied observer once
      per reported error; expected logging failures must be handled by that
      observer. No acquisition, hook or logging effect occurs during create. *)
end
