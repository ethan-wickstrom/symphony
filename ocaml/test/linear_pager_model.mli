(** Ordered list model of the published Linear read profile. No pager, record
    parser, map or set implements the oracle. *)

type selection = States of string list | Ids of string list
type operation = Issues | Labels | Relations

type request =
  | Issues_page of { selection : selection; after : string option }
  | Labels_page of { id : string; after : string option }
  | Relations_page of { id : string; after : string option }

val operation : request -> operation

val variables : project:string -> request -> Json.t
(** Exact variables contain all dynamic values; pageSize is the profile's 50.
    State names normalize as a set; IDs use exact bytes in sorted chunks. *)

type entry = {
  id : string;
  identifier : string;
  state : string;
  project : string;
}

type node = Valid of entry | Malformed
type failure = Duplicate_id | Duplicate_identifier | Scope | Filter | Required
type collected = { entries : entry list; omitted : int }

val collect :
  project:string -> selection -> node list -> (collected, failure) result
(** Validate scope/filter/required fields before final batch uniqueness. State
    malformed nodes warn/omit; malformed ID reads fail. Then the first identity
    collision rejects the whole checked stream. Success preserves order; no
    earlier prefix escapes on failure. *)

val partition : int list -> 'a list -> 'a list list
(** Positive requested lengths partition without dropping/reordering values;
    exhaustion retains the remaining suffix as one page. Concatenating the
    result equals the original list, including the empty identity. *)

val chunks : selection -> selection list
(** Empty selection gives no chunks. ID sets split into sorted groups of 50; a
    nonempty state selection stays one normalized set request. *)
