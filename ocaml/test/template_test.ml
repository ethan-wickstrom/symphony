let checked = function
  | Ok x -> x
  | Error message -> Alcotest.fail message

let file =
  let base = checked (Absolute_path.parse "/tmp/symphony-template-tests") in
  checked (Workflow_path.resolve ~base "WORKFLOW.md")

let issue ?(title = "Repair the parser") ?description ?native_ref () =
  checked
    (Issue.parse
       {
         Issue.id = "issue-1";
         identifier = "SYM-1";
         title;
         description;
         priority = Some "2";
         state = "Todo";
         branch_name = None;
         url = None;
         labels = [ "bug"; "team" ];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref;
       })

let compile source =
  match Template.compile ~file source with
  | Ok t -> t
  | Error (Template.Parse_error d | Template.Render_error d) ->
      Alcotest.fail (Diagnostic.render d)

let rendered ?(attempt = Template.First) issue source =
  match Template.render (compile source) ~issue ~attempt with
  | Ok text -> text
  | Error (Template.Parse_error d | Template.Render_error d) ->
      Alcotest.fail (Diagnostic.render d)

let check source expected =
  Alcotest.check Alcotest.string source expected (rendered (issue ()) source)

let render_error source =
  match
    Template.render (compile source) ~issue:(issue ()) ~attempt:Template.First
  with
  | Error (Template.Render_error _) -> ()
  | Error (Template.Parse_error _) ->
      Alcotest.fail "render returned a parse error"
  | Ok _ -> Alcotest.fail ("expected render error: " ^ source)

let named_render_error name task source =
  match
    Template.render (compile source) ~issue:task ~attempt:Template.First
  with
  | Error (Template.Render_error diagnostic) ->
      let message = Diagnostic.render diagnostic in
      let regexp = Re.compile (Re.str name) in
      if not (Re.execp regexp message) then
        Alcotest.fail ("expected " ^ name ^ ": " ^ message)
  | Error (Template.Parse_error _) -> Alcotest.fail "unexpected parse error"
  | Ok _ -> Alcotest.fail ("expected " ^ name ^ " error")

let parse_error source =
  match Template.compile ~file source with
  | Error (Template.Parse_error _) -> ()
  | Error (Template.Render_error _) ->
      Alcotest.fail "compile returned a render error"
  | Ok _ -> Alcotest.fail ("expected parse error: " ^ source)

let null_and_missing () =
  check "{{ issue.description }}" "";
  check "{{ issue.description | default('none') }}" "none";
  check "{% if issue.description == null %}null{% endif %}" "null";
  List.iter render_error
    [
      "{{ absent }}";
      "{{ issue.absent }}";
      "{{ issue.absent | default('hidden') }}";
      "{{ issue.description.title }}";
      "{{ issue.title.missing }}";
    ]

let indexes () =
  check "{{ issue['title'] }}" "Repair the parser";
  check "{{ issue.labels[0] }}" "bug";
  check "{{ issue.labels[1] }}" "team";
  List.iter render_error
    [
      "{{ issue.labels[2] }}";
      "{{ issue.labels[-1] }}";
      "{{ issue.labels['x'] }}";
      "{{ issue.labels[false] }}";
      "{{ issue.title[0] }}";
    ];
  render_error ("{{ issue.labels[" ^ string_of_int max_int ^ "] }}")

let filters () =
  check "{{ issue.labels | join(', ') }}" "bug, team";
  check "{{ issue.labels | length }}" "2";
  check "{{ ' Grüß ' | trim | upper }}" "GRÜSS";
  check "{{ 'İ' | lower }}" "i̇";
  check "{{ 'a.b.a' | replace('.', '\\\\1') }}" "a\\1b\\1a";
  check "{{ 'é' | replace('', '-') }}" "-é-";
  List.iter parse_error
    [
      "{{ issue.title | missing_filter }}";
      "{{ issue.title | random }}";
      "{{ lower() }}";
      "{{ issue.title | replace('x') }}";
      "{{ issue.title | join(separator=',') }}";
    ];
  render_error "{{ issue.priority | upper }}"

