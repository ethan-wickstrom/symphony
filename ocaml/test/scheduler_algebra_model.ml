type dispatch_key = {
  priority : int option;
  created_at : int option;
  identifier : string;
}

let dispatch left right =
  let key value =
    let priority =
      match value.priority with
      | Some ((1 | 2 | 3 | 4) as n) -> n
      | Some _ | None -> 5
    in
    let created =
      match value.created_at with
      | Some n -> (0, n)
      | None -> (1, 0)
    in
    (priority, created, value.identifier)
  in
  Stdlib.compare (key left) (key right)

let backoff ~attempt ~cap =
  let cap_bits = Z.numbits cap in
  (* Above this bound even a base of one already exceeds cap. *)
  if Z.compare attempt (Z.of_int (cap_bits + 1)) > 0 then cap
  else Z.min cap (Z.shift_left (Z.of_int 10000) (Z.to_int attempt - 1))

type totals = { input : Z.t; output : Z.t; total : Z.t }

let zero = { input = Z.zero; output = Z.zero; total = Z.zero }

let collect combine values =
  let field project = List.fold_left combine Z.zero (List.map project values) in
  {
    input = field (fun value -> value.input);
    output = field (fun value -> value.output);
    total = field (fun value -> value.total);
  }

let sum = collect Z.add
let supremum = collect Z.max

let growth ~previous ~current =
  let field before after = Z.max Z.zero (Z.sub after before) in
  {
    input = field previous.input current.input;
    output = field previous.output current.output;
    total = field previous.total current.total;
  }

type identity_error = Wrong_run | Wrong_thread
type watermark = { run : string; thread : string; reports : totals list }

let initial ~run ~thread = { run; thread; reports = [] }
let absolute watermark = supremum watermark.reports

let observe watermark ~run ~thread ~report =
  if not (String.equal watermark.run run) then Error Wrong_run
  else if not (String.equal watermark.thread thread) then Error Wrong_thread
  else
    let next = { watermark with reports = report :: watermark.reports } in
    let delta =
      growth ~previous:(absolute watermark) ~current:(absolute next)
    in
    Ok (next, delta)
