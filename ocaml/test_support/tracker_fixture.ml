exception Unexpected_io of string

let forbidden operation = raise (Unexpected_io operation)

module Port = struct
  module Pure = Clock.Pure

  type t = unit

  let now () = forbidden "monotonic clock"
  let sleep_until () _ = forbidden "timer"
  let sample () = forbidden "wall clock"
end

module Http = Native_http.Make (Port)
module Adapter = Linear_tracker.Make (Http) (Port)

(* Configuration captures these capabilities; it must never invoke them. *)
let io =
  Adapter.io ~clock:()
    ~http:(fun () -> forbidden "HTTP factory")
    ~omitted:(fun _ -> forbidden "omission reporter")

let registry =
  match
    Tracker_registry.make [ Tracker_registry.Entry ((module Adapter), io) ]
  with
  | Ok registry -> registry
  | Error error -> failwith (Diagnostic.render (Tracker_error.diagnostic error))