let scopes () =
  check
    "{% for issue in issue.labels %}{{ issue }}{% endfor %}|{{ \
     issue.identifier }}"
    "bugteam|SYM-1";
  check
    "{% for x in issue.labels %}{{ x }}{% for x in ['inner'] %}{{ x }}{% \
     endfor %}{{ x }}{% endfor %}"
    "buginnerbugteaminnerteam";
  render_error "{% for x in issue.labels %}{% endfor %}{{ x }}";
  render_error "{% for x in issue.labels %}{{ loop.cycle }}{% endfor %}";
  check "{% for loop in issue.labels %}{{ loop }}{% endfor %}" "bugteam";
  check "{% for k in {'a':1,'b':2} %}{{ k }}{% endfor %}" "ab";
  check "{% for k,v in {'a':1,'b':2} %}{{ k }}={{ v }};{% endfor %}" "a=1;b=2;";
  render_error "{% for a,b in issue.labels %}{{ a }}{% endfor %}"

let injection () =
  check "{% raw %}{{ absent }}{% endraw %}" "{{ absent }}";
  check "before{# ignored {{ absent }} #}after" "beforeafter";
  let title = "{{ absent }}{% include '/etc/passwd' %}$(touch /tmp/pwned)" in
  Alcotest.check Alcotest.string "interpolation stays data" title
    (rendered (issue ~title ()) "{{ issue.title }}");
  List.iter parse_error
    [
      "{% include '/etc/passwd' %}";
      "{% extends '/etc/passwd' %}";
      "{% import '/etc/passwd' as x %}";
      "{% set x = 'a' %}";
      "{% macro x() %}x{% endmacro %}";
      "{{ eval(issue.title) }}";
      "{{ issue.native_ref.tool() }}";
      "{{ range(1000000) }}";
      "{{ 2 ** 100 }}";
      "{{ 0.1 }}";
    ]

let reference_prompt () =
  let source =
    "Ticket {{ issue.identifier }}\n\
     {% if attempt %}Follow-up #{{ attempt }}\n\
     {% endif %}{{ issue.title }}\n\
     {% if issue.description %}{{ issue.description }}{% else %}No \
     description.{% endif %}"
  in
  let task = issue ~description:"Use checked access." () in
  Alcotest.check Alcotest.string "first attempt"
    "Ticket SYM-1\nRepair the parser\nUse checked access."
    (rendered task source);
  Alcotest.check Alcotest.string "follow-up"
    "Ticket SYM-1\nFollow-up #2\nRepair the parser\nUse checked access."
    (rendered
       ~attempt:(Template.Follow_up (Positive_count.next Positive_count.first))
       task source)

let exact_numbers () =
  let huge = "999999999999999999999999999999999999999999999999999" in
  let native_ref = checked (Json.parse ("{\"number\":" ^ huge ^ "}")) in
  Alcotest.check Alcotest.string "opaque numeral stays exact" huge
    (rendered (issue ~native_ref ()) "{{ issue.native_ref.number }}");
  Alcotest.check Alcotest.string "attempt stays exact" huge
    (rendered
       ~attempt:(Template.Follow_up (checked (Positive_count.parse huge)))
       (issue ()) "{{ attempt }}");
  let native_ref =
    checked
      (Json.parse
         "{\"n\":1.2000e100000000000000000000,\"zero\":-0.00,\"small\":1e-999999999999999999}")
  in
  let task = issue ~native_ref () in
  Alcotest.check Alcotest.string "numbers and exponent stay exact"
    "{\"n\":1.2000e100000000000000000000,\"zero\":-0.00,\"small\":1e-999999999999999999}"
    (rendered task "{{ issue.native_ref }}");
  Alcotest.check Alcotest.string "exact comparison and zero truth"
    "big zero tiny"
    (rendered task
       "{% if issue.native_ref.n > 9 %}big {% endif %}{% if not \
        issue.native_ref.zero %}zero {% endif %}{% if issue.native_ref.small < \
        1 %}tiny{% endif %}")

let short_circuit () =
  check "{% if false and absent %}bad{% else %}ok{% endif %}" "ok";
  check "{% if true or absent %}ok{% endif %}" "ok";
  check "{{ true ? 'ok' : absent }}" "ok";
  render_error "{% if true and absent %}bad{% endif %}"

