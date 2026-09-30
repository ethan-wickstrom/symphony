type hook = After_create | Before_run | After_run | Before_remove

type t = {
  root : Absolute_path.t;
  hooks : string option * string option * string option * string option;
  timeout : Milliseconds.t;
}

let ( let* ) = Result.bind

let parse ~env ~workflow_file config =
  let error key e = Nonempty_list.singleton (Fields.diagnostic ~key e) in
  let* base =
    Result.map_error (error "workspace.root")
      (Absolute_path.parse
         (Filename.dirname (Workflow_path.display workflow_file)))
  in
  let* root =
    match Fields.get config [ "workspace"; "root" ] with
    | None ->
        Result.map_error (error "workspace.root")
          (Absolute_path.parse
             (Filename.concat
                (Absolute_path.display (Environment.temp_dir env))
                "symphony_workspaces"))
    | Some v ->
        let value =
          match Config_value.view v with
          | Config_value.String s -> Ok s
          | Config_value.Null
          | Config_value.Bool _
          | Config_value.Number _
          | Config_value.Sequence _
          | Config_value.Mapping _ -> Error "expected a path string"
        in
        Result.map_error (error "workspace.root")
          (let* s = value in
           Fields.path env ~base s)
  in
  let script key =
    match Fields.get config [ "hooks"; key ] with
    | None -> Ok None
    | Some v -> (
        match Config_value.view v with
        | Config_value.Null -> Ok None
        | Config_value.String s when not (String.contains s '\000') ->
            Ok (Some s)
        | Config_value.String _
        | Config_value.Bool _
        | Config_value.Number _
        | Config_value.Sequence _
        | Config_value.Mapping _ ->
            Error
              (error ("hooks." ^ key)
                 "expected a trusted shell string without NUL"))
  in
  let* a = script "after_create" in
  let* b = script "before_run" in
  let* c = script "after_run" in
  let* d = script "before_remove" in
  let hooks = (a, b, c, d) in
  let* timeout =
    match Fields.get config [ "hooks"; "timeout_ms" ] with
    | None ->
        Result.map_error (error "hooks.timeout_ms") (Milliseconds.parse "60000")
    | Some v ->
        Result.map_error (error "hooks.timeout_ms")
          (let* n = Fields.integer env v in
           if Z.sign n <= 0 then Error "hook timeout must be positive"
           else Milliseconds.parse (Z.to_string n))
  in
  Ok { root; hooks; timeout }

let root t = t.root

let script t hook =
  match (t.hooks, hook) with
  | (a, _, _, _), After_create -> a
  | (_, b, _, _), Before_run -> b
  | (_, _, c, _), After_run -> c
  | (_, _, _, d), Before_remove -> d

let timeout t = t.timeout
let equal a b = a = b
