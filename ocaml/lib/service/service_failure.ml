type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture f =
  match f () with
  | result -> Returned result
  | exception error -> Raised (error, Printexc.get_raw_backtrace ())

let restore = function
  | Returned value -> value
  | Raised (error, backtrace) -> Printexc.raise_with_backtrace error backtrace

let flatten = function
  | Returned outcome -> outcome
  | Raised (error, backtrace) -> Raised (error, backtrace)

type 'key secondary = Secondary of 'key * exn

let rec secondary key ~primary = function
  | Eio.Exn.Multiple errors ->
      List.concat_map (fun (error, _) -> secondary key ~primary error) errors
  | Eio.Cancel.Cancelled _ -> []
  | error ->
      if List.exists (fun original -> original == error) primary then []
      else [ Secondary (key, error) ]

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
      | Some previous ->
          let primary =
            match previous with
            | Checked _ -> []
            | Unexpected (original, _) -> [ original ]
          in
          retain t (secondary key ~primary error)
    end

let prefer t fallback =
  match t.primary with
  | None -> fallback
  | Some (Checked diagnostic) -> Returned (Error diagnostic)
  | Some (Unexpected (error, backtrace)) -> Raised (error, backtrace)

let check t = restore (prefer t (Returned (Ok ())))

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
      | Returned () | Raised _ -> ())
    faults
