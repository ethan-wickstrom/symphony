(** Atomic Linear paging over one supplied HTTP read capability. No settings,
    credentials, ambient authority or clock enters this mechanism. *)

type selection = States of string list | Ids of Issue_id.Set.t

val read :
  post:(Json.t -> (Http_transport.response, Diagnostic.t) result) ->
  project:string ->
  terminal:string list ->
  omitted:(Linear_omission.t -> (unit, Diagnostic.t) result) ->
  selection ->
  (Issue_batch.t, Tracker_error.t) result
(** Empty input performs zero post calls. Use constant GraphQL documents and
    JSON variables, project filtering and explicit case-insensitive states; ID
    refresh has no active-state filter. Collect all outer and nested pages, or
    return one atomic Error. Preserve outer wire order across pages/chunks.

    Repartitioning the same scripted issue stream into valid pages preserves
    ordered output; any paging/transport error absorbs the rest of the read.
    Reject cursor cycles, duplicate IDs/identifiers, scope/filter violations,
    exceeded cumulative budgets and malformed requested records.

    States omits malformed required records with a bounded warning. Expected
    warning-sink Error leaves the read unchanged; sink cancellation/defects
    propagate. Optional unusable collections normalize conservatively, and
    incomplete blocker evidence never establishes Todo dispatchability.

    Result keys for Ids are a subset of the input set; omitted IDs mean no
    longer visible. Project/selection inputs come from checked configuration and
    identifiers; this module never interprets native_ref. *)
