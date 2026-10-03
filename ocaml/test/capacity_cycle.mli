type phase = Idle | Busy
type input = Poll | Other
type 'instant t
type 'instant interval = { started : 'instant; ended : 'instant }

val create : unit -> 'instant t
val phase : 'instant t -> phase

val observe :
  at:'instant ->
  now:'instant ->
  input:input ->
  phase:phase ->
  'instant t ->
  'instant t * 'instant interval option
(** Start an accepted poll's Idle-to-Busy transition; finish only at Idle.
    Retained busy ticks preserve its start. [now] includes observer work. *)
