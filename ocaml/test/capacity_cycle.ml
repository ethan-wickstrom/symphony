type phase = Idle | Busy
type input = Poll | Other
type 'instant t = { phase : phase; start : 'instant option }
type 'instant interval = { started : 'instant; ended : 'instant }

let create () = { phase = Idle; start = None }
let phase value = value.phase

let observe ~at ~now ~input ~phase previous =
  (* Retained timer ticks cannot move an unfinished cycle's start. *)
  let start =
    if previous.phase = Idle && phase = Busy && input = Poll then Some at
    else previous.start
  in
  match (phase, start) with
  | Idle, Some started ->
      ({ phase; start = None }, Some { started; ended = now })
  | Idle, None | Busy, (None | Some _) -> ({ phase; start }, None)
