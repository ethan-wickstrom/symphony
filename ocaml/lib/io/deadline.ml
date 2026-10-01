module Make (Clock : Clock.S) = struct
  type ('a, 'e) signal =
    | Completed of ('a, 'e) result
    | Clock_error of Diagnostic.t
    | Expired

  type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

  let capture action =
    try Returned (action ())
    with exn -> Raised (exn, Printexc.get_raw_backtrace ())

  let run clock ~delay ~on_error ~on_timeout action =
    match Clock.now clock with
    | Error error -> Error (on_error error)
    | Ok start -> (
        let due = Clock.Pure.after start delay in
        let winner =
          Eio.Fiber.first
            (fun () -> capture (fun () -> Completed (action ())))
            (fun () ->
              capture (fun () ->
                  match Clock.sleep_until clock due with
                  | Ok () -> Expired
                  | Error error -> Clock_error error))
        in
        match winner with
        | Raised (exn, trace) -> Printexc.raise_with_backtrace exn trace
        | Returned (Completed result) -> result
        | Returned (Clock_error error) -> Error (on_error error)
        | Returned Expired -> Error (on_timeout ()))
end
