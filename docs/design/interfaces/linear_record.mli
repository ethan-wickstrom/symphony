(** Linear record normalization. Raw nodes stay within this provider boundary;
    only a complete checked Issue.t crosses into Tracker. *)

type completeness = Complete | Incomplete

val parse :
  terminal:string list ->
  labels:Json.t list ->
  relations:Json.t list ->
  completeness:completeness ->
  Json.t ->
  (Issue.t, Linear_omission.t) result
(** Required id/identifier/title/state.name are nonempty checked values.
    Unusable optional fields become null/empty, labels normalize idempotently,
    and exact integral priorities normalize without floating-point truncation.

    The metadata lists concatenate completed Relay pages in wire order. A Todo
    issue is dispatchable exactly when evidence is Complete and every incoming
    blocks relation has the matching target and a known terminal blocker state.
    Missing/malformed blocker evidence cannot establish dispatchability; other
    states have no blocker restriction. Best-effort blocked_by is a separate
    projection, so dropping an unusable entry cannot turn false into true.

    Relation source=issue and target=relatedIssue. Other relation types are
    ignored; unknown relation shapes make evidence incomplete. Todo
    self-blocking is never dispatchable. Native_ref contains only constructed
    issue/project identities; arbitrary provider fields never enter it.

    Fields not read by this parser cannot change its result. Adding a usable
    nonterminal blocker to Todo cannot improve eligibility. Cancellation and
    defects are not caught or reclassified as malformed records. *)
