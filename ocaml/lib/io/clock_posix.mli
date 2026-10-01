(** Eio time capabilities adapted to exact Symphony deadlines. *)

include Clock.S with module Pure = Clock.Pure

val create : mono:_ Eio.Time.Mono.t -> wall:_ Eio.Time.clock -> t
(** Capture explicit capabilities without reading them. The monotonic capability
    must obey Eio's monotonic-clock law; wall time may jump independently.
    Native targets advance by at most one day and remain representable. At the
    native horizon, a future logical deadline returns an operator diagnostic.
    Sys_error, Unix errors and Eio IO failures become diagnostics; cancellation
    and other defects propagate. Every operation runs inside an Eio context. *)
