let ( let* ) = Result.bind

let get tree keys =
  List.fold_left
    (fun node key -> Option.bind node (fun n -> Config_value.field n key))
    (Some tree) keys

let reference s =
  let first = function
    | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
    | _ -> false
  in
  let later c = first c || (c >= '0' && c <= '9') in
  if
    String.length s > 1
    && s.[0] = '$'
    && first s.[1]
    && String.for_all later (String.sub s 1 (String.length s - 1))
  then Some (String.sub s 1 (String.length s - 1))
  else None

let resolve env s =
  match reference s with
  | Some name -> (
      match Environment.lookup env name with
      | Some v -> Ok v
      | None ->
          Error
            ("environment variable " ^ name
           ^ " is missing; set it or change the reference"))
  | None -> Ok s

let text env v =
  match Config_value.view v with
  | Config_value.String s -> resolve env s
  | Config_value.Null
  | Config_value.Bool _
  | Config_value.Number _
  | Config_value.Sequence _
  | Config_value.Mapping _ -> Error "expected a string"

let decimal s =
  let digits =
    if String.starts_with ~prefix:"-" s || String.starts_with ~prefix:"+" s then
      String.sub s 1 (String.length s - 1)
    else s
  in
  digits <> "" && String.for_all (fun c -> c >= '0' && c <= '9') digits

type numeral = Decimal | Core

let integer env v =
  let* s, kind =
    match Config_value.view v with
    | Config_value.String s ->
        let* s = resolve env s in
        Ok (s, Decimal)
    | Config_value.Number s -> Ok (s, Core)
    | Config_value.Null
    | Config_value.Bool _
    | Config_value.Sequence _
    | Config_value.Mapping _ -> Error "expected an integer"
  in
  let value = s in
  let unsigned =
    if
      String.starts_with ~prefix:"-" value
      || String.starts_with ~prefix:"+" value
    then String.sub value 1 (String.length value - 1)
    else value
  in
  let radix =
    String.starts_with ~prefix:"0x" unsigned
    || String.starts_with ~prefix:"0o" unsigned
  in
  let core_int =
    kind = Core
    && (radix
       || (not (String.contains value '.'))
          && (not (String.contains value 'e'))
          && not (String.contains value 'E'))
  in
  if not (decimal value || core_int) then Error "expected an exact integer"
  else
    try Ok (Z.of_string value)
    with Invalid_argument _ -> Error "invalid integer"

let rec sequence = function
  | [] -> Ok []
  | x :: xs ->
      let* x = x in
      let* xs = sequence xs in
      Ok (x :: xs)

let strings env v =
  match Config_value.view v with
  | Config_value.Sequence xs -> sequence (List.map (text env) xs)
  | Config_value.Null
  | Config_value.Bool _
  | Config_value.Number _
  | Config_value.String _
  | Config_value.Mapping _ -> Error "expected a list of strings"

let mapping v =
  match Config_value.view v with
  | Config_value.Mapping xs -> Ok xs
  | Config_value.Null
  | Config_value.Bool _
  | Config_value.Number _
  | Config_value.String _
  | Config_value.Sequence _ -> Error "expected a mapping"

let rec json v =
  let* v =
    match Config_value.view v with
    | Config_value.Null -> Ok Json.Null
    | Config_value.Bool b -> Ok (Json.Bool b)
    | Config_value.Number n -> Ok (Json.Number n)
    | Config_value.String s -> Ok (Json.String s)
    | Config_value.Sequence xs ->
        let* xs = sequence (List.map json xs) in
        Ok (Json.Array xs)
    | Config_value.Mapping xs ->
        let* xs =
          sequence
            (List.map
               (fun (k, v) ->
                 let* v = json v in
                 Ok (k, v))
               xs)
        in
        Ok (Json.Object xs)
  in
  Json.of_view v

let path env ~base s =
  let b = Buffer.create (String.length s) in
  let is_name = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let rec expand i =
    if i = String.length s then Ok (Buffer.contents b)
    else if s.[i] <> '$' then (
      Buffer.add_char b s.[i];
      expand (i + 1))
    else
      let start = i + 1 in
      let brace = start < String.length s && s.[start] = '{' in
      let start = if brace then start + 1 else start in
      let rec end_name j =
        if j < String.length s && is_name s.[j] then end_name (j + 1) else j
      in
      let last = end_name start in
      if last = start || (brace && (last = String.length s || s.[last] <> '}'))
      then Error "invalid environment reference in path"
      else
        let name = String.sub s start (last - start) in
        match Environment.lookup env name with
        | None ->
            Error
              ("path environment variable " ^ name
             ^ " is missing; set it or change the reference")
        | Some v ->
            Buffer.add_string b v;
            expand (if brace then last + 1 else last)
  in
  let* s = expand 0 in
  let* s =
    if s = "~" || String.starts_with ~prefix:"~/" s then
      match Environment.lookup env "HOME" with
      | None ->
          Error "HOME is missing; set it or use an absolute workspace.root"
      | Some home ->
          let* home = Absolute_path.parse home in
          Ok (Absolute_path.display home ^ String.sub s 1 (String.length s - 1))
    else if String.starts_with ~prefix:"~" s then
      Error "named-user home expansion is unsupported"
    else Ok s
  in
  if String.trim s = "" then Error "path must be nonempty"
  else
    Absolute_path.parse
      (if Filename.is_relative s then
         Filename.concat (Absolute_path.display base) s
       else s)

let diagnostic ~key message =
  Diagnostic.make
    ~site:
      (Diagnostic.Workflow { file = "WORKFLOW.md"; key = Some key; line = None })
    ~message
    ~remedy:("set " ^ key ^ " to the documented value")
