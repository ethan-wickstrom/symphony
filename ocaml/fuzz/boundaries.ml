module Config = Config_layer.Make (Tracker_config)
module Generic_id = Checked_id.Make ()

module Loader_io = struct
  type t = (string, Workflow_loader.error) result

  let read input ~file:_ = input
end

module Loader = Workflow_loader.Make (Loader_io)

let checked = function
  | Ok value -> value
  | Error message -> Crowbar.fail message

let iter_ok fn = function
  | Ok value -> fn value
  | Error _ -> ()

let must_error label = function
  | Error _ -> ()
  | Ok _ -> Crowbar.failf "%s accepted an invalid boundary value" label

let base = checked (Absolute_path.parse "/srv/symphony/workflows")
let file = checked (Workflow_path.resolve ~base "WORKFLOW.md")

let env =
  checked
    (Environment.of_bindings ~temp_dir:base
       [
         ("HOME", "/home/fixture");
         ("LINEAR_API_KEY", "fuzz-fixture-token");
         ("WORK_ROOT", "repositories");
         ("POLL_MS", "17");
         ("EMPTY", "");
       ])

let registry =
  match
    Tracker_config.make [ Tracker_config.Entry (module Linear_settings) ]
  with
  | Ok value -> value
  | Error error ->
      Crowbar.fail (Diagnostic.render (Tracker_error.diagnostic error))

let tracker_yaml =
  "tracker:\n\
  \  kind: linear\n\
  \  active_states: [Todo, 'In Progress']\n\
  \  terminal_states: [Done, Canceled]\n\
  \  provider:\n\
  \    project_slug: fixture-project\n"

let framed config prompt = "---\n" ^ config ^ "---\n" ^ prompt
let initial_source = framed tracker_yaml "Do the work."

let fixture_json =
  {|{"id":"fixture-id","identifier":"SYMPHONY-1","title":"Fixture title","state":"Todo","labels":[" READY ","ready"],"native_ref":{"opaque":true}}|}

let workflow_error = function
  | Workflow_loader.Missing_file error | Workflow_loader.Read_error error ->
      Diagnostic.render error
  | Workflow_loader.Invalid_document
      ( Workflow_document.Parse_error error
      | Workflow_document.Front_matter_not_map error ) ->
      Diagnostic.render error

let config_error = function
  | Config_layer.Workflow error -> workflow_error error
  | Config_layer.Fields errors ->
      String.concat "\n"
        (List.map Diagnostic.render (Nonempty_list.to_list errors))
  | Config_layer.Tracker error ->
      Diagnostic.render (Tracker_error.diagnostic error)

let load input =
  match Loader.load input ~file with
  | Error error -> Error (Config_layer.Workflow error)
  | Ok document -> Config.resolve registry ~env ~document

let initial =
  match load (Ok initial_source) with
  | Ok settings -> settings
  | Error error -> Crowbar.fail (config_error error)

