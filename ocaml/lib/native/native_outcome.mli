(** Preserve a primary outcome while completing independent release obligations.
*)
type 'a t = Returned of 'a | Raised of exn * Printexc.raw_backtrace

val capture : (unit -> 'a) -> 'a t
(** Captures the original exception and its backtrace without classifying it. *)

val resolve : 'a t -> 'a
(** [resolve (capture f)] has the same observation as [f ()], including the
    physical exception and original backtrace. *)
