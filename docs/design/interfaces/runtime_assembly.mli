(** Signature witness for the runtime composition; not a new production helper.
*)

module Http : Http_transport.S
module Clock : Clock.S
module Linear : module type of Linear_tracker.Make (Http) (Clock)

module Registry :
  Tracker.S
    with type t = Tracker_registry.t
     and module Contract = Tracker_registry.Contract

module Config :
  Config_layer.S
    with type tracker = Registry.Contract.binding
     and type registry = Registry.t

val registry : Linear.io -> (Registry.t, Tracker_error.t) result
(** One entry packages exactly Linear.settings and Linear.io. The host supplies
    explicit net/fs/clock/trust capabilities to the deferred HTTP factory;
    Linear.io only captures the closure. Crypto activation occurs only for an
    explicit tracker read or service run. Offline Config.resolve cannot activate
    crypto or read trust.

    Keep the host capability scope open until all old binding work drains.
    Config.tracker = Registry.Contract.binding; Config.registry = Registry.t;
    Linear.settings = Linear.Config.settings; Registry.Contract.Issue = Issue.
    Agent's portable Contract shares this exact Issue module at assembly. *)
