module Make (Http : Http_transport.S) (Clock : Clock.S) = struct
  module Hash = Digestif.SHA256
  module Limit = Deadline.Make (Clock)

  type settings = {
    credential : Http.credential;
    project : string;
    source : string option;
    scope : Tracker_scope.t;
    delay : Milliseconds.t;
  }

  let default_endpoint = "https://api.linear.app/graphql"
  let default_secret_name = "LINEAR_API_KEY"
  let read_timeout_ms = "30000"

  let error category key message =
    Tracker_error.make category
      (Fields.diagnostic
         ~key:
           (if key = "" then "tracker.provider" else "tracker.provider." ^ key)
         message)

  let seal_error category key diagnostic =
    error category key (Diagnostic.render diagnostic)

  module Config = struct
    type nonrec settings = settings

    let kind = "linear"

    let equal a b =
      Http.equal a.credential b.credential
      && a.project = b.project && a.source = b.source
      && Tracker_scope.equal a.scope b.scope
      && Milliseconds.compare a.delay b.delay = 0

    let secret_names settings =
      match settings.source with
      | Some source when source <> default_secret_name ->
          [ default_secret_name; source ]
      | Some _ | None -> [ default_secret_name ]

    let scope settings = settings.scope

    let parse ~env config =
      let ( let* ) = Result.bind in
      let* _ =
        Result.map_error
          (error Tracker_error.Invalid_tracker_config "")
          (Fields.mapping config)
      in
      let* token, source =
        match Config_value.field config "api_key" with
        | None ->
            Ok
              ( Option.value ~default:""
                  (Environment.lookup env default_secret_name),
                Some default_secret_name )
        | Some value ->
            let source =
              match Config_value.view value with
              | Config_value.String text -> Fields.reference text
              | Config_value.Null
              | Config_value.Bool _
              | Config_value.Number _
              | Config_value.Sequence _
              | Config_value.Mapping _ -> None
            in
            let* token =
              Result.map_error
                (error Tracker_error.Missing_tracker_secret "api_key")
                (Fields.credential_text env value)
            in
            Ok (token, source)
      in
      let deny =
        match source with
        | Some source when source <> default_secret_name ->
            [ default_secret_name; source ]
        | Some _ | None -> [ default_secret_name ]
      in
      let public =
        Environment.public env ~deny
          ~secrets:(Option.to_list (Environment.Secret.make token))
      in
      let field key default =
        let value =
          match Config_value.field config key with
          | None -> Environment.check public default
          | Some value -> Fields.text public value
        in
        Result.map_error (error Tracker_error.Invalid_tracker_config key) value
      in
      let* raw_endpoint = field "endpoint" default_endpoint in
      let* project = field "project_slug" "" in
      if
        String.trim project = ""
        || String.contains project '\000'
        || not (Text.valid_utf8 project)
      then
        Error
          (error Tracker_error.Invalid_tracker_config "project_slug"
             "Linear project slug must be nonempty UTF-8 without NUL")
      else
        let* endpoint =
          Result.map_error
            (seal_error Tracker_error.Invalid_tracker_config "endpoint")
            (Http.endpoint raw_endpoint)
        in
        let* credential =
          Result.map_error
            (seal_error Tracker_error.Missing_tracker_secret "api_key")
            (Http.credential endpoint ~scheme:Http.Authorization_value ~token)
        in
        (* A workspace owner may expose scope; retain only a routing fingerprint. *)
        let components =
          Printf.sprintf "%d:%s%d:%s"
            (String.length raw_endpoint)
            raw_endpoint (String.length project) project
        in
        let* scope =
          Result.map_error
            (error Tracker_error.Invalid_tracker_config "project_slug")
            (Tracker_scope.parse
               ("linear:" ^ Hash.to_hex (Hash.digest_string components)))
        in
        let* delay =
          Result.map_error
            (error Tracker_error.Invalid_tracker_config "")
            (Milliseconds.parse read_timeout_ms)
        in
        Ok ({ credential; project; source; scope; delay }, public)
  end

  include (Config : Tracker_adapter.CONFIG with type settings := settings)

  type io = {
    http : unit -> (Http.t, Diagnostic.t) result;
    clock : Clock.t;
    omitted : Linear_omission.t -> (unit, Diagnostic.t) result;
  }

  let io ~http ~clock ~omitted = { http; clock; omitted }

  let request_error diagnostic =
    Tracker_error.make Tracker_error.Tracker_request diagnostic

  let timeout () =
    request_error
      (Diagnostic.make
         ~site:(Diagnostic.Host "tracker=linear key=tracker.provider.endpoint")
         ~message:"Linear read exceeded its 30 s deadline"
         ~remedy:
           "Check tracker connectivity and reduce the paginated result size")

  let read io settings ~policy selection =
    match selection with
    | Linear_pager.States [] -> Ok Issue_batch.empty
    | Linear_pager.Ids ids when Issue_id.Set.is_empty ids ->
        Ok Issue_batch.empty
    | Linear_pager.States (_ :: _) | Linear_pager.Ids _ ->
        Limit.run io.clock ~delay:settings.delay ~on_error:request_error
          ~on_timeout:timeout (fun () ->
            let ( let* ) = Result.bind in
            let* http = Result.map_error request_error (io.http ()) in
            Linear_pager.read
              ~post:(fun body -> Http.post http settings.credential ~body)
              ~project:settings.project
              ~terminal:(Tracker_read_policy.terminal policy)
              ~omitted:io.omitted selection)

  let states io settings ~policy names =
    read io settings ~policy (Linear_pager.States names)

  let ids io settings ~policy ids =
    Result.map Issue_batch.by_id
      (read io settings ~policy (Linear_pager.Ids ids))
end
