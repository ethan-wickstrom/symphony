module Names = Map.Make (String)
module Keys = Set.Make (String)
module Event = Yaml.Stream.Event

type t = { value : view; line : int; column : int }

and view =
  | Null
  | Bool of bool
  | Number of string
  | String of string
  | Sequence of t list
  | Mapping of (string * t) list

(* Bounds cover the source and the logical tree, including shared alias occurrences. *)
let max_input_bytes = 1_048_576
let max_depth = 64
let max_nodes = 32_768
let max_expanded_bytes = 4_194_304
let tag_prefix = "tag:yaml.org,2002:"
let string_tag = tag_prefix ^ "str"
let null_tag = tag_prefix ^ "null"
let bool_tag = tag_prefix ^ "bool"
let integer_tag = tag_prefix ^ "int"
let float_tag = tag_prefix ^ "float"
let sequence_tag = tag_prefix ^ "seq"
let mapping_tag = tag_prefix ^ "map"
let null_spellings = [ ""; "~"; "null"; "Null"; "NULL" ]
let true_spellings = [ "true"; "True"; "TRUE" ]
let false_spellings = [ "false"; "False"; "FALSE" ]
let infinity_spellings = [ ".inf"; ".Inf"; ".INF" ]
let nan_spellings = [ ".nan"; ".NaN"; ".NAN" ]

type int_state =
  | Int_start
  | Int_sign
  | Int_zero
  | Int_decimal
  | Int_octal_start
  | Int_octal
  | Int_hex_start
  | Int_hex
  | Int_invalid

let is_integer text =
  let step state char =
    match (state, char) with
    | Int_start, ('+' | '-') -> Int_sign
    | Int_start, '0' -> Int_zero
    | (Int_start | Int_sign | Int_zero | Int_decimal), '0' .. '9' -> Int_decimal
    | Int_zero, 'o' -> Int_octal_start
    | Int_zero, 'x' -> Int_hex_start
    | (Int_octal_start | Int_octal), '0' .. '7' -> Int_octal
    | (Int_hex_start | Int_hex), ('0' .. '9' | 'a' .. 'f' | 'A' .. 'F') ->
        Int_hex
    | ( ( Int_start
        | Int_sign
        | Int_zero
        | Int_decimal
        | Int_octal_start
        | Int_octal
        | Int_hex_start
        | Int_hex
        | Int_invalid ),
        _ ) -> Int_invalid
  in
  match String.fold_left step Int_start text with
  | Int_zero | Int_decimal | Int_octal | Int_hex -> true
  | Int_start | Int_sign | Int_octal_start | Int_hex_start | Int_invalid ->
      false

type float_state =
  | Float_start
  | Float_sign
  | Float_dot
  | Float_digits
  | Float_fraction
  | Float_exp
  | Float_exp_sign
  | Float_exp_digits
  | Float_invalid

let is_float text =
  let step state char =
    match (state, char) with
    | Float_start, ('+' | '-') -> Float_sign
    | (Float_start | Float_sign), '.' -> Float_dot
    | (Float_start | Float_sign | Float_digits), '0' .. '9' -> Float_digits
    | (Float_dot | Float_fraction), '0' .. '9' -> Float_fraction
    | Float_digits, '.' -> Float_fraction
    | (Float_digits | Float_fraction), ('e' | 'E') -> Float_exp
    | Float_exp, ('+' | '-') -> Float_exp_sign
    | (Float_exp | Float_exp_sign | Float_exp_digits), '0' .. '9' ->
        Float_exp_digits
    | ( ( Float_start
        | Float_sign
        | Float_dot
        | Float_digits
        | Float_fraction
        | Float_exp
        | Float_exp_sign
        | Float_exp_digits
        | Float_invalid ),
        _ ) -> Float_invalid
  in
  match String.fold_left step Float_start text with
  | Float_digits | Float_fraction | Float_exp_digits -> true
  | Float_start
  | Float_sign
  | Float_dot
  | Float_exp
  | Float_exp_sign
  | Float_invalid -> false

let is_nonfinite text =
  List.mem text nan_spellings
  || List.exists
       (fun spelling ->
         text = spelling || text = "+" ^ spelling || text = "-" ^ spelling)
       infinity_spellings

let boolean text =
  if List.mem text true_spellings then Some true
  else if List.mem text false_spellings then Some false
  else None

let implicit_scalar text =
  if List.mem text null_spellings then Ok Null
  else
    match boolean text with
    | Some value -> Ok (Bool value)
    | None ->
        if is_nonfinite text then
          Error "nonfinite YAML numbers are not supported"
        else if is_integer text || is_float text then Ok (Number text)
        else Ok (String text)

