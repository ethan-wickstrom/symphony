type settings = {
  endpoint : string;
  project : string;
  secret : string;
  source : string option;
  scope : Tracker_scope.t;
}

let kind = "linear"

let equal a b =
  a.endpoint = b.endpoint && a.project = b.project && a.secret = b.secret
  && a.source = b.source
  && Tracker_scope.equal a.scope b.scope

let secret_names s = "LINEAR_API_KEY" :: Option.to_list s.source
let scope s = s.scope
let default_endpoint = "https://api.linear.app/graphql"
let secure_prefix = "https://"
let max_port = 65535

let unreserved = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let subdelimiter = function
  | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' -> true
  | _ -> false

let component allowed source =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  let rec loop i =
    if i = String.length source then true
    else if source.[i] = '%' then
      i + 2 < String.length source
      && hex source.[i + 1]
      && hex source.[i + 2]
      && loop (i + 3)
    else allowed source.[i] && loop (i + 1)
  in
  loop 0

let port source =
  source <> ""
  && String.for_all (fun c -> c >= '0' && c <= '9') source
  && Option.fold ~none:false
       ~some:(fun n -> n > 0 && n <= max_port)
       (int_of_string_opt source)

let authority source =
  if String.starts_with ~prefix:"[" source then
    match String.index_opt source ']' with
    | None -> false
    | Some close ->
        let host = String.sub source 1 (close - 1) in
        let suffix =
          String.sub source (close + 1) (String.length source - close - 1)
        in
        Result.is_ok
          (Angstrom.parse_string ~consume:Angstrom.Consume.All Uri.Parser.ipv6
             host)
        && (suffix = ""
           || String.starts_with ~prefix:":" suffix
              && port (String.sub suffix 1 (String.length suffix - 1)))
  else
    let host source =
      source <> "" && component (fun c -> unreserved c || subdelimiter c) source
    in
    match String.split_on_char ':' source with
    | [ name ] -> host name
    | [ name; number ] -> host name && port number
    | [] | _ :: _ -> false

let raw_endpoint endpoint =
  let start = String.length secure_prefix in
  if
    String.length endpoint < start
    || String.lowercase_ascii (String.sub endpoint 0 start) <> secure_prefix
  then false
  else
    let rec end_authority i =
      if i = String.length endpoint then i
      else
        match endpoint.[i] with
        | '/' | '?' | '#' -> i
        | _ -> end_authority (i + 1)
    in
    let finish = end_authority start in
    let resource =
      String.sub endpoint finish (String.length endpoint - finish)
    in
    let path, query =
      match String.index_opt resource '?' with
      | None -> (resource, "")
      | Some i ->
          ( String.sub resource 0 i,
            String.sub resource (i + 1) (String.length resource - i - 1) )
    in
    let pchar c = unreserved c || subdelimiter c || c = ':' || c = '@' in
    authority (String.sub endpoint start (finish - start))
    && component (fun c -> pchar c || c = '/') path
    && component (fun c -> pchar c || c = '/' || c = '?') query

let valid_endpoint endpoint =
  (* Uri repairs malformed input; RFC3986 raw syntax must pass before parsing. *)
  raw_endpoint endpoint
  &&
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.All Uri.Parser.uri_reference
      endpoint
  with
  | Error _ -> false
  | Ok uri ->
      let host =
        match Uri.host uri with
        | None -> false
        | Some h ->
            h <> ""
            && not
                 (String.exists
                    (fun c ->
                      Char.code c <= 32 || c = '%' || c = '/' || c = '\\')
                    h)
      in
      Uri.scheme uri = Some "https"
      && host
      && Uri.userinfo uri = None
      && Uri.fragment uri = None

let error category key message =
  Tracker_error.make category
    (Fields.diagnostic
       ~key:(if key = "" then "tracker.provider" else "tracker.provider." ^ key)
       message)

let parse ~env ~active:_ ~terminal:_ config =
  let ( let* ) = Result.bind in
  let field key default =
    match Config_value.field config key with
    | None -> Ok default
    | Some v ->
        Result.map_error
          (error Tracker_error.Invalid_tracker_config key)
          (Fields.text env v)
  in
  let* _ =
    Result.map_error
      (error Tracker_error.Invalid_tracker_config "")
      (Fields.mapping config)
  in
  let* endpoint = field "endpoint" default_endpoint in
  let* project = field "project_slug" "" in
  let* secret, source =
    match Config_value.field config "api_key" with
    | None -> (
        match Environment.lookup env "LINEAR_API_KEY" with
        | None -> Ok ("", Some "LINEAR_API_KEY")
        | Some s -> Ok (s, Some "LINEAR_API_KEY"))
    | Some v ->
        let source =
          match Config_value.view v with
          | Config_value.String s -> Fields.reference s
          | Config_value.Null
          | Config_value.Bool _
          | Config_value.Number _
          | Config_value.Sequence _
          | Config_value.Mapping _ -> None
        in
        let* value =
          Result.map_error
            (error Tracker_error.Missing_tracker_secret "api_key")
            (Fields.text env v)
        in
        Ok (value, source)
  in
  if String.trim project = "" then
    Error
      (error Tracker_error.Invalid_tracker_config "project_slug"
         "project slug must be nonempty")
  else if String.trim secret = "" || String.contains secret '\000' then
    Error
      (error Tracker_error.Missing_tracker_secret "api_key"
         "Linear API credential is missing or invalid")
  else if not (valid_endpoint endpoint) then
    Error
      (error Tracker_error.Invalid_tracker_config "endpoint"
         "Linear endpoint must be an absolute HTTPS URI with a host and no \
          userinfo or fragment")
  else
    let scope_text =
      Printf.sprintf "%d:%s%s" (String.length endpoint) endpoint project
    in
    let* scope =
      Result.map_error
        (error Tracker_error.Invalid_tracker_config "project_slug")
        (Tracker_scope.parse scope_text)
    in
    Ok { endpoint; project; secret; source; scope }
