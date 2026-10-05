type refresh = Queued | Coalesced

type unavailable =
  | Timeout
  | Shutting_down
  | Clock_unavailable
  | Projection_unavailable

module type S = sig
  type t

  val snapshot : t -> (Snapshot.t, unavailable) result
  val refresh : t -> (refresh, unavailable) result
end
