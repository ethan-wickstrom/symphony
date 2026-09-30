let ( let* ) = Result.bind

let parse text =
  let* j = Json.parse text in
  let* fields =
    match Json.view j with
    | Json.Object xs -> Ok xs
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Error "issue fixture must be a JSON object"
  in
  let required k =
    match List.assoc_opt k fields with
    | Some j -> (
        match Json.view j with
        | Json.String s -> Ok s
        | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _
          -> Error (k ^ " must be a string"))
    | None -> Error ("missing issue field " ^ k)
  in
  let optional k =
    Option.bind (List.assoc_opt k fields) (fun j ->
        match Json.view j with
        | Json.String s -> Some s
        | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _
          -> None)
  in
  let* id = required "id" in
  let* identifier = required "identifier" in
  let* title = required "title" in
  let* state = required "state" in
  let priority =
    Option.bind (List.assoc_opt "priority" fields) (fun j ->
        match Json.view j with
        | Json.Number s -> Some s
        | Json.Null | Json.Bool _ | Json.String _ | Json.Array _ | Json.Object _
          -> None)
  in
  let labels =
    match List.assoc_opt "labels" fields with
    | Some j -> (
        match Json.view j with
        | Json.Array xs ->
            List.filter_map
              (fun j ->
                match Json.view j with
                | Json.String s -> Some s
                | Json.Null
                | Json.Bool _
                | Json.Number _
                | Json.Array _
                | Json.Object _ -> None)
              xs
        | Json.Null
        | Json.Bool _
        | Json.Number _
        | Json.String _
        | Json.Object _ -> [])
    | None -> []
  in
  let* dispatchable =
    match List.assoc_opt "dispatchable" fields with
    | Some j -> (
        match Json.view j with
        | Json.Bool true -> Ok Issue.Dispatchable
        | Json.Bool false -> Ok Issue.Unroutable
        | Json.Null
        | Json.Number _
        | Json.String _
        | Json.Array _
        | Json.Object _ -> Error "dispatchable must be an explicit boolean")
    | None -> Error "missing issue field dispatchable; provide true or false"
  in
  let native_ref = List.assoc_opt "native_ref" fields in
  let blocker j =
    match Json.view j with
    | Json.Object xs ->
        let text k =
          Option.bind (List.assoc_opt k xs) (fun j ->
              match Json.view j with
              | Json.String s -> Some s
              | Json.Null
              | Json.Bool _
              | Json.Number _
              | Json.Array _
              | Json.Object _ -> None)
        in
        Some
          {
            Issue.id =
              Option.bind (text "id") (fun s ->
                  Result.to_option (Issue_id.parse s));
            identifier =
              Option.bind (text "identifier") (fun s ->
                  Result.to_option (Issue_identifier.parse s));
            state = text "state";
          }
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        None
  in
  let blocked_by =
    match List.assoc_opt "blocked_by" fields with
    | Some j -> (
        match Json.view j with
        | Json.Array xs -> List.filter_map blocker xs
        | Json.Null
        | Json.Bool _
        | Json.Number _
        | Json.String _
        | Json.Object _ -> [])
    | None -> []
  in
  Issue.parse
    {
      Issue.id;
      identifier;
      title;
      state;
      description = optional "description";
      priority;
      branch_name = optional "branch_name";
      url = optional "url";
      assignee_id = optional "assignee_id";
      labels;
      blocked_by;
      created_at = optional "created_at";
      updated_at = optional "updated_at";
      dispatchable;
      native_ref;
    }
