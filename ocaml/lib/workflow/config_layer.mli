(** Section 3.1 component: immutable validated settings plus explicit dispatch
    readiness. *)

type error =
  | Workflow of Workflow_loader.error
  | Fields of Diagnostic.t Nonempty_list.t
  | Tracker of Tracker_error.t

module type PURE = sig
  type tracker
  type t
  type reload
  type readiness = Ready | Blocked of error

  val scheduling : t -> Scheduling_policy.t
  val agent : t -> Agent_settings.t
  val workspace : t -> Workspace_settings.t
  val tracker : t -> tracker

  val prompt_source : t -> string
  (** Empty workflow prompt selects the §5.4 literal fallback here, before
      compilation. *)

  val file : t -> Workflow_path.t

  val child_env : t -> Environment.child
  (** Immutable allowlisted public environment excludes declared sources and
      value-equal credential aliases. Freeze this value in each launch reference
      and use the same environment for hooks and agent. *)

  val equal : t -> t -> bool
  (** Semantic effective-settings equality, including secret changes without
      printing them. *)

  val initial : t -> reload

  val apply : reload -> (t, error) result -> reload
  (** [effective(apply r (Error e)) = effective r]; readiness becomes Blocked e.
      Identical valid load is idempotent. Valid load clears gating. Invalid load
      is NOT identity on the whole state. Reference model: last good + latest
      validity. *)

  val effective : reload -> t
  val readiness : reload -> readiness
end

module type S = sig
  include PURE

  type registry

  val server_port : t -> Http_port.t option
  (** Initial listener setting; a reload does not hot-rebind the HTTP server. *)

  val resolve :
    registry ->
    env:Environment.t ->
    document:Workflow_document.t ->
    (t, error) result
  (** Bootstrap the adapter's frozen binding and restricted public environment
      before parsing core settings from the same document. Credential material
      cannot enter public settings through names, aliases or exact literals. No
      network request; callers cannot attach a binding parsed from a different
      document. Prompt syntax is checked before either initial or reloaded
      settings become effective. Trusted shell strings retain their literal
      bytes. *)
end

module Make (Tracker : Tracker.CONFIG) :
  S with type tracker = Tracker.Contract.binding and type registry = Tracker.t
