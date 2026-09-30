let ( let* ) = Result.bind

let field node name =
  match Json.view node with
  | Json.Object xs -> List.assoc_opt name xs
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      None

let array node =
  match Json.view node with
  | Json.Array xs -> xs
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      []

let same a b = Json.encode a = Json.encode b

let validate ~definition value =
  let* schema = Json.parse Policy_schema.source in
  let* definitions =
    match field schema "definitions" with
    | Some d -> Ok d
    | None -> Error "missing pinned schema definitions"
  in
  let rec check depth node value =
    if depth > 32 then Error "policy schema depth limit exceeded"
    else
      let* props =
        match Json.view node with
        | Json.Object xs -> Ok xs
        | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          -> Error "invalid pinned policy schema"
      in
      let known =
        [
          "$ref";
          "description";
          "title";
          "type";
          "enum";
          "oneOf";
          "anyOf";
          "allOf";
          "properties";
          "required";
          "additionalProperties";
          "items";
          "default";
        ]
      in
      if List.exists (fun (k, _) -> not (List.mem k known)) props then
        Error "unsupported pinned schema keyword"
      else
        let rec constraints = function
          | [] -> Ok ()
          | (key, v) :: rest ->
              let* () =
                match (key, Json.view v) with
                | "$ref", Json.String ref -> (
                    let prefix = "#/definitions/" in
                    if not (String.starts_with ~prefix ref) then
                      Error "unsupported schema reference"
                    else
                      let name =
                        String.sub ref (String.length prefix)
                          (String.length ref - String.length prefix)
                      in
                      match field definitions name with
                      | None -> Error "missing pinned definition"
                      | Some schema -> (
                          let* () = check (depth + 1) schema value in
                          if name <> "AbsolutePathBuf" then Ok ()
                          else
                            match Json.view value with
                            | Json.String s ->
                                Result.map (fun _ -> ()) (Absolute_path.parse s)
                            | Json.Null
                            | Json.Bool _
                            | Json.Number _
                            | Json.Array _
                            | Json.Object _ -> Error "expected an absolute path"
                          ))
                | "enum", Json.Array xs ->
                    if List.exists (same value) xs then Ok ()
                    else Error "value is outside generated policy enum"
                | "type", Json.String kind ->
                    let valid =
                      match (kind, Json.view value) with
                      | "string", Json.String _
                      | "boolean", Json.Bool _
                      | "object", Json.Object _
                      | "array", Json.Array _
                      | "null", Json.Null -> true
                      | ( _,
                          ( Json.Null
                          | Json.Bool _
                          | Json.Number _
                          | Json.String _
                          | Json.Array _
                          | Json.Object _ ) ) -> false
                    in
                    if valid then Ok () else Error ("expected policy " ^ kind)
                | ("oneOf" | "anyOf"), Json.Array alternatives ->
                    let passing =
                      List.filter
                        (fun schema ->
                          Result.is_ok (check (depth + 1) schema value))
                        alternatives
                    in
                    if
                      (key = "oneOf" && List.length passing = 1)
                      || (key = "anyOf" && passing <> [])
                    then Ok ()
                    else Error "policy does not match generated schema"
                | "allOf", Json.Array alternatives ->
                    Result.map
                      (fun _ -> ())
                      (Fields.sequence
                         (List.map
                            (fun s -> check (depth + 1) s value)
                            alternatives))
                | "required", Json.Array names ->
                    if
                      List.for_all
                        (fun n ->
                          match Json.view n with
                          | Json.String name ->
                              Option.is_some (field value name)
                          | Json.Null
                          | Json.Bool _
                          | Json.Number _
                          | Json.Array _
                          | Json.Object _ -> false)
                        names
                    then Ok ()
                    else Error "required policy property is missing"
                | "properties", Json.Object schemas ->
                    let tests =
                      List.filter_map
                        (fun (name, s) ->
                          Option.map (check (depth + 1) s) (field value name))
                        schemas
                    in
                    Result.map (fun _ -> ()) (Fields.sequence tests)
                | "items", _ ->
                    Result.map
                      (fun _ -> ())
                      (Fields.sequence
                         (List.map (check (depth + 1) v) (array value)))
                | "additionalProperties", Json.Bool false ->
                    let declared =
                      match List.assoc_opt "properties" props with
                      | Some p -> (
                          match Json.view p with
                          | Json.Object xs -> List.map fst xs
                          | Json.Null
                          | Json.Bool _
                          | Json.Number _
                          | Json.String _
                          | Json.Array _ -> [])
                      | None -> []
                    in
                    let keys =
                      match Json.view value with
                      | Json.Object xs -> List.map fst xs
                      | Json.Null
                      | Json.Bool _
                      | Json.Number _
                      | Json.String _
                      | Json.Array _ -> []
                    in
                    if List.for_all (fun k -> List.mem k declared) keys then
                      Ok ()
                    else Error "unknown policy property"
                | ("description" | "title" | "default"), _ -> Ok ()
                | ( _,
                    ( Json.Null
                    | Json.Bool _
                    | Json.Number _
                    | Json.String _
                    | Json.Array _
                    | Json.Object _ ) ) ->
                    Error "unsupported pinned policy schema constraint"
              in
              constraints rest
        in
        constraints props
  in
  match field definitions definition with
  | None -> Error "unknown policy definition"
  | Some s -> check 0 s value
