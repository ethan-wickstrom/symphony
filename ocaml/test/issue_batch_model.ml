type error =
  | Duplicate_id of Issue_id.t
  | Duplicate_identifier of Issue_identifier.t

let of_list issues =
  let rec check prefix = function
    | [] -> Ok issues
    | issue :: rest ->
        let id = Issue.id issue in
        let identifier = Issue.identifier issue in
        if List.exists (fun old -> Issue_id.equal (Issue.id old) id) prefix then
          Error (Duplicate_id id)
        else if
          List.exists
            (fun old ->
              Issue_identifier.equal (Issue.identifier old) identifier)
            prefix
        then Error (Duplicate_identifier identifier)
        else check (issue :: prefix) rest
  in
  check [] issues

let find id issues =
  List.find_opt (fun issue -> Issue_id.equal id (Issue.id issue)) issues
