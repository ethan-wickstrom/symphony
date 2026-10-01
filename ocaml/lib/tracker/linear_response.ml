let success_min = 200
let success_limit = 300
let rate_status = 429
let graphql_error_status = 400
let rate_code = "RATELIMITED"

let error category message =
  Error
    (Tracker_error.make category
       (Diagnostic.make ~site:(Diagnostic.Host "linear.response") ~message
          ~remedy:
            "Check the configured endpoint, credential, scope and provider \
             availability"))

let field name json =
  match Json.view json with
  | Json.Object fields -> List.assoc_opt name fields
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      None

let rate_limited json =
  match Option.bind (field "extensions" json) (field "code") with
  | Some code -> (
      match Json.view code with
      | Json.String value -> String.equal value rate_code
      | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _
        -> false)
  | None -> false

let parse ~status ~body =
  if status = rate_status then
    error Tracker_error.Tracker_rate_limited "Linear rate limit reached"
  else
    let envelope = Json.parse body in
    let errors = Option.bind (Result.to_option envelope) (field "errors") in
    let rate =
      match Option.map Json.view errors with
      | Some (Json.Array entries) -> List.exists rate_limited entries
      | None
      | Some
          ( Json.Null
          | Json.Bool _
          | Json.Number _
          | Json.String _
          | Json.Object _ ) -> false
    in
    let may_report_rate =
      (status >= success_min && status < success_limit)
      || status = graphql_error_status
    in
    if rate && may_report_rate then
      error Tracker_error.Tracker_rate_limited "Linear rate limit reached"
    else if status < success_min || status >= success_limit then
      error Tracker_error.Tracker_status
        (Printf.sprintf "Linear returned HTTP %d" status)
    else
      match envelope with
      | Error _ ->
          error Tracker_error.Tracker_response "Linear returned invalid JSON"
      | Ok json -> (
          let no_errors =
            match Option.map Json.view errors with
            | None | Some Json.Null | Some (Json.Array []) -> true
            | Some (Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _)
            | Some (Json.Array (_ :: _)) -> false
          in
          if not no_errors then
            error Tracker_error.Tracker_response
              "Linear returned GraphQL errors"
          else
            match field "data" json with
            | Some data -> (
                match Json.view data with
                | Json.Object _ -> Ok data
                | Json.Null
                | Json.Bool _
                | Json.Number _
                | Json.String _
                | Json.Array _ ->
                    error Tracker_error.Tracker_response
                      "Linear data must be an object")
            | None ->
                error Tracker_error.Tracker_response
                  "Linear response lacks data")
