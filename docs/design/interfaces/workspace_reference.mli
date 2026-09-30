(** Pure checked workspace request. Its root is lexical; a live Path.t requires
    directory acquisition. One reference freezes an attempt's settings and child
    environment. No current configuration is consulted at cleanup. *)

module Make (Path : Workspace_path.S) :
  Workspace_manager.PURE with module Issue = Issue and module Path = Path
