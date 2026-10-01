type selection = States of string list | Ids of Issue_id.Set.t
type budget = { calls : int; bytes : int; nodes : int; issues : int }
type metadata = Labels | Relations

let page_size = 50
let max_calls = 1000
let max_bytes = 16_777_216
let max_nodes = 200_000
let max_issues = 10_000
let initial = { calls = 0; bytes = 0; nodes = 0; issues = 0 }
let ( let* ) = Result.bind

let issue_query =
  {|query SymphonyIssues($filter: IssueFilter!, $after: String, $pageSize: Int!) {
  issues(filter: $filter, after: $after, first: $pageSize, orderBy: createdAt, includeArchived: false) {
    nodes {
      id identifier title description priority branchName url createdAt updatedAt
      state { name } assignee { id } project { id slugId }
      labels(first: $pageSize) { nodes { id name } pageInfo { hasNextPage endCursor } }
      inverseRelations(first: $pageSize) {
        nodes { id type issue { id identifier state { name } } relatedIssue { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}|}

let label_query =
  {|query SymphonyLabels($id: String!, $after: String, $pageSize: Int!) {
  issue(id: $id) {
    id project { slugId }
    labels(after: $after, first: $pageSize) {
      nodes { id name } pageInfo { hasNextPage endCursor }
    }
  }
}|}

let relation_query =
  {|query SymphonyRelations($id: String!, $after: String, $pageSize: Int!) {
  issue(id: $id) {
    id project { slugId }
    inverseRelations(after: $after, first: $pageSize) {
      nodes { id type issue { id identifier state { name } } relatedIssue { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
}|}

let error category message =
  Tracker_error.make category
    (Diagnostic.make ~site:(Diagnostic.Host "linear.read") ~message
       ~remedy:
         "Check the configured scope/filter and provider response; reduce an \
          oversized read")

let malformed message = Error (error Tracker_error.Tracker_response message)

let exceeded name =
  Error (error Tracker_error.Tracker_pagination ("Linear read exceeds " ^ name))

let make view =
  Result.map_error
    (fun _ ->
      error Tracker_error.Tracker_request "Linear request exceeds JSON bounds")
    (Json.of_view view)

let string text = make (Json.String text)

let object_ fields =
  let* fields =
    Fields.sequence
      (List.map
         (fun (name, value) -> Result.map (fun value -> (name, value)) value)
         fields)
  in
  make (Json.Object fields)

let array values =
  let* values = Fields.sequence values in
  make (Json.Array values)

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

let at name json = Option.bind (field name json) text
let project_of json = Option.bind (field "project" json) (at "slugId")

let request operation query variables =
  object_
    [
      ("operationName", string operation);
      ("query", string query);
      ("variables", variables);
    ]

let after = function
  | None -> make Json.Null
  | Some cursor -> string (Linear_page.cursor_text cursor)

let size = make (Json.Number (string_of_int page_size))

let filter project selection =
  let project = object_ [ ("slugId", object_ [ ("eq", string project) ]) ] in
  let selector =
    match selection with
    | States names ->
        let names =
          List.map Text.normalize names |> List.sort_uniq String.compare
        in
        ( "or",
          array
            (List.map
               (fun name ->
                 object_
                   [
                     ( "state",
                       object_
                         [ ("name", object_ [ ("eqIgnoreCase", string name) ]) ]
                     );
                   ])
               names) )
    | Ids ids ->
        ( "id",
          object_
            [
              ( "in",
                array
                  (List.map
                     (fun id -> string (Issue_id.text id))
                     (Issue_id.Set.elements ids)) );
            ] )
  in
  object_ [ ("project", project); selector ]

let read ~post ~project ~terminal ~omitted selection =
  let fetch budget body =
    if budget.calls = max_calls then exceeded "request limit"
    else
      let* body = body in
      let* response =
        Result.map_error
          (fun diagnostic ->
            Tracker_error.make Tracker_error.Tracker_request diagnostic)
          (post body)
      in
      let bytes = String.length response.Http_transport.body in
      if bytes > max_bytes - budget.bytes then exceeded "response byte limit"
      else
        let* data =
          Linear_response.parse ~status:response.Http_transport.status
            ~body:response.Http_transport.body
        in
        Ok
          ( data,
            {
              budget with
              calls = budget.calls + 1;
              bytes = budget.bytes + bytes;
            } )
  in
  let account_page budget page_ =
    let count = List.length (Linear_page.nodes page_) in
    if count > max_nodes - budget.nodes then exceeded "connection node limit"
    else if count > page_size then exceeded "page size"
    else Ok (page_, { budget with nodes = budget.nodes + count })
  in
  let page budget connection =
    let* page_ = Linear_page.parse connection in
    account_page budget page_
  in
  let member node =
    if project_of node = Some project then Ok ()
    else malformed "Linear returned an issue outside the configured project"
  in
  let metadata budget node id kind =
    let name, operation, query =
      match kind with
      | Labels -> ("labels", "SymphonyLabels", label_query)
      | Relations -> ("inverseRelations", "SymphonyRelations", relation_query)
    in
    let rec collect budget history reversed page_ =
      let reversed = List.rev_append (Linear_page.nodes page_) reversed in
      match Linear_page.next page_ with
      | None -> Ok (List.rev reversed, Linear_record.Complete, budget)
      | Some cursor -> (
          let* history = Linear_page.advance history cursor in
          let variables =
            object_
              [
                ("id", string (Issue_id.text id));
                ("after", after (Some cursor));
                ("pageSize", size);
              ]
          in
          let* data, budget =
            fetch budget (request operation query variables)
          in
          match field "issue" data with
          | None -> malformed "Linear metadata response lacks its issue"
          | Some refreshed -> (
              let* () = member refreshed in
              if at "id" refreshed <> Some (Issue_id.text id) then
                malformed "Linear metadata response changed issue identity"
              else
                match field name refreshed with
                | None ->
                    malformed "Linear metadata response lacks its connection"
                | Some connection ->
                    let* page_, budget = page budget connection in
                    collect budget history reversed page_))
    in
    match field name node with
    | None -> Ok ([], Linear_record.Incomplete, budget)
    | Some connection -> (
        match Linear_page.parse connection with
        | Error _ -> Ok ([], Linear_record.Incomplete, budget)
        | Ok first ->
            let* first, budget = account_page budget first in
            collect budget Linear_page.start [] first)
  in
  let normalize wanted budget node =
    let* () = member node in
    let id =
      Option.bind (at "id" node) (fun value ->
          Result.to_option (Issue_id.parse value))
    in
    let* labels, relations, completeness, budget =
      match id with
      | None -> Ok ([], [], Linear_record.Incomplete, budget)
      | Some id ->
          let* labels, _, budget = metadata budget node id Labels in
          let* relations, completeness, budget =
            metadata budget node id Relations
          in
          Ok (labels, relations, completeness, budget)
    in
    match
      Linear_record.parse ~terminal ~labels ~relations ~completeness node
    with
    | Error omission -> (
        match wanted with
        | States _ ->
            let _ = omitted omission in
            Ok (None, budget)
        | Ids _ ->
            Error
              (Tracker_error.make Tracker_error.Tracker_response
                 (Linear_omission.diagnostic omission)))
    | Ok issue ->
        let matches =
          match wanted with
          | States names ->
              List.exists
                (fun name -> Text.normalize name = Issue.state_key issue)
                names
          | Ids ids -> Issue_id.Set.mem (Issue.id issue) ids
        in
        if matches then Ok (Some issue, budget)
        else
          malformed
            "Linear returned an issue outside the requested state or ID set"
  in
  let rec normalize_all wanted budget reversed = function
    | [] -> Ok (reversed, budget)
    | node :: rest ->
        let* issue, budget = normalize wanted budget node in
        let reversed =
          Option.fold ~none:reversed
            ~some:(fun issue -> issue :: reversed)
            issue
        in
        normalize_all wanted budget reversed rest
  in
  let rec pages budget history reversed selection cursor =
    let variables =
      object_
        [
          ("filter", filter project selection);
          ("after", after cursor);
          ("pageSize", size);
        ]
    in
    let* data, budget =
      fetch budget (request "SymphonyIssues" issue_query variables)
    in
    match field "issues" data with
    | None -> malformed "Linear response lacks the issues connection"
    | Some connection -> (
        let* page_, budget = page budget connection in
        let count = List.length (Linear_page.nodes page_) in
        if count > max_issues - budget.issues then exceeded "issue limit"
        else
          let budget = { budget with issues = budget.issues + count } in
          let* reversed, budget =
            normalize_all selection budget reversed (Linear_page.nodes page_)
          in
          match Linear_page.next page_ with
          | None -> Ok (reversed, budget)
          | Some cursor ->
              let* history = Linear_page.advance history cursor in
              pages budget history reversed selection (Some cursor))
  in
  let rec split count reversed remaining =
    match (count, remaining) with
    | 0, _ | _, [] -> (List.rev reversed, remaining)
    | _, id :: rest -> split (count - 1) (id :: reversed) rest
  in
  let rec chunks budget reversed = function
    | [] -> Ok reversed
    | _ :: _ as ids ->
        let chunk, rest = split page_size [] ids in
        let subset = Issue_id.Set.of_list chunk in
        let* reversed, budget =
          pages budget Linear_page.start reversed (Ids subset) None
        in
        chunks budget reversed rest
  in
  let* reversed =
    match selection with
    | States [] -> Ok []
    | States (_ :: _) ->
        let* reversed, _ = pages initial Linear_page.start [] selection None in
        Ok reversed
    | Ids ids -> chunks initial [] (Issue_id.Set.elements ids)
  in
  Result.map_error
    (function
      | Issue_batch.Duplicate_id _ ->
          error Tracker_error.Tracker_pagination
            "Linear repeated an issue ID across pages or chunks"
      | Issue_batch.Duplicate_identifier _ ->
          error Tracker_error.Tracker_response
            "Linear returned conflicting issue identifiers")
    (Issue_batch.of_list (List.rev reversed))