let private_marker () =
  let native_ref =
    checked
      (Json.parse
         "{\"__symphony_exact_decimal\":\"1\",\"__str__\":\"{{ absent \
          }}\",\"__eq__\":\"eval\"}")
  in
  let task = issue ~native_ref () in
  Alcotest.check Alcotest.string "JSON cannot forge a private number" "false"
    (rendered task "{{ issue.native_ref == 1 }}");
  Alcotest.check Alcotest.string "object methods stay data"
    "{\"__symphony_exact_decimal\":\"1\",\"__str__\":\"{{ absent \
     }}\",\"__eq__\":\"eval\"}"
    (rendered task "{{ issue.native_ref }}")

let normalized_fields () =
  let fields =
    [
      "id";
      "identifier";
      "title";
      "description";
      "priority";
      "state";
      "branch_name";
      "url";
      "labels";
      "blocked_by";
      "created_at";
      "updated_at";
      "native_ref";
    ]
  in
  let source =
    String.concat "|"
      (List.map (fun field -> "{{ issue." ^ field ^ " }}") fields)
  in
  check source
    "issue-1|SYM-1|Repair the parser||2|Todo|||[\"bug\",\"team\"]|[]|||";
  check "{{ {'a':[1,null,true], 'b':'text'} }}"
    "{\"a\":[1,null,true],\"b\":\"text\"}"

let budgets () =
  parse_error (String.make ((256 * 1024) + 1) 'x');
  parse_error
    ("{{ issue" ^ String.concat "" (List.init 80 (fun _ -> ".x")) ^ " }}");
  parse_error (String.concat "" (List.init 9000 (fun _ -> "{{ 1 }}")));
  let nested =
    "{% for a in issue.native_ref.items %}{% for b in issue.native_ref.items \
     %}{% for c in issue.native_ref.items %}{% endfor %}{% endfor %}{% endfor \
     %}"
  in
  let items = String.concat "," (List.init 130 (fun _ -> "null")) in
  let native_ref = checked (Json.parse ("{\"items\":[" ^ items ^ "]}")) in
  named_render_error "render work" (issue ~native_ref ()) nested;
  let source =
    "{% for x in [1,2,3,4,5,6,7,8] %}"
    ^ String.make (150 * 1024) 'x'
    ^ "{% endfor %}"
  in
  named_render_error "string/output bytes" (issue ()) source;
  let replacement = String.make (24 * 1024) 'y' in
  let source = "{{ issue.title | replace('x', '" ^ replacement ^ "') }}" in
  named_render_error "string/output bytes"
    (issue ~title:(String.make 50 'x') ())
    source;
  let title = String.concat "" (List.init 350_000 (fun _ -> "İ")) in
  named_render_error "string/output bytes" (issue ~title ())
    "{{ issue.title | lower }}"

(* This model has no Jingoo types, parser, interpreter, or helpers. *)
type value =
  | Null
  | Text of string
  | Boolean of bool
  | Integer of int
  | Array of value list
  | Object of (string * value) list

type expression = Path of string list | Constant of value

type statement =
  | Literal of string
  | Expand of expression
  | Conditional of expression * statement list * statement list
  | Iterate of string * expression * statement list

let model_issue =
  [
    ( "issue",
      Object
        [
          ("identifier", Text "SYM-1");
          ("title", Text "Repair the parser");
          ("description", Null);
          ("priority", Integer 2);
          ("labels", Array [ Text "bug"; Text "team" ]);
        ] );
    ("attempt", Null);
  ]

let rec model_json = function
  | Null -> "null"
  | Text s -> "\"" ^ s ^ "\""
  | Boolean b -> string_of_bool b
  | Integer n -> string_of_int n
  | Array xs -> "[" ^ String.concat "," (List.map model_json xs) ^ "]"
  | Object xs ->
      "{"
      ^ String.concat ","
          (List.map
             (fun (key, value) -> "\"" ^ key ^ "\":" ^ model_json value)
             xs)
      ^ "}"

let model_display = function
  | Null -> ""
  | Text s -> s
  | Boolean b -> string_of_bool b
  | Integer n -> string_of_int n
  | (Array _ | Object _) as value -> model_json value

let truth = function
  | Null -> false
  | Boolean b -> b
  | Integer n -> n <> 0
  | Text s -> s <> ""
  | Array xs -> xs <> []
  | Object xs -> xs <> []

