module Make
    (Store : Workspace_store.S)
    (Hooks : Workspace_hooks.S with module Contract = Store.Contract) =
struct
  module Contract = Store.Contract

  type t = {
    store : Store.t;
    hooks : Hooks.t;
    report : Workspace_manager.error -> unit;
  }

  type lease = Store.lease
  type origin = Store.origin = Created | Reused

  let create ~store ~hooks ~report = { store; hooks; report }
  let with_lease t = Store.with_lease t.store
  let with_existing t = Store.with_existing t.store
  let path = Store.path

  let hook t lease phase =
    Result.bind (Store.path lease) (fun cwd ->
        Hooks.run t.hooks ~workspace:(Store.reference lease) ~cwd phase)

  let remove t = Store.remove t.store

  let cleanup_scope _t run =
    (* A cancelled preparation scope cannot host after_run children. *)
    Eio.Switch.run_protected (fun _scope -> run ())

  let report t error = t.report error
end