(* Static generator shapes keep replay input bounded without filtering failures. *)
(* Crowbar 0.2.2's byte reader accepts requests of at most 256 bytes. *)
let max_random_bytes = 256

(* Crowbar's heterogeneous input constructors share names with ordinary lists.
   Confine the intentional empty-constructor shadow to this one value. *)
let no_inputs : ('a, 'a) Crowbar.gens =
  let open! Crowbar in
  []

let ( @> ) generator rest =
  (Crowbar.( :: ) (generator, rest) : (_, _) Crowbar.gens)

let raw =
  Crowbar.map
    (Crowbar.range (max_random_bytes + 1)
    @> Crowbar.bytes_fixed max_random_bytes
    @> no_inputs)
    (fun length bytes -> String.sub bytes 0 length)

let ascii =
  Crowbar.map (raw @> no_inputs)
    (String.map (fun c -> Char.chr (32 + (Char.code c mod 95))))

let choose_text samples = Crowbar.choose (raw :: List.map Crowbar.const samples)
let depth_source = String.make 70 '[' ^ "null" ^ String.make 70 ']'
let quoted text = Json.encode (checked (Json.of_view (Json.String text)))

let structured_yaml =
  Crowbar.map
    (ascii @> Crowbar.uint16 @> Crowbar.bool @> no_inputs)
    (fun text number flag ->
      Printf.sprintf
        "{s: %s, n: %d, b: %b, seq: [null, %s, 'true'], map: {inner: %s}}"
        (quoted text) number flag (quoted text) (quoted text))

let yaml_input =
  Crowbar.choose
    [
      structured_yaml;
      choose_text
        [
          "{}";
          "null";
          "true";
          "'true'";
          "0xFF";
          "999999999999999999999999999999";
          "x: [null, true, 42]";
          "x: 1\nx: 2";
          "*undefined";
          "&cycle [*cycle]";
          "a: &v [true, 42]\nb: *v";
          "!!str true";
          "!application value";
          "---\nx: 1\n---\ny: 2";
          depth_source;
          tracker_yaml;
        ];
    ]

let structured_workflow =
  Crowbar.map
    (Crowbar.uint16 @> ascii @> no_inputs)
    (fun number text ->
      framed
        (tracker_yaml
        ^ Printf.sprintf "polling:\n  interval_ms: %d\nworkspace:\n  root: %s\n"
            number (quoted text))
        ("{{ issue.title }}\n" ^ text))

let workflow_input =
  Crowbar.choose
    [
      structured_workflow;
      choose_text
        [
          initial_source;
          framed (tracker_yaml ^ "polling:\n  interval_ms: $POLL_MS\n") "";
          framed
            (tracker_yaml ^ "workspace:\n  root: $WORK_ROOT\n")
            "{{ issue.title }}";
          framed (tracker_yaml ^ "agent:\n  max_concurrent_agents: 0\n") "body";
          framed (tracker_yaml ^ "codex:\n  turn_timeout_ms: -1\n") "body";
          "---\n---\nbody";
          "---\n[x]\n---\nbody";
          "---\nx: 1";
          "---\nx: 1\nx: 2\n---\nbody";
          framed ("x: " ^ depth_source ^ "\n") "body";
        ];
    ]

let json_input =
  choose_text
    [
      fixture_json;
      "null";
      "{}";
      "[]";
      "[1,true,null,\"x\"]";
      "{\"x\":1,\"x\":2}";
      "NaN";
      "[Infinity]";
      "01";
      "1e999999";
      "\"\\u0000\"";
      "\"\\ud800\"";
      depth_source;
    ]

let template_input =
  choose_text
    [
      "";
      "{{ issue.title }}";
      "{{ attempt }}";
      "{{ issue.description | default('none') }}";
      "{% if issue.priority %}{{ issue.priority }}{% else %}none{% endif %}";
      "{% for label in issue.labels %}{{ label }}{% endfor %}";
      "{{ issue.missing }}";
      "{{ unknown }}";
      "{{ issue.labels[99999] }}";
      "{% include '/etc/passwd' %}";
      "{{ issue.title | unknown_filter }}";
      "{% for x in issue.native_ref %}{% for y in issue.native_ref %}{{ x }}{{ \
       y }}{% endfor %}{% endfor %}";
    ]

let number_input =
  Crowbar.choose
    [
      Crowbar.map (Crowbar.int64 @> no_inputs) Int64.to_string;
      Crowbar.map
        (Crowbar.uint16 @> Crowbar.uint16 @> no_inputs)
        (fun mantissa exponent -> Printf.sprintf "%de%d" mantissa exponent);
      Crowbar.const "-0";
      Crowbar.const "0e999999999999999999999999999999";
      Crowbar.const "1e999999";
      Crowbar.const "-1e-999999";
      Crowbar.const "1.000000000000000000000000000001";
      Crowbar.const "999999999999999999999999999999";
    ]

(* The reference predicate inspects only the mantissa; it never raises a power
   or converts the generated decimal through floating point. *)
let model_zero text =
  let mantissa =
    match String.split_on_char 'e' (String.lowercase_ascii text) with
    | first :: _ -> first
    | [] -> Crowbar.fail "empty numeric fixture model"
  in
  String.for_all
    (function
      | '0' | '-' | '+' | '.' -> true
      | _ -> false)
    mantissa

let native_fixture =
  Crowbar.map
    (ascii @> number_input @> Crowbar.bool @> no_inputs)
    (fun text decimal flag ->
      let source =
        Printf.sprintf
          "{\"id\":\"native-fixture\",\"identifier\":\"NATIVE-1\",\"title\":%s,\"state\":\"Todo\",\"native_ref\":{\"n\":%s,\"nil\":null,\"flag\":%b,\"items\":[%s,%s,{\"nested\":[null,%b]}]}}"
          (quoted ("Title " ^ text))
          decimal flag (quoted text) decimal flag
      in
      (source, Some (decimal, model_zero decimal)))

let fixture_input =
  Crowbar.choose
    [
      native_fixture;
      Crowbar.map (json_input @> no_inputs) (fun source -> (source, None));
    ]

let rec yaml_laws tree =
  let line, column = Config_value.location tree in
  Crowbar.check (line > 0 && column > 0);
  match Config_value.view tree with
  | Config_value.Null
  | Config_value.Bool _
  | Config_value.Number _
  | Config_value.String _ -> ()
  | Config_value.Sequence values -> List.iter yaml_laws values
  | Config_value.Mapping fields ->
      let keys = List.map fst fields in
      Crowbar.check_eq (List.length keys)
        (List.length (List.sort_uniq String.compare keys));
      List.iter (fun (_, value) -> yaml_laws value) fields

let json_laws value =
  let encoded = Json.encode value in
  let again = checked (Json.parse encoded) in
  Crowbar.check_eq ~pp:Crowbar.pp_string encoded (Json.encode again);
  let rebuilt = checked (Json.of_view (Json.view value)) in
  Crowbar.check_eq ~pp:Crowbar.pp_string encoded (Json.encode rebuilt)

let ids source other =
  let instances : (module Checked_id.S) list =
    [
      (module Generic_id);
      (module Issue_id);
      (module Issue_identifier);
      (module Tracker_scope);
    ]
  in
  List.iter
    (fun (module Id : Checked_id.S) ->
      iter_ok
        (fun value ->
          let again = checked (Id.parse (Id.text value)) in
          Crowbar.check (Id.equal value again);
          Crowbar.check_eq 0 (Id.compare value again);
          iter_ok
            (fun next ->
              Crowbar.check (Id.equal value next = (Id.compare value next = 0));
              Crowbar.check_eq
                (Int.compare 0 (Id.compare value next))
                (Int.compare (Id.compare next value) 0))
            (Id.parse other))
        (Id.parse source))
    instances

let numeric source other =
  iter_ok
    (fun value ->
      let again = checked (Count.parse (Count.decimal value)) in
      Crowbar.check_eq 0 (Count.compare value again);
      Crowbar.check_eq 0 (Count.compare value (Count.add Count.zero value));
      Crowbar.check_eq 0
        (Count.compare Count.zero (Count.delta ~previous:value ~current:value));
      (match Count.decimal_bounded ~max_bytes:128 value with
      | Error _ -> ()
      | Ok text -> Crowbar.check (String.length text <= 128));
      let seconds = Seconds.of_nanoseconds value in
      Crowbar.check_eq 0 (Count.compare value (Seconds.nanoseconds seconds));
      Crowbar.check_eq (Seconds.decimal seconds)
        (Seconds.decimal (Seconds.add Seconds.zero seconds));
      ignore (checked (Json.parse (Seconds.decimal seconds)));
      iter_ok
        (fun next ->
          Crowbar.check_eq 0
            (Count.compare (Count.add value next) (Count.add next value));
          let total = Count.add value next in
          Crowbar.check_eq 0
            (Count.compare next (Count.delta ~previous:value ~current:total)))
        (Count.parse other))
    (Count.parse source);
  iter_ok
    (fun value ->
      let again =
        checked
          (Positive_count.parse (Count.decimal (Positive_count.count value)))
      in
      Crowbar.check_eq 0
        (Count.compare
           (Positive_count.count value)
           (Positive_count.count again));
      Crowbar.check_eq 0
        (Count.compare
           (Positive_count.count (Positive_count.next value))
           (Count.add (Positive_count.count value) Count.one)))
    (Positive_count.parse source);
  iter_ok
    (fun value ->
      let again = checked (Milliseconds.parse (Milliseconds.decimal value)) in
      Crowbar.check_eq 0 (Milliseconds.compare value again);
      let sum = checked (Milliseconds.add Milliseconds.zero value) in
      Crowbar.check_eq 0 (Milliseconds.compare value sum))
    (Milliseconds.parse source)

let text_time_path source =
  if Text.valid_utf8 source then (
    Crowbar.check_eq (Text.normalize source)
      (Text.normalize (Text.normalize source));
    Crowbar.check_eq (Text.lower source) (Text.lower (Text.lower source));
    Crowbar.check_eq (Text.upper source) (Text.upper (Text.upper source)));
  let escaped = Text.escape source in
  Crowbar.check (not (String.exists (fun c -> Char.code c < 32) escaped));
  iter_ok
    (fun value ->
      let again = checked (Utc.parse (Utc.rfc3339 value)) in
      Crowbar.check_eq 0 (Utc.compare value again))
    (Utc.parse source);
  let absolute_law value =
    let again = checked (Absolute_path.parse (Absolute_path.display value)) in
    Crowbar.check_eq (Absolute_path.display value) (Absolute_path.display again)
  in
  iter_ok absolute_law (Absolute_path.parse source);
  iter_ok
    (fun value -> absolute_law (Workflow_path.absolute value))
    (Workflow_path.resolve ~base source);
  iter_ok absolute_law (Fields.path env ~base source)

let environments name value duplicate =
  let bindings =
    if duplicate then [ (name, value); (name, value) ] else [ (name, value) ]
  in
  iter_ok
    (fun snapshot ->
      Crowbar.check_eq (Some value) (Environment.lookup snapshot name);
      let child =
        Environment.child snapshot ~allow:[ name; name ] ~deny:[ name ]
      in
      Crowbar.check_eq [] (Environment.bindings child);
      let allowed = Environment.child snapshot ~allow:[ name ] ~deny:[] in
      Crowbar.check_eq [ (name, value) ] (Environment.bindings allowed))
    (Environment.of_bindings ~temp_dir:base bindings)

let fields tree =
  ignore (Fields.get tree [ "tracker"; "kind" ]);
  ignore (Fields.text env tree);
  ignore (Fields.integer env tree);
  ignore (Fields.strings env tree);
  ignore (Fields.mapping tree);
  iter_ok json_laws (Fields.json tree);
  let checked_node source =
    iter_ok
      (fun node ->
        ignore (Fields.integer env node);
        ignore (Fields.text env node))
      (Config_value.parse source)
  in
  List.iter checked_node [ "$POLL_MS"; "'$EMPTY'"; "null"; "0xFF" ];
  iter_ok
    (fun policy ->
      Crowbar.check (Scheduling_policy.global_limit policy > 0);
      let overlap =
        Scheduling_policy.Names.inter
          (Scheduling_policy.active policy)
          (Scheduling_policy.terminal policy)
      in
      Crowbar.check (Scheduling_policy.Names.is_empty overlap);
      Crowbar.check (Scheduling_policy.state_limit policy "unknown" > 0))
    (Scheduling_policy.parse ~env tree);
  iter_ok
    (fun settings -> Crowbar.check (Agent_settings.command settings <> ""))
    (Agent_settings.parse ~env tree);
  ignore (Workspace_settings.parse ~env ~workflow_file:file tree);
  iter_ok
    (fun settings ->
      let scope = Linear_settings.scope settings in
      Crowbar.check (Tracker_scope.text scope <> "");
      Crowbar.check
        (List.mem "LINEAR_API_KEY" (Linear_settings.secret_names settings)))
    (Linear_settings.parse ~env ~active:[ "Todo" ] ~terminal:[ "Done" ] tree)

let yaml_boundary source =
  iter_ok
    (fun tree ->
      yaml_laws tree;
      fields tree)
    (Config_value.parse source)

let fixture_laws parsed =
  let encoded = Json.encode (Issue.to_json parsed) in
  let again = checked (Prompt_fixture.parse encoded) in
  Crowbar.check_eq ~pp:Crowbar.pp_string encoded
    (Json.encode (Issue.to_json again));
  let labels = Issue.labels parsed in
  Crowbar.check_eq (List.length labels)
    (List.length (List.sort_uniq String.compare labels));
  Crowbar.check
    (List.for_all
       (fun label -> label <> "" && Text.normalize label = label)
       labels)

let json_boundary source =
  iter_ok
    (fun value ->
      json_laws value;
      List.iter
        (fun definition -> ignore (Policy_check.validate ~definition value))
        [ "AskForApproval"; "SandboxMode"; "SandboxPolicy" ])
    (Json.parse source);
  iter_ok fixture_laws (Prompt_fixture.parse source)

let issue_boundary title metadata =
  let input : Issue.input =
    {
      Issue.id = "fuzz-id";
      identifier = "SYMPHONY-2";
      title;
      state = "Todo";
      description = Some metadata;
      priority = Some metadata;
      branch_name = Some metadata;
      url = Some metadata;
      labels = [ title; metadata; title ];
      blocked_by = [];
      created_at = Some metadata;
      updated_at = Some metadata;
      dispatchable = Issue.Dispatchable;
      native_ref = None;
    }
  in
  iter_ok fixture_laws (Issue.parse input)

let template_result = function
  | Ok text -> ("ok", text)
  | Error (Template.Parse_error error) -> ("parse", Diagnostic.render error)
  | Error (Template.Render_error error) -> ("render", Diagnostic.render error)

let fixed_template source =
  match Template.compile ~file source with
  | Ok value -> value
  | Error (Template.Parse_error error | Template.Render_error error) ->
      Crowbar.fail (Diagnostic.render error)

let numeric_template = fixed_template "{{ issue.native_ref.n }}"

let zero_template =
  fixed_template
    "{% if issue.native_ref.n == 0 %}zero{% else %}nonzero{% endif %}"

let container_templates =
  List.map fixed_template
    [
      "{{ issue.native_ref }}";
      "{{ issue.native_ref.items }}";
      "{{ issue.native_ref.nil | default('empty') }}";
      "{% for key, value in issue.native_ref %}{{ key }}={{ value }};{% endfor \
       %}";
    ]

let rendered template parsed =
  match Template.render template ~issue:parsed ~attempt:Template.First with
  | Ok text -> text
  | Error (Template.Parse_error error | Template.Render_error error) ->
      Crowbar.fail (Diagnostic.render error)

let fixture_render (source, expectation) =
  match Prompt_fixture.parse source with
  | Error error -> (
      match expectation with
      | None -> ()
      | Some _ ->
          Crowbar.fail ("valid generated issue fixture rejected: " ^ error))
  | Ok parsed -> (
      fixture_laws parsed;
      List.iter
        (fun template ->
          let first =
            Template.render template ~issue:parsed ~attempt:Template.First
          in
          let second =
            Template.render template ~issue:parsed ~attempt:Template.First
          in
          Crowbar.check_eq (template_result first) (template_result second);
          iter_ok
            (fun text -> Crowbar.check (String.length text <= 1_048_576))
            first)
        (numeric_template :: zero_template :: container_templates);
      match expectation with
      | None -> ()
      | Some (decimal, zero) ->
          Crowbar.check_eq ~pp:Crowbar.pp_string decimal
            (rendered numeric_template parsed);
          Crowbar.check_eq ~pp:Crowbar.pp_string
            (if zero then "zero" else "nonzero")
            (rendered zero_template parsed);
          List.iter
            (fun template -> ignore (rendered template parsed))
            container_templates)

let template_boundary source title attempt =
  match Template.compile ~file source with
  | Error (Template.Parse_error _ | Template.Render_error _) -> ()
  | Ok template ->
      let input =
        {
          Issue.id = "fuzz-issue";
          identifier = "SYMPHONY-3";
          title = "Title " ^ title;
          state = "Todo";
          description = None;
          priority = Some "1";
          branch_name = None;
          url = None;
          labels = [ "ready"; title ];
          blocked_by = [];
          created_at = None;
          updated_at = None;
          dispatchable = Issue.Dispatchable;
          native_ref = None;
        }
      in
      let parsed = checked (Issue.parse input) in
      let attempt =
        if attempt = 0 then Template.First
        else
          Template.Follow_up
            (checked (Positive_count.parse (string_of_int attempt)))
      in
      let first = Template.render template ~issue:parsed ~attempt in
      let second = Template.render template ~issue:parsed ~attempt in
      Crowbar.check_eq (template_result first) (template_result second);
      iter_ok
        (fun text -> Crowbar.check (String.length text <= 1_048_576))
        first

let readiness result expected =
  match (result, expected) with
  | Config.Ready, true | Config.Blocked _, false -> ()
  | Config.Ready, false | Config.Blocked _, true ->
      Crowbar.fail "reload gating differs from latest validity"

let workflow_boundary source next missing =
  let missing_error =
    Workflow_loader.Missing_file
      (Diagnostic.make
         ~site:
           (Diagnostic.Workflow
              { file = Workflow_path.display file; key = None; line = None })
         ~message:"missing fuzz workflow" ~remedy:"create WORKFLOW.md")
  in
  let first = load (if missing then Error missing_error else Ok source) in
  let second = load (Ok next) in
  let step (state, last_good) result =
    let updated = Config.apply state result in
    let model_good, valid =
      match result with
      | Ok value -> (value, true)
      | Error _ -> (last_good, false)
    in
    Crowbar.check (Config.equal model_good (Config.effective updated));
    readiness (Config.readiness updated) valid;
    let replay = Config.apply updated result in
    Crowbar.check
      (Config.equal (Config.effective updated) (Config.effective replay));
    readiness (Config.readiness replay) valid;
    (updated, model_good)
  in
  let updated = step (Config.initial initial, initial) first in
  ignore (step updated second);
  iter_ok
    (fun document ->
      Crowbar.check_eq
        (Workflow_path.display file)
        (Workflow_path.display (Workflow_document.file document));
      yaml_laws (Workflow_document.config document);
      iter_ok
        (fun settings ->
          Crowbar.check (Config.equal settings settings);
          let child = Environment.bindings (Config.child_env settings) in
          Crowbar.check (not (List.mem_assoc "LINEAR_API_KEY" child));
          ignore (Template.compile ~file (Config.prompt_source settings)))
        (Config.resolve registry ~env ~document))
    (Workflow_document.parse ~file source)

let collections text count =
  let values = List.init count (fun i -> text ^ string_of_int i) in
  (match Nonempty_list.of_list values with
  | None -> Crowbar.check_eq [] values
  | Some nonempty ->
      Crowbar.check_eq values (Nonempty_list.to_list nonempty);
      Crowbar.check_eq values
        (Nonempty_list.to_list (Nonempty_list.map Fun.id nonempty)));
  let rec allocate remaining allocator names =
    if remaining = 0 then names
    else
      let token, next = Request_id.Allocator.fresh allocator in
      allocate (remaining - 1) next (Request_id.text token :: names)
  in
  let names = allocate count Request_id.Allocator.empty [] in
  Crowbar.check_eq count (List.length (List.sort_uniq String.compare names))

let () =
  Crowbar.add_test ~name:"YAML, fields, policies and adapter settings"
    (yaml_input @> no_inputs) yaml_boundary;
  Crowbar.add_test ~name:"workflow load, config resolve and reload model"
    (workflow_input @> workflow_input @> Crowbar.bool @> no_inputs)
    workflow_boundary;
  Crowbar.add_test ~name:"JSON, policy JSON and normalized issue fixture"
    (json_input @> no_inputs) json_boundary;
  Crowbar.add_test ~name:"issue parser and normalized fixture roundtrip"
    (ascii @> raw @> no_inputs)
    issue_boundary;
  Crowbar.add_test ~name:"template compile and deterministic bounded render"
    (template_input @> ascii @> Crowbar.range 65 @> no_inputs)
    template_boundary;
  Crowbar.add_test ~name:"checked identity equivalence and comparator"
    (choose_text [ "id"; "SYMPHONY-1"; " "; "\000" ] @> raw @> no_inputs)
    ids;
  Crowbar.add_test ~name:"exact count, positive count and duration algebras"
    (choose_text [ "0"; "1"; "42"; "999999999999999999999999999999"; "-1" ]
    @> choose_text [ "0"; "1"; "5" ]
    @> no_inputs)
    numeric;
  Crowbar.add_test ~name:"Unicode, UTC, absolute and workflow path boundaries"
    (choose_text
       [
         "2026-09-30T12:34:56.123456789Z";
         "/srv/../tmp";
         "relative";
         "$WORK_ROOT";
         "~/work";
       ]
    @> no_inputs)
    text_time_path;
  Crowbar.add_test ~name:"environment names, values and denial dominance"
    (choose_text [ "HOME"; "LINEAR_API_KEY"; "X"; "BAD=NAME" ]
    @> raw @> Crowbar.bool @> no_inputs)
    environments;
  Crowbar.add_test ~name:"nonempty list and request identity allocation"
    (raw @> Crowbar.range 65 @> no_inputs)
    collections;
  Crowbar.add_test ~name:"curated duplicate, depth and effect escape rejection"
    (Crowbar.const () @> no_inputs)
    (fun () ->
      must_error "YAML duplicate" (Config_value.parse "x: 1\nx: 2");
      must_error "YAML depth" (Config_value.parse depth_source);
      must_error "JSON duplicate" (Json.parse "{\"x\":1,\"x\":2}");
      must_error "JSON depth" (Json.parse depth_source);
      List.iter
        (fun source ->
          must_error "template effect syntax" (Template.compile ~file source))
        [
          "{% include '/etc/passwd' %}";
          "{% import '/tmp/macros' as m %}";
          "{% macro m() %}x{% endmacro %}";
          "{{ range(100) }}";
          "{{ issue.title | unknown_filter }}";
        ]);
  Crowbar.add_test ~name:"issue data stays uninterpreted template text"
    (ascii @> no_inputs) (fun title ->
      let escaped_title = "{{ missing }}{% include 'file' %}" ^ title in
      let fixture : Issue.input =
        {
          Issue.id = "data";
          identifier = "DATA-1";
          title = escaped_title;
          state = "Todo";
          description = None;
          priority = None;
          branch_name = None;
          url = None;
          labels = [];
          blocked_by = [];
          created_at = None;
          updated_at = None;
          dispatchable = Issue.Dispatchable;
          native_ref = None;
        }
      in
      let parsed = checked (Issue.parse fixture) in
      let template =
        match Template.compile ~file "{{ issue.title }}" with
        | Ok value -> value
        | Error (Template.Parse_error error | Template.Render_error error) ->
            Crowbar.fail (Diagnostic.render error)
      in
      match Template.render template ~issue:parsed ~attempt:Template.First with
      | Ok rendered ->
          Crowbar.check_eq ~pp:Crowbar.pp_string escaped_title rendered
      | Error (Template.Parse_error error | Template.Render_error error) ->
          Crowbar.fail (Diagnostic.render error));
  Crowbar.add_test ~name:"checked fixture JSON through actual template renderer"
    (fixture_input @> no_inputs)
    fixture_render
