(** Checked Relay page. Shared by issues, labels and inverse relations, which
    have the same connection operations. Provider values remain at this boundary
    until their record-specific parsers consume them. *)

type cursor
type t

val parse : Json.t -> (t, Tracker_error.t) result
(** Require an object, a nodes array and pageInfo.hasNextPage boolean. A
    continuing page has at least one node and a nonempty bounded endCursor.
    Invalid pagination never becomes an empty completed page. *)

val nodes : t -> Json.t list
(** Preserve wire order; repeated observation agrees. *)

val next : t -> cursor option
(** None means the provider explicitly reported hasNextPage=false. *)

val cursor_text : cursor -> string

val cursor_equal : cursor -> cursor -> bool
(** Exact equality is an equivalence relation. Cursor text is used only in JSON
    variables, never shell strings, diagnostics or URL interpolation. *)

type history

val start : history

val advance : history -> cursor -> (history, Tracker_error.t) result
(** Seen cursors form a set. Advancing a new cursor adds exactly that cursor;
    repetition fails. A repeated-cursor error absorbs every later suffix. No
    page loop can manufacture progress by alternating earlier cursors. *)
