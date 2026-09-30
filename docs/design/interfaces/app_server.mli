(** Mechanism: generated-schema codec, handshake and turns over injected drivers.
    No ambient process, time, environment, filesystem, or tracker capabilities. *)

module Make
    (Process : Agent_process.S)
    (Clock : Clock.S) : sig
  include Agent_runner.TRANSPORT with module Path = Process.Path
  val create : process:Process.t -> clock:Clock.t -> t
  (** Stable 0.159.2 profile. Request ID registry belongs to the session's single
      protocol fiber; futures and readers are scoped to its child switch. *)

end
