type field = Id | Identifier | Title | State

type reason =
  | Missing_field of field
  | Wrong_type of field
  | Invalid_record
  | Record_rejected

type label = Exact of string | Digest of string

type identity =
  | Unknown
  | By_id of label
  | By_identifier of label
  | Identified of label * label

type t = { reason : reason; identity : identity }

module Hash = Digestif.SHA256

let max_identity_bytes = 128

let label parse text key fields =
  match List.assoc_opt key fields with
  | None -> None
  | Some value -> (
      match Json.view value with
      | Json.String value -> (
          match parse value with
          | Error _ -> None
          | Ok value ->
              let bytes = text value in
              if String.length bytes <= max_identity_bytes then
                Some (Exact bytes)
              else Some (Digest (Hash.to_hex (Hash.digest_string bytes))))
      | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _
        -> None)

let make reason json =
  let identity =
    match Json.view json with
    | Json.Object fields -> (
        let id = label Issue_id.parse Issue_id.text "id" fields in
        let identifier =
          label Issue_identifier.parse Issue_identifier.text "identifier" fields
        in
        match (id, identifier) with
        | None, None -> Unknown
        | Some id, None -> By_id id
        | None, Some identifier -> By_identifier identifier
        | Some id, Some identifier -> Identified (id, identifier))
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Unknown
  in
  { reason; identity }

let identity warning = warning.identity
let reason warning = warning.reason

let label_text = function
  | Exact bytes -> Printf.sprintf "%S" bytes
  | Digest hex -> "sha256:" ^ hex

let identity_text = function
  | Unknown -> "unknown"
  | By_id id -> "issue_id=" ^ label_text id
  | By_identifier identifier -> "issue_identifier=" ^ label_text identifier
  | Identified (id, identifier) ->
      "issue_id=" ^ label_text id ^ " issue_identifier=" ^ label_text identifier

let field_text = function
  | Id -> "id"
  | Identifier -> "identifier"
  | Title -> "title"
  | State -> "state"

let diagnostic warning =
  let message, remedy =
    match warning.reason with
    | Missing_field field ->
        let key = field_text field in
        ( "Linear issue omitted: missing " ^ key,
          "Supply a nonempty string for " ^ key ^ " in the issue record" )
    | Wrong_type field ->
        let key = field_text field in
        ( "Linear issue omitted: " ^ key ^ " must be a string",
          "Supply a nonempty string for " ^ key ^ " in the issue record" )
    | Invalid_record ->
        ( "Linear issue omitted: expected an issue object",
          "Return an object containing id, identifier, title and state" )
    | Record_rejected ->
        ( "Linear issue omitted: required fields failed normalization",
          "Correct id, identifier, title and state in the issue record" )
  in
  Diagnostic.make
    ~site:(Diagnostic.Host ("tracker=linear " ^ identity_text warning.identity))
    ~message ~remedy
