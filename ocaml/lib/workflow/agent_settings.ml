type turn = Default | Explicit of Json.t

type t = {
  command : string;
  read : Milliseconds.t;
  turn : Milliseconds.t;
  max_turns : int;
  thread : Json.t;
  turn_policy : turn;
}

let ( let* ) = Result.bind

let parse ~env config =
  let error key e = Nonempty_list.singleton (Fields.diagnostic ~key e) in
  let scalar key default =
    match Fields.get config [ "codex"; key ] with
    | None -> Ok default
    | Some v -> Result.map_error (error ("codex." ^ key)) (Fields.text env v)
  in
  let* command =
    match Fields.get config [ "codex"; "command" ] with
    | None -> Ok "codex app-server"
    | Some v -> (
        match Config_value.view v with
        | Config_value.String s
          when String.trim s <> "" && not (String.contains s '\000') -> Ok s
        | Config_value.Null
        | Config_value.Bool _
        | Config_value.Number _
        | Config_value.String _
        | Config_value.Sequence _
        | Config_value.Mapping _ ->
            Error
              (error "codex.command"
                 "command must be a nonempty trusted shell string"))
  in
  let duration key default =
    let value =
      match Fields.get config [ "codex"; key ] with
      | None -> Ok (Z.of_string default)
      | Some v -> Fields.integer env v
    in
    Result.map_error
      (error ("codex." ^ key))
      (let* n = value in
       if Z.sign n <= 0 then Error "timeout must be positive"
       else Milliseconds.parse (Z.to_string n))
  in
  let* read = duration "read_timeout_ms" "5000" in
  let* turn = duration "turn_timeout_ms" "3600000" in
  let* max_turns =
    Result.map_error (error "agent.max_turns")
      (let* n =
         match Fields.get config [ "agent"; "max_turns" ] with
         | None -> Ok (Z.of_int 20)
         | Some v -> Fields.integer env v
       in
       if Z.sign n <= 0 || not (Z.fits_int n) then
         Error "max_turns must be a positive machine integer"
       else Ok (Z.to_int n))
  in
  let* approval =
    match Fields.get config [ "codex"; "approval_policy" ] with
    | None ->
        Result.map_error
          (error "codex.approval_policy")
          (Json.of_view (Json.String "never"))
    | Some v ->
        Result.map_error
          (error "codex.approval_policy")
          (match Config_value.view v with
          | Config_value.String _ ->
              let* s = Fields.text env v in
              Json.of_view (Json.String s)
          | Config_value.Null
          | Config_value.Bool _
          | Config_value.Number _
          | Config_value.Sequence _
          | Config_value.Mapping _ -> Fields.json v)
  in
  let* () =
    Result.map_error
      (error "codex.approval_policy")
      (Policy_check.validate ~definition:"AskForApproval" approval)
  in
  let* sandbox = scalar "thread_sandbox" "workspace-write" in
  let* sandbox_json =
    Result.map_error
      (error "codex.thread_sandbox")
      (Json.of_view (Json.String sandbox))
  in
  let* () =
    Result.map_error
      (error "codex.thread_sandbox")
      (Policy_check.validate ~definition:"SandboxMode" sandbox_json)
  in
  let* thread =
    Result.map_error (error "codex")
      (Json.of_view
         (Json.Object
            [ ("approvalPolicy", approval); ("sandbox", sandbox_json) ]))
  in
  let* turn_policy =
    match Fields.get config [ "codex"; "turn_sandbox_policy" ] with
    | None -> Ok Default
    | Some v ->
        let* j =
          Result.map_error (error "codex.turn_sandbox_policy") (Fields.json v)
        in
        let* () =
          Result.map_error
            (error "codex.turn_sandbox_policy")
            (Policy_check.validate ~definition:"SandboxPolicy" j)
        in
        Ok (Explicit j)
  in
  Ok { command; read; turn; max_turns; thread; turn_policy }

let command t = t.command
let read_timeout t = t.read
let turn_timeout t = t.turn
let max_turns t = t.max_turns
let thread_policy t = t.thread

let equal a b =
  a.command = b.command
  && Milliseconds.compare a.read b.read = 0
  && Milliseconds.compare a.turn b.turn = 0
  && a.max_turns = b.max_turns
  && Json.equal a.thread b.thread
  &&
  match (a.turn_policy, b.turn_policy) with
  | Default, Default -> true
  | Explicit a, Explicit b -> Json.equal a b
  | Default, Explicit _ | Explicit _, Default -> false

module Bind (Path : Workspace_path.S) = struct
  let turn_policy t path =
    match t.turn_policy with
    | Explicit j -> j
    | Default -> (
        let encoded =
          Printf.sprintf
            {|{"type":"workspaceWrite","writableRoots":[%s],"networkAccess":false,"excludeSlashTmp":true,"excludeTmpdirEnvVar":true}|}
            (Yojson.Safe.to_string (`String (Path.display path)))
        in
        (* The sealed workspace capability guarantees a valid bounded path. *)
        match Json.parse encoded with
        | Ok j -> j
        | Error e -> invalid_arg ("workspace capability defect: " ^ e))
end