let scalar_value (scalar : Yaml.scalar) =
  match scalar.Yaml.tag with
  | None | Some "?" -> (
      match scalar.Yaml.style with
      | `Plain | `Any -> implicit_scalar scalar.Yaml.value
      | `Single_quoted | `Double_quoted | `Literal | `Folded ->
          Ok (String scalar.Yaml.value))
  | Some "!" -> Ok (String scalar.Yaml.value)
  | Some tag ->
      if tag = string_tag then Ok (String scalar.Yaml.value)
      else if tag = null_tag then
        if List.mem scalar.Yaml.value null_spellings then Ok Null
        else Error "the null tag requires a YAML null scalar"
      else if tag = bool_tag then
        match boolean scalar.Yaml.value with
        | Some value -> Ok (Bool value)
        | None -> Error "the boolean tag requires a YAML boolean scalar"
      else if tag = integer_tag then
        if is_integer scalar.Yaml.value then Ok (Number scalar.Yaml.value)
        else Error "the integer tag requires a YAML integer scalar"
      else if tag = float_tag then
        if is_float scalar.Yaml.value then Ok (Number scalar.Yaml.value)
        else Error "the float tag requires a finite YAML numeric scalar"
      else Error "unsupported YAML tag; use a standard core tag"

let collection_tag expected = function
  | None | Some "!" | Some "?" -> Ok ()
  | Some tag ->
      if tag = expected then Ok ()
      else Error "the YAML collection tag does not match its node kind"

type anchor = Pending of int | Ready of int * t

type reader = {
  parser : Yaml.Stream.parser;
  anchors : anchor Names.t;
  next_anchor : int;
  nodes : int;
  bytes : int;
  position : int * int;
}

let ( let* ) = Result.bind

let error (line, column) message =
  Error (Printf.sprintf "line %d, column %d: %s" line column message)

let position (pos : Event.pos) =
  let mark = pos.Event.start_mark in
  (mark.Yaml.Stream.Mark.line + 1, mark.Yaml.Stream.Mark.column + 1)

let charge reader depth bytes site =
  if depth > max_depth then
    error site "YAML depth limit exceeded; reduce nesting or alias depth"
  else if reader.nodes >= max_nodes then
    error site
      "YAML node limit exceeded; reduce the document or alias expansion"
  else if bytes > max_expanded_bytes - reader.bytes then
    error site "YAML byte expansion limit exceeded; reduce repeated aliases"
  else Ok { reader with nodes = reader.nodes + 1; bytes = reader.bytes + bytes }

