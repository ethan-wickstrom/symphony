(** Runtime-selected pure adapter settings registry; never performs tracker
    requests. The live service instantiates Config_layer with its own
    Tracker.CONFIG contract. *)

type entry =
  | Entry : (module Tracker_adapter.CONFIG with type settings = 's) -> entry

include Tracker.CONFIG

val make : entry list -> (t, Tracker_error.t) result
