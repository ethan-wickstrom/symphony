(** Owner-facing status capability. Expected unavailability is a value; port
    cancellation and unexpected defects propagate. No last-good snapshot cache.
*)

type refresh = Queued | Coalesced

type unavailable =
  | Timeout
  | Shutting_down
  | Clock_unavailable
  | Projection_unavailable

module type S = sig
  type t

  val snapshot : t -> (Snapshot.t, unavailable) result
  (** A fresh owner projection from one paired clock sample. Reading emits no
      scheduling command and changes no owner. The interpreter bounds its wait.
  *)

  val refresh : t -> (refresh, unavailable) result
  (** Queue an immediate poll/reconciliation request. Repeated pending requests
      coalesce: one accepted trigger followed by any repetitions creates one
      pending trigger. It does not reload configuration from the HTTP fiber. *)
end
