(** Prefix-scan and lookup oracle over lists of already checked issues. *)

type error =
  | Duplicate_id of Issue_id.t
  | Duplicate_identifier of Issue_identifier.t

val of_list : Issue.t list -> (Issue.t list, error) result
(** Scan earlier issues directly. The first collision wins, with ID precedence
    at that item. Success returns the original list unchanged. *)

val find : Issue_id.t -> Issue.t list -> Issue.t option
(** The unique matching issue in a successful model list, or None. *)
