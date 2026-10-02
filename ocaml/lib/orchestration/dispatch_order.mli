(** Pure dispatch ordering; equality of rank need not identify an issue. *)

type 'a comparator = 'a -> 'a -> int

val equal : 'a comparator
(** Always-equal comparator; identity of lexicographic composition. *)

val then_by : 'a comparator -> 'a comparator -> 'a comparator
(** On pure comparators, composition is associative with [equal] as identity and
    repeating a comparator is idempotent. It preserves total preorders. It is
    not commutative. Laws compare signs, not arbitrary magnitudes. *)

val priority : Issue.t comparator
(** Priorities 1 through 4 in ascending order, then one equal bucket for all
    other values, including null. *)

val created_at : Issue.t comparator
(** Chronological order with null timestamps last. *)

val identifier : Issue.t comparator
(** The checked identifier's total byte order. *)

val dispatch : Issue.t comparator
(** [dispatch = priority then_by created_at then_by identifier]. This total
    preorder is never used for uniqueness in [Issue_id.Map]. *)
