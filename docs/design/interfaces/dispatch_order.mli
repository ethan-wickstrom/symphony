type 'a comparator = 'a -> 'a -> int
val equal : 'a comparator
val then_by : 'a comparator -> 'a comparator -> 'a comparator
(** Comparator composition monoid: associative; always-equal is identity.
    Preserves total preorders; repeating a comparator is idempotent. Not commutative;
    comparison equality need not be identity. Laws compare signs, not arbitrary magnitudes. *)

val priority : Issue.t comparator
val created_at : Issue.t comparator
val identifier : Issue.t comparator
val dispatch : Issue.t comparator
(** [dispatch = priority then_by created_at then_by identifier]. Priority 1..4
    precedes all other values; timestamps put null last; identifiers use byte order.
    This preorder is never reused as the Issue_id.Map uniqueness comparator. *)
