(** Ordered tracker snapshot with unique dispatch IDs and identifiers. Store the
    checked issues once; projections never cache a second index. *)

type t

type error =
  | Duplicate_id of Issue_id.t
  | Duplicate_identifier of Issue_identifier.t

val empty : t
(** [ordered empty = []]; [by_id empty = Issue_id.Map.empty]. *)

val of_list : Issue.t list -> (t, error) result
(** Consume checked issues without reparsing, sorting or changing snapshots.
    Identity uses [Issue_id.equal] and [Issue_identifier.equal], preserving
    their exact byte semantics.

    Success holds exactly when both identity projections are unique. If
    [of_list xs = Ok batch], then [ordered batch = xs]. Reconstruction
    [of_list (ordered batch)] succeeds with the same ordered projection.

    Reject the first collision in input order. At that issue, a repeated ID
    takes precedence over a repeated identifier. Appending any suffix after this
    first collision preserves its error. No partial batch is returned. *)

val ordered : t -> Issue.t list
(** Preserve input order and the complete checked issue values, including
    provider metadata. Repeated observation agrees. *)

val by_id : t -> Issue.t Issue_id.Map.t
(** Derive the map with the named [Issue_id.Map] instance. For each issue [i] in
    [ordered batch],
    [Issue_id.Map.find_opt (Issue.id i) (by_id batch) = Some i]. All other
    lookups are [None]; keys are exactly the input IDs and cardinality equals
    [List.length (ordered batch)]. Map traversal uses ID order; consume
    [ordered] when snapshot order matters. *)
