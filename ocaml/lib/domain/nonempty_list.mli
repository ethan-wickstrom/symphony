type 'a t

val singleton : 'a -> 'a t
val of_list : 'a list -> 'a t option

val to_list : 'a t -> 'a list
(** [of_list (to_list xs) = Some xs]; [to_list xs <> []]. *)

val map : ('a -> 'b) -> 'a t -> 'b t
(** Functor laws: identity and composition. *)

val fold : ('a -> 'b -> 'a) -> 'a -> 'b t -> 'a

val append : 'a t -> 'a t -> 'a t
(** Associative semigroup; agrees with list append. No empty identity. *)
