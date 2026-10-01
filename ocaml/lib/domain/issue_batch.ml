type t = Issue.t list

type error =
  | Duplicate_id of Issue_id.t
  | Duplicate_identifier of Issue_identifier.t

let empty = []

let of_list issues =
  let rec check ids identifiers = function
    | [] -> Ok issues
    | issue :: rest ->
        let id = Issue.id issue in
        let identifier = Issue.identifier issue in
        if Issue_id.Set.mem id ids then Error (Duplicate_id id)
        else if Issue_identifier.Set.mem identifier identifiers then
          Error (Duplicate_identifier identifier)
        else
          check (Issue_id.Set.add id ids)
            (Issue_identifier.Set.add identifier identifiers)
            rest
  in
  check Issue_id.Set.empty Issue_identifier.Set.empty issues

let ordered issues = issues

let by_id issues =
  List.fold_left
    (fun map issue -> Issue_id.Map.add (Issue.id issue) issue map)
    Issue_id.Map.empty issues
