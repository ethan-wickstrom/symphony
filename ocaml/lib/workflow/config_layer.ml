type error =
  | Workflow of Workflow_loader.error
  | Fields of Diagnostic.t Nonempty_list.t
  | Tracker of Tracker_error.t

module type PURE = sig
  type tracker
  type t
  type reload
  type readiness = Ready | Blocked of error

  val scheduling : t -> Scheduling_policy.t
  val agent : t -> Agent_settings.t
  val workspace : t -> Workspace_settings.t
  val tracker : t -> tracker
  val prompt_source : t -> string
  val file : t -> Workflow_path.t
  val child_env : t -> Environment.child
  val equal : t -> t -> bool
  val initial : t -> reload
  val apply : reload -> (t, error) result -> reload
  val effective : reload -> t
  val readiness : reload -> readiness
end

module type S = sig
  include PURE

  type registry

  val resolve :
    registry ->
    env:Environment.t ->
    document:Workflow_document.t ->
    (t, error) result
end

module type STARTUP = sig
  include S

  type startup

  val resolve_startup :
    registry ->
    env:Environment.t ->
    document:Workflow_document.t ->
    (startup, error) result

  val runtime : startup -> t
  val listener_port : startup -> Http_port.t option
end

module Make (Tracker : Tracker.CONFIG) = struct
  type tracker = Tracker.Contract.binding
  type registry = Tracker.t

  type t = {
    scheduling : Scheduling_policy.t;
    agent : Agent_settings.t;
    workspace : Workspace_settings.t;
    tracker : tracker;
    prompt : string;
    file : Workflow_path.t;
    child : Environment.child;
  }

  type startup = { configuration : t; port : Http_port.t option }
  type readiness = Ready | Blocked of error
  type reload = { good : t; validity : readiness }

  let scheduling t = t.scheduling
  let agent t = t.agent
  let workspace t = t.workspace
  let tracker t = t.tracker
  let prompt_source t = t.prompt
  let file t = t.file
  let child_env t = t.child
  let runtime startup = startup.configuration
  let listener_port startup = startup.port

  let equal a b =
    Scheduling_policy.equal a.scheduling b.scheduling
    && Agent_settings.equal a.agent b.agent
    && Workspace_settings.equal a.workspace b.workspace
    && Tracker.Contract.equal a.tracker b.tracker
    && a.prompt = b.prompt
    && Workflow_path.display a.file = Workflow_path.display b.file
    && Environment.bindings a.child = Environment.bindings b.child

  let initial good = { good; validity = Ready }

  let apply r = function
    | Ok good -> { good; validity = Ready }
    | Error e -> { r with validity = Blocked e }

  let effective r = r.good
  let readiness r = r.validity

  let allow_env =
    [
      "PATH";
      "HOME";
      "USER";
      "LOGNAME";
      "SHELL";
      "TMPDIR";
      "LANG";
      "LC_ALL";
      "LC_CTYPE";
      "TZ";
      "TERM";
      "CODEX_HOME";
    ]

  let fallback = "You are working on an issue from the configured tracker."

  let field_errors file errors =
    Fields
      (Nonempty_list.map
         (Diagnostic.at_file (Workflow_path.display file))
         errors)

  let check_section config file key =
    match Config_value.field config key with
    | None -> Ok ()
    | Some value ->
        Result.map
          (fun _ -> ())
          (Result.map_error
             (fun error ->
               field_errors file
                 (Nonempty_list.singleton (Fields.diagnostic ~key error)))
             (Fields.mapping value))

  let resolve_core registry ~env ~document =
    let ( let* ) = Result.bind in
    let config = Workflow_document.config document
    and file = Workflow_document.file document in
    let fields errors = field_errors file errors in
    let* _ =
      Fields.sequence
        (List.map
           (check_section config file)
           [ "tracker"; "polling"; "workspace"; "hooks"; "agent"; "codex" ])
    in
    let* kind =
      match Fields.get config [ "tracker"; "kind" ] with
      | None ->
          Error
            (fields
               (Nonempty_list.singleton
                  (Fields.diagnostic ~key:"tracker.kind"
                     "tracker kind is required")))
      | Some v -> Ok v
    in
    let* provider =
      match Fields.get config [ "tracker"; "provider" ] with
      | Some p -> Ok p
      | None ->
          Result.map_error
            (fun e ->
              fields
                (Nonempty_list.singleton
                   (Fields.diagnostic ~key:"tracker.provider" e)))
            (Config_value.parse "{}")
    in
    (* Bootstrap credentials first; public fields receive only restricted authority. *)
    let* tracker, env =
      Result.map_error
        (fun e ->
          Tracker
            (Tracker_error.make (Tracker_error.category e)
               (Diagnostic.at_file
                  (Workflow_path.display file)
                  (Tracker_error.diagnostic e))))
        (Tracker.configure registry ~env ~kind ~provider)
    in
    let* scheduling =
      Result.map_error fields (Scheduling_policy.parse ~env config)
    in
    let* agent = Result.map_error fields (Agent_settings.parse ~env config) in
    let* workspace =
      Result.map_error fields
        (Workspace_settings.parse ~env ~workflow_file:file config)
    in
    let prompt = Workflow_document.prompt document in
    let prompt = if prompt = "" then fallback else prompt in
    (* A reload cannot install prompt syntax that fails every future worker. *)
    let* _ =
      Result.map_error
        (function
          | Template.Parse_error diagnostic | Template.Render_error diagnostic
            -> fields (Nonempty_list.singleton diagnostic))
        (Template.compile ~file prompt)
    in
    let child = Environment.child env ~allow:allow_env in
    Ok ({ scheduling; agent; workspace; tracker; prompt; file; child }, env)

  let resolve registry ~env ~document =
    Result.map fst (resolve_core registry ~env ~document)

  let resolve_startup registry ~env ~document =
    let ( let* ) = Result.bind in
    let* configuration, env = resolve_core registry ~env ~document in
    let config = Workflow_document.config document
    and file = Workflow_document.file document in
    let* () = check_section config file "server" in
    let* port =
      Result.map_error (field_errors file) (Server_settings.parse ~env config)
    in
    Ok { configuration; port }
end
