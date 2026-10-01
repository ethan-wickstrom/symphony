type t = {
  scope : Tracker_scope.t;
  issue_id : Issue_id.t;
  identifier : Issue_identifier.t;
  device : int64;
  inode : int64;
}

(* This bounds protected-file corruption without constraining normal tracker IDs. *)
let max_bytes = 16 * 1024
let current_version = 1
let hex_width = 16
let hex_shift = 4
let decimal_digits = 10
let version_field = "version"
let scope_field = "scope"
let issue_id_field = "issue_id"
let identifier_field = "identifier"
let device_field = "device"
let inode_field = "inode"

let field_names =
  [
    version_field;
    scope_field;
    issue_id_field;
    identifier_field;
    device_field;
    inode_field;
  ]

let scope owner = owner.scope
let issue_id owner = owner.issue_id
let identifier owner = owner.identifier
let device owner = owner.device
let inode owner = owner.inode

let equal a b =
  Tracker_scope.equal a.scope b.scope
  && Issue_id.equal a.issue_id b.issue_id
  && Issue_identifier.equal a.identifier b.identifier
  && Int64.equal a.device b.device
  && Int64.equal a.inode b.inode

let hex value = Printf.sprintf "%0*Lx" hex_width value

let encode owner =
  (* The fixed scalar shape and checked strings make serialization total. *)
  Yojson.Safe.to_string
    (`Assoc
       [
         (version_field, `Int current_version);
         (scope_field, `String (Tracker_scope.text owner.scope));
         (issue_id_field, `String (Issue_id.text owner.issue_id));
         (identifier_field, `String (Issue_identifier.text owner.identifier));
         (device_field, `String (hex owner.device));
         (inode_field, `String (hex owner.inode));
       ])

let size_error =
  Printf.sprintf "workspace owner exceeds the %d-byte record limit" max_bytes

let make ~scope ~issue_id ~identifier ~device ~inode =
  let ( let* ) = Result.bind in
  let* _ =
    Result.map_error
      (fun message -> "workspace owner identifier: " ^ message)
      (Workspace_key.of_identifier identifier)
  in
  let owner = { scope; issue_id; identifier; device; inode } in
  let oversized text = String.length text > max_bytes in
  (* Reject large checked inputs before allocating their escaped JSON encoding. *)
  if
    oversized (Tracker_scope.text scope)
    || oversized (Issue_id.text issue_id)
    || String.length (encode owner) > max_bytes
  then Error size_error
  else Ok owner

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("workspace owner missing field " ^ name)

let string_field fields name =
  let ( let* ) = Result.bind in
  let* value = field fields name in
  match Json.view value with
  | Json.String text -> Ok text
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Error ("workspace owner field " ^ name ^ " must be a string")

let checked_field fields name parse =
  let ( let* ) = Result.bind in
  let* text = string_field fields name in
  Result.map_error
    (fun message -> "workspace owner field " ^ name ^ ": " ^ message)
    (parse text)

let hex_digit = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + decimal_digits)
  | _ -> None

let hex_error =
  Printf.sprintf "must be exactly %d lowercase hexadecimal digits" hex_width

let parse_hex text =
  if String.length text <> hex_width then Error hex_error
  else
    (* Shift the exact bits; signed decimal conversion would lose high-bit IDs. *)
    let digit total c =
      let ( let* ) = Result.bind in
      let* bits = total in
      match hex_digit c with
      | None -> Error hex_error
      | Some n ->
          Ok (Int64.logor (Int64.shift_left bits hex_shift) (Int64.of_int n))
    in
    Seq.fold_left digit (Ok Int64.zero) (String.to_seq text)

let check_version fields =
  let ( let* ) = Result.bind in
  let* value = field fields version_field in
  match Json.view value with
  | Json.Number version
    when String.equal version (string_of_int current_version) -> Ok ()
  | Json.Number _
  | Json.Null
  | Json.Bool _
  | Json.String _
  | Json.Array _
  | Json.Object _ -> Error "workspace owner version must be the number 1"

let parse_fields fields =
  let ( let* ) = Result.bind in
  let names = List.sort String.compare (List.map fst fields) in
  let expected = List.sort String.compare field_names in
  let* () =
    if List.equal String.equal names expected then Ok ()
    else
      Error
        "workspace owner requires exactly version, scope, issue_id, \
         identifier, device, inode"
  in
  let* () = check_version fields in
  let* scope = checked_field fields scope_field Tracker_scope.parse in
  let* issue_id = checked_field fields issue_id_field Issue_id.parse in
  let* identifier =
    checked_field fields identifier_field Issue_identifier.parse
  in
  let* device = checked_field fields device_field parse_hex in
  let* inode = checked_field fields inode_field parse_hex in
  make ~scope ~issue_id ~identifier ~device ~inode

let parse text =
  if String.length text > max_bytes then Error size_error
  else
    let ( let* ) = Result.bind in
    let* value =
      Result.map_error
        (fun message -> "workspace owner JSON: " ^ message)
        (Json.parse text)
    in
    match Json.view value with
    | Json.Object fields -> parse_fields fields
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Error "workspace owner must be a JSON object"
