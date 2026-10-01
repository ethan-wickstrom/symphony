(** Pure checked attempt identity. Lexical roots are frozen configuration, not
    acquired directory capabilities. *)

module Make (Path : Workspace_path.S) : sig
  module Path : Workspace_path.S with type t = Path.t

  type reference

  val reference :
    settings:Workspace_settings.t ->
    env:Environment.child ->
    scope:Tracker_scope.t ->
    issue_id:Issue_id.t ->
    identifier:Issue_identifier.t ->
    (reference, Workspace_manager.error) result
  (** Check the key once and retain immutable inputs. Equal inputs give equal
      accessor observations. No filesystem/process effect, [Path.t]
      construction, or ambient lookup. Only [Invalid_key] is returned here; its
      diagnostic names the identifier and key failure and tells the operator
      what to change. Containment and ownership belong to acquisition. *)

  val identifier : reference -> Issue_identifier.t
  (** [identifier r] equals the constructor's identifier under
      [Issue_identifier.equal]. *)

  val issue_id : reference -> Issue_id.t
  (** [issue_id r] equals the constructor's opaque ID under [Issue_id.equal].
      Ownership compares it as well as scope and original identifier, so a
      recreated issue cannot inherit a prior issue's directory. *)

  val scope : reference -> Tracker_scope.t
  (** [scope r] equals the constructor's scope under [Tracker_scope.equal]. *)

  val environment : reference -> Environment.child
  (** [Environment.bindings (environment r) = Environment.bindings env], where
      [env] was supplied to the constructor. *)

  val key : reference -> Workspace_key.t
  (** [key r] equals the constructor identifier's successful derived key under
      [Workspace_key.compare]. *)

  val settings : reference -> Workspace_settings.t
  (** Equal to the supplied settings under [Workspace_settings.equal]. Later
      construction or configuration replacement changes no observation of [r].
  *)

  type cleanup = { request_id : Request_id.t; workspace : reference }
end
