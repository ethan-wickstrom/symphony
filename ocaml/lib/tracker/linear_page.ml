type cursor = string
type t = { nodes : Json.t list; next : cursor option }

module Cursor_order = String
module Cursor_set = Set.Make (Cursor_order)

type history = Cursor_set.t

let cursor_bytes = 4096

let error message =
  Error
    (Tracker_error.make Tracker_error.Tracker_pagination
       (Diagnostic.make ~site:(Diagnostic.Host "linear.page") ~message
          ~remedy:
            "Check the provider's nodes/pageInfo response and cursor progress"))

let field name json =
  match Json.view json with
  | Json.Object fields -> List.assoc_opt name fields
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      None

let parse json =
  match (field "nodes" json, field "pageInfo" json) with
  | Some nodes, Some info -> (
      match (Json.view nodes, field "hasNextPage" info) with
      | Json.Array nodes, Some continuing -> (
          match Json.view continuing with
          | Json.Bool false -> Ok { nodes; next = None }
          | Json.Bool true -> (
              match (nodes, field "endCursor" info) with
              | _ :: _, Some cursor -> (
                  match Json.view cursor with
                  | Json.String text
                    when String.trim text <> ""
                         && String.length text <= cursor_bytes
                         && not (String.contains text '\000') ->
                      Ok { nodes; next = Some text }
                  | Json.Null
                  | Json.Bool _
                  | Json.Number _
                  | Json.String _
                  | Json.Array _
                  | Json.Object _ ->
                      error "continuing page has an invalid endCursor")
              | [], _ | _ :: _, None ->
                  error "continuing page lacks nodes or endCursor")
          | Json.Null
          | Json.Number _
          | Json.String _
          | Json.Array _
          | Json.Object _ -> error "pageInfo.hasNextPage must be boolean")
      | ( ( Json.Null
          | Json.Bool _
          | Json.Number _
          | Json.String _
          | Json.Object _ ),
          _ )
      | Json.Array _, None ->
          error "page requires nodes array and pageInfo.hasNextPage")
  | None, _ | _, None -> error "page requires nodes and pageInfo"

let nodes page = page.nodes
let next page = page.next
let cursor_text cursor = cursor
let cursor_equal = String.equal
let start = Cursor_set.empty

let advance history cursor =
  if Cursor_set.mem cursor history then
    error "provider repeated a pagination cursor"
  else Ok (Cursor_set.add cursor history)
