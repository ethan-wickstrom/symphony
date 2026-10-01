type completeness = Complete | Incomplete

let ( let* ) = Result.bind

let field name json =
  match Json.view json with
  | Json.Object fields -> List.assoc_opt name fields
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      None

let text json =
  match Json.view json with
  | Json.String value -> Some value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      None

let optional name json = Option.bind (field name json) text

let usable value =
  String.trim value <> ""
  && (not (String.contains value '\000'))
  && Text.valid_utf8 value

let nested name child json = Option.bind (field name json) (optional child)

let parse ~terminal ~labels ~relations ~completeness node =
  let omitted reason = Error (Linear_omission.make reason node) in
  let required name key json =
    match field key json with
    | None -> omitted (Linear_omission.Missing_field name)
    | Some json -> (
        match text json with
        | Some value -> Ok value
        | None -> omitted (Linear_omission.Wrong_type name))
  in
  let* id = required Linear_omission.Id "id" node in
  let* identifier = required Linear_omission.Identifier "identifier" node in
  let* title = required Linear_omission.Title "title" node in
  let* state =
    match field "state" node with
    | None -> omitted (Linear_omission.Missing_field Linear_omission.State)
    | Some state -> required Linear_omission.State "name" state
  in
  let terminal = List.map Text.normalize terminal in
  let blocker relation =
    match optional "type" relation with
    | Some "blocks" ->
        let source = field "issue" relation in
        let target = nested "relatedIssue" "id" relation in
        let source_id =
          Option.bind
            (Option.bind source (optional "id"))
            (fun value -> Result.to_option (Issue_id.parse value))
        in
        let source_identifier =
          Option.bind
            (Option.bind source (optional "identifier"))
            (fun value -> Result.to_option (Issue_identifier.parse value))
        in
        let source_state =
          Option.bind
            (Option.bind source (nested "state" "name"))
            (fun value -> if usable value then Some value else None)
        in
        let terminal_source =
          match (source_id, source_state) with
          | Some source_id, Some state ->
              Issue_id.text source_id <> id
              && List.mem (Text.normalize state) terminal
          | None, _ | _, None -> false
        in
        let target_matches = target = Some id in
        let metadata =
          if
            (not target_matches)
            || (source_id = None && source_identifier = None)
          then None
          else
            Some
              ({
                 Issue.id = source_id;
                 identifier = source_identifier;
                 state = source_state;
               }
                : Issue.blocker)
        in
        (target_matches && terminal_source, metadata)
    | Some kind when usable kind -> (true, None)
    | Some _ | None -> (false, None)
  in
  let evidence, blocked_by =
    List.fold_left
      (fun (evidence, reversed) relation ->
        let eligible, metadata = blocker relation in
        ( evidence && eligible,
          Option.fold ~none:reversed ~some:(fun b -> b :: reversed) metadata ))
      (completeness = Complete, [])
      relations
  in
  let routing =
    if Text.normalize state <> "todo" || evidence then Issue.Dispatchable
    else Issue.Unroutable
  in
  let labels = List.filter_map (optional "name") labels in
  let priority =
    Option.bind (field "priority" node) Json.to_int |> Option.map string_of_int
  in
  let native_ref =
    let identities =
      [
        ("issue_id", Some id);
        ("project_id", nested "project" "id" node);
        ("project_slug", nested "project" "slugId" node);
      ]
      |> List.filter_map (fun (key, value) ->
          Option.bind value (fun value ->
              if not (usable value) then None
              else
                Option.map
                  (fun json -> (key, json))
                  (Result.to_option (Json.of_view (Json.String value)))))
    in
    Result.to_option (Json.of_view (Json.Object identities))
  in
  let input : Issue.input =
    {
      Issue.id;
      identifier;
      title;
      description = optional "description" node;
      priority;
      state;
      branch_name = optional "branchName" node;
      url = optional "url" node;
      assignee_id = nested "assignee" "id" node;
      labels;
      blocked_by = List.rev blocked_by;
      created_at = optional "createdAt" node;
      updated_at = optional "updatedAt" node;
      dispatchable = routing;
      native_ref;
    }
  in
  match Issue.parse input with
  | Ok issue -> Ok issue
  | Error _ -> omitted Linear_omission.Record_rejected
