type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture f =
  match f () with
  | result -> Returned result
  | exception error -> Raised (error, Printexc.get_raw_backtrace ())

let restore = function
  | Returned value -> value
  | Raised (error, backtrace) -> Printexc.raise_with_backtrace error backtrace

type 'key secondary = Secondary of 'key * exn

let same_error a b =
  if a == b then true
  else
    match (a, b) with
    | Eio.Io (a, ca), Eio.Io (b, cb) -> a == b && ca == cb
    | _ -> false

let rec consume error = function
  | [] -> None
  | original :: rest ->
      if same_error error original then Some rest
      else
        Option.map (fun remaining -> original :: remaining) (consume error rest)

let secondary key ~primary error =
  let leaves error =
    List.map fst (Eio_failure.leaves (error, Printexc.get_callstack 0))
  in
  (* Eio erases IO wrapper identity. Subtract occurrences, not a set of identities:
     a later independent IO error may share the same error/context pair. *)
  let primary = List.concat_map leaves primary in
  let _, reversed =
    List.fold_left
      (fun (remaining, faults) error ->
        match error with
        | Eio.Cancel.Cancelled _ -> (remaining, faults)
        | error -> (
            match consume error remaining with
            | Some remaining -> (remaining, faults)
            | None -> (remaining, Secondary (key, error) :: faults)))
      (primary, []) (leaves error)
  in
  List.rev reversed

type primary =
  | Checked of Diagnostic.t
  | Unexpected of exn * Printexc.raw_backtrace

type 'key t = {
  mutable primary : primary option;
  mutable secondary : 'key secondary list;
}

let create () = { primary = None; secondary = [] }
let failed t = Option.is_some t.primary
let retain t faults = t.secondary <- List.rev_append faults t.secondary

let record t key = function
  | Returned (Ok ()) -> ()
  | Returned (Error diagnostic) ->
      if not (failed t) then t.primary <- Some (Checked diagnostic)
  | Raised (error, backtrace) -> begin
      match t.primary with
      | None -> t.primary <- Some (Unexpected (error, backtrace))
      | Some _ -> retain t (secondary key ~primary:[] error)
    end

let prefer t fallback =
  match t.primary with
  | None -> fallback
  | Some (Checked diagnostic) -> Returned (Error diagnostic)
  | Some (Unexpected (error, backtrace)) -> Raised (error, backtrace)

let finish t = restore (prefer t (Returned (Ok ())))

let flush t ~describe ~report =
  let faults = List.rev t.secondary in
  t.secondary <- [];
  List.iter
    (fun (Secondary (key, error)) ->
      let diagnostic =
        Diagnostic.make
          ~site:(Diagnostic.Host ("service " ^ describe key))
          ~message:("secondary cleanup defect: " ^ Printexc.exn_slot_name error)
          ~remedy:"Inspect the owning port's cleanup and cancellation handlers."
      in
      match capture (fun () -> report key diagnostic) with
      | Returned () -> ()
      | Raised (error, backtrace) ->
          if not (failed t) then record t key (Raised (error, backtrace)))
    faults
