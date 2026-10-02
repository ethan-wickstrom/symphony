module Make
    (Clock : Clock.PURE)
    (Owner : Ownership.OWNER with type instant = Clock.instant) =
struct
  type t = Owner.t list

  let id owner = Issue.id (Owner.issue owner)
  let empty = []

  let remove key owners =
    List.filter (fun owner -> not (Issue_id.equal key (id owner))) owners

  let put owner owners = owner :: remove (id owner) owners

  let find key owners =
    List.find_opt (fun owner -> Issue_id.equal key (id owner)) owners

  let bindings owners =
    List.sort
      (fun (a, _) (b, _) -> Issue_id.compare a b)
      (List.map (fun owner -> (id owner, owner)) owners)

  let select keep owners =
    List.fold_left
      (fun ids owner ->
        if keep (Owner.role owner) then Issue_id.Set.add (id owner) ids else ids)
      Issue_id.Set.empty owners

  let running_ids =
    select (function
      | Owner.Worker | Owner.Cleanup -> true
      | Owner.Retry_waiting _ | Owner.Retry_refreshing _ -> false)

  let retry_ids =
    select (function
      | Owner.Retry_waiting _ | Owner.Retry_refreshing _ -> true
      | Owner.Worker | Owner.Cleanup -> false)

  let claimed owners =
    List.fold_left
      (fun ids owner -> Issue_id.Set.add (id owner) ids)
      Issue_id.Set.empty owners

  let next_retry owners =
    let waiting =
      List.filter_map
        (fun owner ->
          match Owner.role owner with
          | Owner.Retry_waiting (token, due) -> Some (id owner, token, due)
          | Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _ -> None)
        owners
    in
    let order (a, _, due_a) (b, _, due_b) =
      match Clock.compare due_a due_b with
      | 0 -> Issue_id.compare a b
      | sign -> sign
    in
    match List.sort order waiting with
    | [] -> None
    | first :: _ -> Some first
end
