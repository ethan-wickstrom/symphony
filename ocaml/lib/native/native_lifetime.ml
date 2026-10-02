module Loans = Map.Make (struct
  type t = Count.t

  let compare = Count.compare
end)

type loan = { cancel : Eio.Cancel.t; closed : unit Eio.Promise.t }
type phase = Held of loan Loans.t | Closing of unit Eio.Promise.t | Released
type 'e failure = Closed | Rejected of 'e
type 'a completion = Pending | Finished of 'a Native_outcome.t

type t = {
  mutex : Eio.Mutex.t;
  mutable phase : phase;
  mutable next : Count.t;
  report : exn * Printexc.raw_backtrace -> unit;
}

exception Owner_closed
exception Callback_rejected
exception Callback_failed

let locked t f = Eio.Mutex.use_rw ~protect:true t.mutex f

let create ~report =
  {
    mutex = Eio.Mutex.create ();
    phase = Held Loans.empty;
    next = Count.zero;
    report;
  }

let held t =
  locked t (fun () ->
      match t.phase with
      | Held _ -> true
      | Closing _ | Released -> false)

let admit t cancel closed =
  locked t (fun () ->
      match t.phase with
      | Closing _ | Released -> None
      | Held loans ->
          let id = t.next in
          t.next <- Count.add id Count.one;
          t.phase <- Held (Loans.add id { cancel; closed } loans);
          Some id)

let finish t id closed =
  Eio.Cancel.protect (fun () ->
      locked t (fun () ->
          (match t.phase with
          | Held loans -> t.phase <- Held (Loans.remove id loans)
          | Closing _ | Released -> ());
          Eio.Promise.resolve closed ()))

let failures = Eio_failure.leaves

let with_scope t f =
  Eio.Cancel.sub (fun cancel ->
      let closed, resolver = Eio.Promise.create () in
      match admit t cancel closed with
      | None -> Error Closed
      | Some id -> (
          let primary = ref Pending in
          let release =
            Native_outcome.capture (fun () ->
                Eio.Switch.run (fun sw ->
                    let outcome =
                      Native_outcome.capture (fun () ->
                          Eio.Fiber.check ();
                          f ~sw)
                    in
                    primary := Finished outcome;
                    match outcome with
                    | Native_outcome.Returned (Ok _) -> ()
                    | Native_outcome.Returned (Error _) ->
                        Eio.Switch.fail sw Callback_rejected
                    (* Keep the primary outside Eio's exception aggregation. Its
                       IO normalization otherwise erases exception identity. *)
                    | Native_outcome.Raised _ ->
                        Eio.Switch.fail sw Callback_failed))
          in
          finish t id resolver;
          let report () =
            match release with
            | Native_outcome.Returned () -> ()
            | Native_outcome.Raised (ex, bt) ->
                List.iter
                  (fun ((failure, _) as value) ->
                    match failure with
                    | Callback_rejected
                    | Callback_failed
                    | Eio.Cancel.Cancelled _ -> ()
                    | _ ->
                        ignore
                          (Native_outcome.capture (fun () ->
                               Eio.Cancel.protect (fun () -> t.report value))))
                  (failures (ex, bt))
          in
          match !primary with
          | Pending ->
              Native_outcome.resolve release;
              invalid_arg "Lifetime scope never entered"
          | Finished (Native_outcome.Returned (Error error)) ->
              report ();
              Error (Rejected error)
          | Finished
              (Native_outcome.Raised (Eio.Cancel.Cancelled Owner_closed, _)) ->
              report ();
              Error Closed
          | Finished (Native_outcome.Raised (ex, bt)) ->
              report ();
              Printexc.raise_with_backtrace ex bt
          | Finished (Native_outcome.Returned (Ok value)) -> (
              match release with
              | Native_outcome.Returned () -> Ok value
              | Native_outcome.Raised (Eio.Cancel.Cancelled Owner_closed, _) ->
                  Error Closed
              | Native_outcome.Raised (ex, bt) ->
                  Printexc.raise_with_backtrace ex bt)))

let close t =
  Eio.Cancel.protect (fun () ->
      let action =
        locked t (fun () ->
            match t.phase with
            | Released -> `Done
            | Closing closed -> `Join closed
            | Held loans ->
                let closed, resolver = Eio.Promise.create () in
                t.phase <- Closing closed;
                `Close (loans, resolver))
      in
      match action with
      | `Done -> ()
      | `Join closed -> Eio.Promise.await closed
      | `Close (loans, resolver) -> (
          let failures =
            Loans.fold
              (fun _ loan failures ->
                match
                  Native_outcome.capture (fun () ->
                      Eio.Cancel.cancel loan.cancel Owner_closed)
                with
                | Native_outcome.Returned () -> failures
                | Native_outcome.Raised _ as failure -> failure :: failures)
              loans []
          in
          Loans.iter (fun _ loan -> Eio.Promise.await loan.closed) loans;
          locked t (fun () ->
              t.phase <- Released;
              Eio.Promise.resolve resolver ());
          match List.rev failures with
          | [] -> ()
          | failure :: _ -> Native_outcome.resolve failure))
