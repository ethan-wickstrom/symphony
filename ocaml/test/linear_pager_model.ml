type selection = States of string list | Ids of string list
type operation = Issues | Labels | Relations

type request =
  | Issues_page of { selection : selection; after : string option }
  | Labels_page of { id : string; after : string option }
  | Relations_page of { id : string; after : string option }

let page_size = 50
let key text = String.lowercase_ascii (String.trim text)
let states names = List.sort_uniq String.compare (List.map key names)
let ids names = List.sort_uniq String.compare names

let checked = function
  | Ok json -> json
  | Error message -> invalid_arg ("pager fixture model: " ^ message)

let node view = checked (Json.of_view view)
let str value = node (Json.String value)
let obj fields = node (Json.Object fields)
let array values = node (Json.Array values)

let operation = function
  | Issues_page _ -> Issues
  | Labels_page _ -> Labels
  | Relations_page _ -> Relations

let variables ~project request =
  let after, fields =
    match request with
    | Issues_page { selection; after } ->
        let filter =
          let project =
            ("project", obj [ ("slugId", obj [ ("eq", str project) ]) ])
          in
          match selection with
          | States names ->
              let alternatives =
                List.map
                  (fun state ->
                    obj
                      [
                        ( "state",
                          obj [ ("name", obj [ ("eqIgnoreCase", str state) ]) ]
                        );
                      ])
                  (states names)
              in
              obj [ project; ("or", array alternatives) ]
          | Ids names ->
              obj
                [
                  project;
                  ("id", obj [ ("in", array (List.map str (ids names))) ]);
                ]
        in
        (after, [ ("filter", filter) ])
    | Labels_page { id; after } | Relations_page { id; after } ->
        (after, [ ("id", str id) ])
  in
  let after =
    match after with
    | None -> node Json.Null
    | Some value -> str value
  in
  obj
    (("after", after)
    :: ("pageSize", node (Json.Number (string_of_int page_size)))
    :: fields)

type entry = {
  id : string;
  identifier : string;
  state : string;
  project : string;
}

type node = Valid of entry | Malformed
type failure = Duplicate_id | Duplicate_identifier | Scope | Filter | Required
type collected = { entries : entry list; omitted : int }

let collect ~project selection nodes =
  let permitted entry =
    match selection with
    | States names -> List.exists (fun name -> key name = key entry.state) names
    | Ids names -> List.exists (String.equal entry.id) names
  in
  let rec loop reverse omitted = function
    | [] ->
        let entries = List.rev reverse in
        let rec unique seen = function
          | [] -> Ok { entries; omitted }
          | entry :: rest ->
              if List.exists (fun prev -> prev.id = entry.id) seen then
                Error Duplicate_id
              else if
                List.exists
                  (fun prev -> prev.identifier = entry.identifier)
                  seen
              then Error Duplicate_identifier
              else unique (entry :: seen) rest
        in
        unique [] entries
    | Malformed :: rest -> (
        match selection with
        | States _ -> loop reverse (omitted + 1) rest
        | Ids _ -> Error Required)
    | Valid entry :: rest ->
        if entry.project <> project then Error Scope
        else if not (permitted entry) then Error Filter
        else loop (entry :: reverse) omitted rest
  in
  loop [] 0 nodes

let partition lengths items =
  let rec take reverse count rest =
    if count <= 0 then (List.rev reverse, rest)
    else
      match rest with
      | [] -> (List.rev reverse, [])
      | item :: rest -> take (item :: reverse) (count - 1) rest
  in
  let rec loop pages lengths items =
    match (lengths, items) with
    | _, [] -> List.rev pages
    | [], _ :: _ -> List.rev (items :: pages)
    | length :: lengths, _ :: _ ->
        if length <= 0 then loop pages lengths items
        else
          let page, rest = take [] length items in
          loop (page :: pages) lengths rest
  in
  loop [] lengths items

let chunks = function
  | States names -> (
      match states names with
      | [] -> []
      | names -> [ States names ])
  | Ids names ->
      let names = ids names in
      let lengths = List.map (fun _ -> page_size) names in
      List.map (fun chunk -> Ids chunk) (partition lengths names)