let next reader =
  match Yaml.Stream.do_parse reader.parser with
  | Error (`Msg message) -> error reader.position ("invalid YAML: " ^ message)
  | Ok (event, pos) ->
      let site = position pos in
      Ok ((event, site), { reader with position = site })

let open_anchor reader = function
  | None -> (None, reader)
  | Some name ->
      let id = reader.next_anchor in
      ( Some (name, id),
        {
          reader with
          anchors = Names.add name (Pending id) reader.anchors;
          next_anchor = id + 1;
        } )

let finish_anchor reader anchor node =
  match anchor with
  | None -> reader
  | Some (name, id) -> (
      match Names.find_opt name reader.anchors with
      | Some (Pending current) when current = id ->
          {
            reader with
            anchors = Names.add name (Ready (id, node)) reader.anchors;
          }
      | Some (Pending _ | Ready _) | None -> reader)

let node value (line, column) = { value; line; column }

(* Charging the shared tree bounds alias work without storing a second size fact. *)
let rec charge_tree reader depth site tree =
  let bytes =
    match tree.value with
    | String text | Number text -> String.length text
    | Null | Bool _ | Sequence _ | Mapping _ -> 0
  in
  let* reader = charge reader depth bytes site in
  match tree.value with
  | Null | Bool _ | Number _ | String _ -> Ok reader
  | Sequence children -> charge_children reader (depth + 1) site children
  | Mapping fields -> charge_fields reader (depth + 1) site fields

and charge_children reader depth site = function
  | [] -> Ok reader
  | child :: children ->
      let* reader = charge_tree reader depth site child in
      charge_children reader depth site children

and charge_fields reader depth site = function
  | [] -> Ok reader
  | (key, child) :: fields ->
      let* reader = charge reader depth (String.length key) site in
      let* reader = charge_tree reader depth site child in
      charge_fields reader depth site fields

let rec parse_node reader depth (event, site) =
  match event with
  | Event.Scalar scalar ->
      let* reader =
        charge reader depth (String.length scalar.Yaml.value) site
      in
      let* value =
        match scalar_value scalar with
        | Ok value -> Ok value
        | Error message -> error site message
      in
      let anchor, reader = open_anchor reader scalar.Yaml.anchor in
      let result = node value site in
      Ok (result, finish_anchor reader anchor result)
  | Event.Sequence_start start ->
      let* () =
        match collection_tag sequence_tag start.tag with
        | Ok () -> Ok ()
        | Error message -> error site message
      in
      let* reader = charge reader depth 0 site in
      let anchor, reader = open_anchor reader start.anchor in
      let* children, reader = parse_sequence reader (depth + 1) [] in
      let result = node (Sequence children) site in
      Ok (result, finish_anchor reader anchor result)
  | Event.Mapping_start start ->
      let* () =
        match collection_tag mapping_tag start.tag with
        | Ok () -> Ok ()
        | Error message -> error site message
      in
      let* reader = charge reader depth 0 site in
      let anchor, reader = open_anchor reader start.anchor in
      let* fields, reader = parse_mapping reader (depth + 1) Keys.empty [] in
      let result = node (Mapping fields) site in
      Ok (result, finish_anchor reader anchor result)
  | Event.Alias alias -> (
      match Names.find_opt alias.anchor reader.anchors with
      | None -> error site "undefined YAML alias; define its anchor before use"
      | Some (Pending _) -> error site "cyclic YAML alias; use an acyclic value"
      | Some (Ready (_, tree)) ->
          let* reader = charge_tree reader depth site tree in
          Ok (node tree.value site, reader))
  | Event.Stream_start _
  | Event.Document_start _
  | Event.Document_end _
  | Event.Mapping_end
  | Event.Stream_end
  | Event.Sequence_end
  | Event.Nothing -> error site "expected a YAML value"

and parse_sequence reader depth acc =
  let* event, reader = next reader in
  match event with
  | Event.Sequence_end, _ -> Ok (List.rev acc, reader)
  | ( ( Event.Stream_start _
      | Event.Document_start _
      | Event.Document_end _
      | Event.Mapping_start _
      | Event.Mapping_end
      | Event.Stream_end
      | Event.Scalar _
      | Event.Sequence_start _
      | Event.Alias _
      | Event.Nothing ),
      _ ) ->
      let* child, reader = parse_node reader depth event in
      parse_sequence reader depth (child :: acc)

and parse_mapping reader depth keys acc =
  let* event, reader = next reader in
  match event with
  | Event.Mapping_end, _ -> Ok (List.rev acc, reader)
  | ( ( Event.Stream_start _
      | Event.Document_start _
      | Event.Document_end _
      | Event.Mapping_start _
      | Event.Stream_end
      | Event.Scalar _
      | Event.Sequence_start _
      | Event.Sequence_end
      | Event.Alias _
      | Event.Nothing ),
      _ ) -> (
      let* key_node, reader = parse_node reader depth event in
      match key_node.value with
      | String key ->
          let site = (key_node.line, key_node.column) in
          if Keys.mem key keys then
            error site
              "duplicate YAML mapping key; keep one binding for this key"
          else
            let* value_event, reader = next reader in
            let* value, reader = parse_node reader depth value_event in
            parse_mapping reader depth (Keys.add key keys) ((key, value) :: acc)
      | Null | Bool _ | Number _ | Sequence _ | Mapping _ ->
          error
            (key_node.line, key_node.column)
            "YAML mapping keys must be strings; quote scalar keys")

type boundary = Stream_begin | Document_stop | Stream_stop

let boundary = function
  | Event.Stream_start _ -> Some Stream_begin
  | Event.Document_end _ -> Some Document_stop
  | Event.Stream_end -> Some Stream_stop
  | Event.Document_start _
  | Event.Mapping_start _
  | Event.Mapping_end
  | Event.Scalar _
  | Event.Sequence_start _
  | Event.Sequence_end
  | Event.Alias _
  | Event.Nothing -> None

let expect expected message reader =
  let* (event, site), reader = next reader in
  if boundary event = Some expected then Ok reader else error site message

let parse_stream parser =
  let reader =
    {
      parser;
      anchors = Names.empty;
      next_anchor = 0;
      nodes = 0;
      bytes = 0;
      position = (1, 1);
    }
  in
  let* reader = expect Stream_begin "expected a YAML stream" reader in
  let* (event, site), reader = next reader in
  let* () =
    match event with
    | Event.Document_start { version = None | Some `V1_2; _ } -> Ok ()
    | Event.Document_start { version = Some `V1_1; _ } ->
        error site "YAML 1.1 is not supported; use the YAML 1.2 core schema"
    | Event.Stream_start _
    | Event.Document_end _
    | Event.Mapping_start _
    | Event.Mapping_end
    | Event.Stream_end
    | Event.Scalar _
    | Event.Sequence_start _
    | Event.Sequence_end
    | Event.Alias _
    | Event.Nothing -> error site "expected exactly one YAML document"
  in
  let* event, reader = next reader in
  let* result, reader = parse_node reader 1 event in
  let* reader =
    expect Document_stop "expected the end of the YAML document" reader
  in
  let* _ =
    expect Stream_stop
      "extra YAML document; keep exactly one front-matter document" reader
  in
  Ok result

let parse source =
  if String.length source > max_input_bytes then
    Error "YAML source exceeds 1048576 bytes; shorten the front matter"
  else
    match Yaml.Stream.with_parser source parse_stream with
    | Ok result -> result
    | Error (`Msg message) ->
        Error ("cannot initialize the YAML parser: " ^ message)

let view node = node.value
let location node = (node.line, node.column)

let field node key =
  match node.value with
  | Mapping fields -> List.assoc_opt key fields
  | Null | Bool _ | Number _ | String _ | Sequence _ -> None
