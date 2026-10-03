type piece = { level : int; bytes : string }
type t = { pieces : piece list; length : int }

type error =
  | Oversized of Diagnostic.t
  | Invalid_json of Diagnostic.t
  | Truncated of Diagnostic.t

type next = Open of t | Failed of error
type batch = { frames : Json.t list; next : next }

let max_bytes = 1_048_576
let empty = { pieces = []; length = 0 }

let diagnostic message =
  Diagnostic.make
    ~site:(Diagnostic.Protocol { method_name = "JSONL"; request_id = None })
    ~message ~remedy:"Check the selected Codex stdio protocol profile"

let level length =
  let rec count n bits = if n <= 1 then bits else count (n / 2) (bits + 1) in
  count length 0

(* Merge equal size classes so tiny reads cannot grow a fragment list or
   repeatedly copy the entire residual. Pieces remain in reverse wire order. *)
let add state bytes =
  let length = String.length bytes in
  let rec merge piece = function
    | old :: rest when old.level <= piece.level ->
        let bytes = old.bytes ^ piece.bytes in
        merge { level = level (String.length bytes); bytes } rest
    | pieces -> piece :: pieces
  in
  if length = 0 then state
  else
    {
      pieces = merge { level = level length; bytes } state.pieces;
      length = state.length + length;
    }

let source state =
  String.concat "" (List.rev_map (fun piece -> piece.bytes) state.pieces)

let feed state chunk =
  let size = String.length chunk in
  let rec consume state offset frames =
    if offset = size then { frames = List.rev frames; next = Open state }
    else
      let newline = String.index_from_opt chunk offset '\n' in
      let boundary = Option.value newline ~default:size in
      let length = boundary - offset in
      if length > max_bytes - state.length then
        {
          frames = List.rev frames;
          next = Failed (Oversized (diagnostic "JSONL frame exceeds 1 MiB"));
        }
      else
        let state = add state (String.sub chunk offset length) in
        match newline with
        | None -> { frames = List.rev frames; next = Open state }
        | Some boundary -> (
            match Json.parse (source state) with
            | Error _ ->
                {
                  frames = List.rev frames;
                  next =
                    Failed (Invalid_json (diagnostic "Invalid JSONL frame"));
                }
            | Ok frame -> consume empty (boundary + 1) (frame :: frames))
  in
  consume state 0 []

let finish state =
  if state.length = 0 then Ok ()
  else Error (Truncated (diagnostic "EOF before JSONL newline"))
