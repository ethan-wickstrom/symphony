module Path = struct
  type t = |

  let display (value : t) =
    match value with
    | _ -> .
end

module Reference : Workspace_manager.PURE with type Path.t = Path.t =
  Workspace_reference.Make (Path)

module Model = Workspace_reference_model

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let base = checked (Absolute_path.parse "/tmp/symphony-reference-tests")
let file = checked (Workflow_path.resolve ~base "WORKFLOW.md")
let samples = 1000

let input tag identifier : Model.input =
  {
    Model.root = "/srv/symphony-" ^ tag;
    after_create = Some ("create " ^ tag);
    before_run = Some ("prepare '" ^ tag ^ "' $KEEP");
    after_run = None;
    before_remove = Some ("remove " ^ tag);
    timeout_ms = "17";
    environment = [ ("KEEP", tag); ("SAFE", "literal $SECRET") ];
    scope = "tracker:" ^ tag;
    issue_id = "opaque:" ^ tag;
    identifier;
  }

let arguments (expected : Model.input) =
  let raw_env =
    checked
      (Environment.of_bindings ~temp_dir:base
         (("SECRET", "fixture-excluded-credential")
         :: expected.Model.environment))
  in
  let env =
    Environment.child raw_env
      ~allow:[ "KEEP"; "SAFE"; "SECRET" ]
      ~deny:[ "SECRET" ]
  in
  let script = function
    | None -> `Null
    | Some text -> `String text
  in
  let source =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("workspace", `Assoc [ ("root", `String expected.Model.root) ]);
           ( "hooks",
             `Assoc
               [
                 ("after_create", script expected.Model.after_create);
                 ("before_run", script expected.Model.before_run);
                 ("after_run", script expected.Model.after_run);
                 ("before_remove", script expected.Model.before_remove);
                 ("timeout_ms", `String expected.Model.timeout_ms);
               ] );
         ])
  in
  let config = checked (Config_value.parse source) in
  let settings =
    match Workspace_settings.parse ~env:raw_env ~workflow_file:file config with
    | Ok settings -> settings
    | Error diagnostics ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list diagnostics)))
  in
  let scope = checked (Tracker_scope.parse expected.Model.scope) in
  let issue_id = checked (Issue_id.parse expected.Model.issue_id) in
  let identifier = checked (Issue_identifier.parse expected.Model.identifier) in
  (settings, env, scope, issue_id, identifier)

let make expected =
  let settings, env, scope, issue_id, identifier = arguments expected in
  Reference.reference ~settings ~env ~scope ~issue_id ~identifier

let diagnostic = function
  | Workspace_manager.Invalid_key error
  | Workspace_manager.Unsafe_path error
  | Workspace_manager.Ownership_conflict error
  | Workspace_manager.Filesystem_error error
  | Workspace_manager.Hook_failed error
  | Workspace_manager.Hook_timeout error -> Diagnostic.render error

let reference expected =
  match make expected with
  | Ok reference -> reference
  | Error error -> Alcotest.fail (diagnostic error)

let observe reference : Model.input =
  let settings = Reference.settings reference in
  {
    Model.root = Absolute_path.display (Workspace_settings.root settings);
    after_create =
      Workspace_settings.script settings Workspace_settings.After_create;
    before_run =
      Workspace_settings.script settings Workspace_settings.Before_run;
    after_run = Workspace_settings.script settings Workspace_settings.After_run;
    before_remove =
      Workspace_settings.script settings Workspace_settings.Before_remove;
    timeout_ms = Milliseconds.decimal (Workspace_settings.timeout settings);
    environment = Environment.bindings (Reference.environment reference);
    scope = Tracker_scope.text (Reference.scope reference);
    issue_id = Issue_id.text (Reference.issue_id reference);
    identifier = Issue_identifier.text (Reference.identifier reference);
  }

let key reference = Workspace_key.text (Reference.key reference)

let matches actual expected =
  Model.equal_input (observe actual) (Model.input expected)
  && String.equal (key actual) (Model.key expected)

let invalid_key = function
  | Workspace_manager.Invalid_key _ -> true
  | Workspace_manager.Unsafe_path _
  | Workspace_manager.Ownership_conflict _
  | Workspace_manager.Filesystem_error _
  | Workspace_manager.Hook_failed _
  | Workspace_manager.Hook_timeout _ -> false

let agrees expected =
  match (make expected, Model.make expected) with
  | Ok actual, Ok model -> matches actual model
  | Error error, Error _ -> invalid_key error
  | Error _, Ok _ | Ok _, Error _ -> false

