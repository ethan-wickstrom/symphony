type 'a primary = Awaiting | Interrupted | Captured of 'a Native_outcome.t

let classify sw outcome =
  match outcome with
  | Native_outcome.Raised (Eio.Cancel.Cancelled reason, _) -> (
      match Eio.Switch.get_error sw with
      | Some (Eio.Cancel.Cancelled cause) when reason == cause -> Interrupted
      | None | Some _ -> Captured outcome)
  | Native_outcome.Returned _ | Native_outcome.Raised _ -> Captured outcome

let with_scope f =
  let primary = ref Awaiting in
  let closure =
    Native_outcome.capture (fun () ->
        Eio.Switch.run (fun sw ->
            let outcome = Native_outcome.capture (fun () -> f sw) in
            (* Classify before re-raising: that re-raise itself cancels the switch.
               Only its existing matching cause proves induced cancellation. *)
            primary := classify sw outcome;
            (* Eio still cancels and joins children on a raised callback. The
               saved outcome survives its later exception aggregation. *)
            Native_outcome.resolve outcome))
  in
  match !primary with
  | Awaiting | Interrupted | Captured (Native_outcome.Returned (Ok _)) ->
      Native_outcome.resolve closure
  | Captured
      ((Native_outcome.Returned (Error _) | Native_outcome.Raised _) as outcome)
    -> Native_outcome.resolve outcome
