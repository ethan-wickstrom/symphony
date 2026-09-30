type ('config, 'error) reload = {
  last_good : 'config;
  latest_error : 'error option;
}

let initial last_good = { last_good; latest_error = None }

let apply previous = function
  | Ok last_good -> { last_good; latest_error = None }
  | Error error -> { previous with latest_error = Some error }

let effective reload = reload.last_good
let latest_error reload = reload.latest_error
let name text = String.lowercase_ascii (String.trim text)

let limits entries =
  List.fold_left
    (fun model (key, value) ->
      match (model, value) with
      | Error (), _ -> Error ()
      | Ok previous, Some limit when limit > 0 ->
          let key = name key in
          if List.mem_assoc key previous then Error ()
          else Ok ((key, limit) :: previous)
      | Ok previous, (None | Some _) -> Ok previous)
    (Ok []) entries

let state_limit ~global entries key =
  Option.value ~default:global (List.assoc_opt (name key) entries)