let frozen () =
  let original = input "old" "SYM-1" in
  let settings, env, scope, issue_id, identifier = arguments original in
  let existing =
    checked
      (Result.map_error diagnostic
         (Reference.reference ~settings ~env ~scope ~issue_id ~identifier))
  in
  let changed =
    {
      (input "new" "OTHER-1") with
      Model.after_run = Some "finish new";
      timeout_ms = "99";
    }
  in
  ignore (reference changed);
  Alcotest.(check bool)
    "original settings retained" true
    (Workspace_settings.equal settings (Reference.settings existing));
  Alcotest.(check bool)
    "original sanitized environment retained" true
    (List.equal
       (fun (name, value) (other_name, other_value) ->
         String.equal name other_name && String.equal value other_value)
       (Environment.bindings env)
       (Environment.bindings (Reference.environment existing)));
  Alcotest.(check bool)
    "all original observations retained" true
    (Model.equal_input original (observe existing));
  Alcotest.(check bool)
    "checked identifier identity retained" true
    (Issue_identifier.equal identifier (Reference.identifier existing));
  Alcotest.(check bool)
    "checked opaque ID identity retained" true
    (Issue_id.equal issue_id (Reference.issue_id existing));
  Alcotest.(check bool)
    "checked scope identity retained" true
    (Tracker_scope.equal scope (Reference.scope existing))

let identities () =
  List.iter
    (fun identifier ->
      Alcotest.(check bool)
        "constructor agrees with checked-key model" true
        (agrees (input "keys" identifier)))
    [
      "SYM-1";
      "A/B";
      "é";
      ".";
      "..";
      String.make 256 'a';
      String.make 222 'a' ^ "/";
    ]

let reused_identifier () =
  let original = input "same-scope" "SYM-1" in
  let later = { original with Model.issue_id = "different-opaque-id" } in
  let first = reference original in
  let second = reference later in
  Alcotest.(check string) "same filesystem key" (key first) (key second);
  Alcotest.(check bool)
    "different issue ownership" false
    (Issue_id.equal (Reference.issue_id first) (Reference.issue_id second))

let errors () =
  let expected = input "error" "." in
  match make expected with
  | Ok _ -> Alcotest.fail "dot key produced a reference"
  | Error (Workspace_manager.Invalid_key error) ->
      let text = Diagnostic.render error in
      let contains value = Re.execp (Re.compile (Re.str value)) text in
      List.iter
        (fun value -> Alcotest.(check bool) value true (contains value))
        [
          "workspace_identifier=.";
          "workspace.root=" ^ expected.Model.root;
          "dot component";
          "Fix the tracker issue identifier";
        ]
  | Error
      (( Workspace_manager.Unsafe_path _
       | Workspace_manager.Ownership_conflict _
       | Workspace_manager.Filesystem_error _
       | Workspace_manager.Hook_failed _
       | Workspace_manager.Hook_timeout _ ) as error) ->
      Alcotest.fail (diagnostic error)

let tests =
  [
    Alcotest.test_case "references freeze settings environment and identities"
      `Quick frozen;
    Alcotest.test_case "constructor models changed and rejected key candidates"
      `Quick identities;
    Alcotest.test_case "identifier reuse preserves distinct opaque owners"
      `Quick reused_identifier;
    Alcotest.test_case "key failure diagnostic identifies input and remedy"
      `Quick errors;
  ]

let generator =
  QCheck2.Gen.(
    map
      (fun (tag, identifier) ->
        let text = string_of_int tag in
        let original = input text identifier in
        {
          original with
          Model.after_create =
            (if tag mod 3 = 0 then None else original.Model.after_create);
          after_run = (if tag mod 2 = 0 then None else Some ("finish " ^ text));
          timeout_ms = string_of_int (tag + 1);
          environment = [ ("KEEP", text); ("SAFE", "literal $SECRET " ^ text) ];
        })
      (pair (int_range 0 99)
         (oneof_list
            [
              "SYM-1";
              "A/B";
              "é";
              "...";
              ".";
              "..";
              String.make 256 'a';
              String.make 222 'a' ^ "/";
            ])))

let repeat expected =
  match (make expected, make expected) with
  | Ok first, Ok second ->
      Model.equal_input (observe first) (observe second)
      && String.equal (key first) (key second)
  | Error first, Error second -> invalid_key first && invalid_key second
  | Error _, Ok _ | Ok _, Error _ -> false

let unchanged (original, later) =
  match (make original, Model.make original) with
  | Ok existing, Ok expected ->
      ignore (make later);
      matches existing expected
  | Error error, Error _ -> invalid_key error
  | Error _, Ok _ | Ok _, Error _ -> false

let properties =
  [
    QCheck2.Test.make
      ~name:"reference constructor agrees with frozen observation model"
      ~count:samples generator agrees;
    QCheck2.Test.make
      ~name:"reference construction preserves repeated observations"
      ~count:samples generator repeat;
    QCheck2.Test.make
      ~name:"later inputs cannot alter frozen reference observations"
      ~count:samples
      QCheck2.Gen.(pair generator generator)
      unchanged;
  ]
