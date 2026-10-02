(** Bounded workflow IO composed with the checked config parser. *)
module Make (Config : Config_layer.S) (IO : Workflow_loader.IO) : sig
  type config = Config.t
  type t
  type request = { id : Request_id.t; file : Workflow_path.t }

  val create : io:IO.t -> registry:Config.registry -> env:Environment.t -> t
  (** Capture explicit immutable capabilities; no IO or current-adapter lookup.
  *)

  val load : t -> request -> (config, Config_layer.error) result
  (** Workflow_loader.Make(IO).load, then Config.resolve on the same document.
      The registry constructs new bindings; each earlier request retains its
      already frozen binding. Cancellation/defects remain outside reload values.
  *)
end
