(** Slice 1 boundary examples and independently generated configuration laws. *)

module Make (Config : Config_layer.S) : sig
  val tests : registry:Config.registry -> unit Alcotest.test_case list
  val properties : registry:Config.registry -> QCheck2.Test.t list
end