let model_expr environment = function
  | Constant value -> Ok value
  | Path parts ->
      let rec lookup environment = function
        | [] -> Error ()
        | key :: rest -> (
            match (List.assoc_opt key environment, rest) with
            | Some value, [] -> Ok value
            | Some (Object entries), _ :: _ -> lookup entries rest
            | None, _
            | Some (Null | Text _ | Boolean _ | Integer _ | Array _), _ :: _ ->
                Error ())
      in
      lookup environment parts

let rec model environment = function
  | [] -> Ok ""
  | statement :: rest ->
      let head =
        match statement with
        | Literal s -> Ok s
        | Expand e -> Result.map model_display (model_expr environment e)
        | Conditional (condition, yes, no) ->
            Result.bind (model_expr environment condition) (fun value ->
                model environment (if truth value then yes else no))
        | Iterate (name, expression, body) ->
            Result.bind (model_expr environment expression) (function
              | (Array _ | Object _) as iterable ->
                  let values =
                    match iterable with
                    | Array xs -> xs
                    | Object xs -> List.map (fun (key, _) -> Text key) xs
                    | Null | Text _ | Boolean _ | Integer _ -> []
                  in
                  List.fold_left
                    (fun result value ->
                      Result.bind result (fun text ->
                          Result.map (( ^ ) text)
                            (model ((name, value) :: environment) body)))
                    (Ok "") values
              | Null | Text _ | Boolean _ | Integer _ -> Error ())
      in
      Result.bind head (fun text ->
          Result.map (( ^ ) text) (model environment rest))

let quote text = "'" ^ text ^ "'"

let syntax_expr = function
  | Path parts -> String.concat "." parts
  | Constant Null -> "null"
  | Constant (Text text) -> quote text
  | Constant (Boolean value) -> string_of_bool value
  | Constant (Integer value) -> string_of_int value
  | Constant (Array _) -> "[]"
  | Constant (Object _) -> "{}"

let rec syntax statements =
  String.concat "" (List.map syntax_statement statements)

and syntax_statement = function
  | Literal text -> text
  | Expand expression -> "{{ " ^ syntax_expr expression ^ " }}"
  | Conditional (condition, yes, no) ->
      "{% if " ^ syntax_expr condition ^ " %}" ^ syntax yes ^ "{% else %}"
      ^ syntax no ^ "{% endif %}"
  | Iterate (name, expression, body) ->
      "{% for " ^ name ^ " in " ^ syntax_expr expression ^ " %}" ^ syntax body
      ^ "{% endfor %}"

let model_result ast =
  match Template.compile ~file (syntax ast) with
  | Error _ -> Error ()
  | Ok template -> (
      match
        Template.render template ~issue:(issue ()) ~attempt:Template.First
      with
      | Ok text -> Ok text
      | Error _ -> Error ())

let ast_gen =
  let open QCheck2.Gen in
  let expression =
    oneof_list
      [
        Path [ "issue"; "identifier" ];
        Path [ "issue"; "title" ];
        Path [ "issue"; "description" ];
        Path [ "issue"; "priority" ];
        Path [ "issue"; "labels" ];
        Path [ "issue"; "missing" ];
        Path [ "missing" ];
        Constant (Text "literal");
        Constant (Boolean true);
        Constant (Boolean false);
        Constant Null;
      ]
  in
  let leaf =
    oneof [ map (fun e -> Expand e) expression; return (Literal "|text|") ]
  in
  let body = list_size (int_range 0 5) leaf in
  let conditional =
    map3 (fun e y n -> Conditional (e, y, n)) expression body body
  in
  let loop =
    map
      (fun name ->
        Iterate (name, Path [ "issue"; "labels" ], [ Expand (Path [ name ]) ]))
      (oneof_list [ "x"; "issue"; "loop"; "__symphony_bound_0" ])
  in
  list_size (int_range 0 10) (oneof [ leaf; conditional; loop ])

let numeral (coefficient, exponent) =
  string_of_int coefficient ^ "e" ^ string_of_int exponent

let rational (coefficient, exponent) =
  let power = Z.pow (Z.of_int 10) (abs exponent) in
  if exponent < 0 then Q.make (Z.of_int coefficient) power
  else Q.of_bigint (Z.mul (Z.of_int coefficient) power)

