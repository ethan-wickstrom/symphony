(** One actual Linear assembly for offline test and fuzz configuration. *)

exception Unexpected_io of string
(** Every captured clock, transport factory and warning operation raises this
    defect. Resolving configuration must use none of them. *)

module Adapter : Tracker_adapter.S
(** Settings and IO come from the same Linear functor instance. The pure HTTP
    constructors are the native driver's checked endpoint/header boundaries. *)

val registry : Tracker_registry.t
(** Frozen registry containing [Adapter] and its deliberately offline IO. *)