let comparison_property (left, right) =
  let expected = Q.compare (rational left) (rational right) in
  let native_ref =
    checked
      (Json.parse
         ("{\"left\":" ^ numeral left ^ ",\"right\":" ^ numeral right ^ "}"))
  in
  let actual =
    rendered (issue ~native_ref ())
      "{% if issue.native_ref.left < issue.native_ref.right %}lt{% elif \
       issue.native_ref.left == issue.native_ref.right %}eq{% else %}gt{% \
       endif %}"
  in
  String.equal actual
    (if expected < 0 then "lt" else if expected = 0 then "eq" else "gt")

let bounded_bytes source =
  match Template.compile ~file source with
  | Error (Template.Parse_error _) -> true
  | Error (Template.Render_error _) -> false
  | Ok template -> (
      match
        Template.render template ~issue:(issue ()) ~attempt:Template.First
      with
      | Ok _ | Error (Template.Render_error _) -> true
      | Error (Template.Parse_error _) -> false)

let properties =
  [
    QCheck2.Test.make ~name:"template agrees with independent AST model"
      ~count:1000 ast_gen (fun ast -> model_result ast = model model_issue ast);
    QCheck2.Test.make ~name:"template render deterministic and reusable"
      ~count:500 ast_gen (fun ast ->
        match Template.compile ~file (syntax ast) with
        | Error _ -> false
        | Ok template ->
            let task = issue () in
            Template.render template ~issue:task ~attempt:Template.First
            = Template.render template ~issue:task ~attempt:Template.First);
    QCheck2.Test.make
      ~name:"AST sequence interpretation preserves concatenation" ~count:500
      QCheck2.Gen.(pair ast_gen ast_gen)
      (fun (a, b) ->
        let composed =
          Result.bind (model_result a) (fun x ->
              Result.map (( ^ ) x) (model_result b))
        in
        model_result ([] @ a) = model_result a
        && model_result (a @ []) = model_result a
        && model_result (a @ b) = composed);
    QCheck2.Test.make ~name:"loop alpha-renaming preserves output" ~count:500
      QCheck2.Gen.(
        pair
          (oneof_list [ "x"; "issue"; "loop" ])
          (oneof_list [ "y"; "attempt"; "private" ]))
      (fun (a, b) ->
        let loop name =
          [
            Iterate
              (name, Path [ "issue"; "labels" ], [ Expand (Path [ name ]) ]);
          ]
        in
        model_result (loop a) = model_result (loop b));
    QCheck2.Test.make
      ~name:"numeric comparison agrees with exact rational model" ~count:1000
      QCheck2.Gen.(
        pair
          (pair (int_range (-9999) 9999) (int_range (-10) 10))
          (pair (int_range (-9999) 9999) (int_range (-10) 10)))
      comparison_property;
    QCheck2.Test.make ~name:"bounded template bytes never escape as exceptions"
      ~count:2000
      QCheck2.Gen.(
        map2
          (fun mode bytes ->
            if mode = 0 then bytes
            else if mode = 1 then "{{ " ^ bytes ^ " }}"
            else "{% if " ^ bytes ^ " %}{% endif %}")
          (int_range 0 2)
          (oneof
             [
               string_size ~gen:char (int_range 0 2048);
               string_size
                 ~gen:(map Char.chr (int_range 32 126))
                 (int_range 0 2048);
             ]))
      bounded_bytes;
  ]

let tests =
  [
    Alcotest.test_case "known null differs from missing" `Quick null_and_missing;
    Alcotest.test_case "strict field and index access" `Quick indexes;
    Alcotest.test_case "finite strict filters" `Quick filters;
    Alcotest.test_case "lexical loop scopes" `Quick scopes;
    Alcotest.test_case "data cannot become template code" `Quick injection;
    Alcotest.test_case "reference prompt and attempt" `Quick reference_prompt;
    Alcotest.test_case "exact numeral display" `Quick exact_numbers;
    Alcotest.test_case "short circuit preserves branch laziness" `Quick
      short_circuit;
    Alcotest.test_case "untrusted objects cannot forge helpers" `Quick
      private_marker;
    Alcotest.test_case "all normalized fields and JSON collections" `Quick
      normalized_fields;
    Alcotest.test_case "source depth fuel output bounds" `Quick budgets;
    Alcotest.test_case "empty template remains empty" `Quick (fun () ->
        check "" "");
  ]
