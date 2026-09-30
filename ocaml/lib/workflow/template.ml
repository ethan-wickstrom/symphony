open Jingoo.Jg_types
module Interp = Jingoo.Jg_interp
module Runtime = Jingoo.Jg_runtime

type t = { file : Workflow_path.t; ast : ast }
type error = Parse_error of Diagnostic.t | Render_error of Diagnostic.t
type attempt = First | Follow_up of Positive_count.t

let source_limit = 256 * 1024
let ast_node_limit = 16_384
let depth_limit = 64
let value_node_limit = 32_768
let byte_limit = 1024 * 1024
let work_limit = 2_000_000
let decimal_key = "__symphony_exact_decimal"

(* Private exceptions stop the library interpreter without leaking through the API.
   OCaml cannot express a library callback's bounded execution in its type. *)
exception Boundary of string * string

let fail message remedy = raise (Boundary (message, remedy))

let exhausted name =
  fail (name ^ " limit exceeded") ("Reduce prompt/input " ^ name ^ ".")

let diagnostic file message remedy =
  Diagnostic.make
    ~site:
      (Diagnostic.Workflow
         { file = Workflow_path.display file; key = Some "prompt"; line = None })
    ~message ~remedy

type budget = { mutable remaining : int }

let spend budget amount =
  if amount > budget.remaining then exhausted "render work";
  budget.remaining <- budget.remaining - amount

let product budget left right =
  if right <> 0 && left > budget.remaining / right then exhausted "render work";
  spend budget (left * right)

let add_size size amount =
  if amount > byte_limit - size then exhausted "string/output bytes";
  size + amount

let depth level = if level > depth_limit then exhausted "depth"

(* Stdlib UTF-8 decoding is indexed; each index advances by the checked decode
   length. No substring indexes enter the language or core domain. *)
let fold_utf8 fn initial text =
  let rec loop offset acc =
    if offset = String.length text then acc
    else
      let decoded = String.get_utf_8_uchar text offset in
      if not (Uchar.utf_decode_is_valid decoded) then
        fail "Invalid UTF-8 in prompt/input" "Use valid UTF-8 text.";
      loop
        (offset + Uchar.utf_decode_length decoded)
        (fn acc (Uchar.utf_decode_uchar decoded))
  in
  loop 0 initial

let utf8_bytes uchar =
  let value = Uchar.to_int uchar in
  if value <= 0x7f then 1
  else if value <= 0x7ff then 2
  else if value <= 0xffff then 3
  else 4

let mapped_size mapping text =
  fold_utf8
    (fun total uchar ->
      match mapping uchar with
      | `Self -> add_size total (utf8_bytes uchar)
      | `Uchars chars ->
          List.fold_left (fun n u -> add_size n (utf8_bytes u)) total chars)
    0 text

type filter = Length | Join | Lower | Upper | Trim | Replace | Default

let filter name =
  match name with
  | "length" -> (Length, 1)
  | "join" -> (Join, 2)
  | "lower" -> (Lower, 1)
  | "upper" -> (Upper, 1)
  | "trim" -> (Trim, 1)
  | "replace" -> (Replace, 3)
  | "default" -> (Default, 2)
  | name ->
      fail
        ("Unsupported filter/call: " ^ name)
        "Use the documented finite filter set."

let rec application args = function
  | ApplyExpr (callee, more) -> application (more @ args) callee
  | IdentExpr name -> (name, args)
  | LiteralExpr _
  | NotOpExpr _
  | NegativeOpExpr _
  | PlusOpExpr _
  | MinusOpExpr _
  | TimesOpExpr _
  | PowerOpExpr _
  | DivOpExpr _
  | ModOpExpr _
  | AndOpExpr _
  | OrOpExpr _
  | NotEqOpExpr _
  | EqEqOpExpr _
  | LtOpExpr _
  | GtOpExpr _
  | LtEqOpExpr _
  | GtEqOpExpr _
  | DotExpr _
  | BracketExpr _
  | ListExpr _
  | SetExpr _
  | ObjExpr _
  | TestOpExpr _
  | InOpExpr _
  | FunctionExpression _
  | TernaryOpExpr _ ->
      fail "Unsupported dynamic callable" "Use a named documented filter."

let validate ast =
  let remaining = ref ast_node_limit in
  let node level =
    depth level;
    if !remaining = 0 then exhausted "AST nodes";
    decr remaining
  in
  let rec expression level expr =
    node level;
    let child = expression (level + 1) in
    match expr with
    | IdentExpr _ -> ()
    | LiteralExpr (Tnull | Tint _ | Tbool _) -> ()
    | LiteralExpr (Tstr s) -> ignore (fold_utf8 (fun () _ -> ()) () s)
    | LiteralExpr
        ( Tfloat _
        | Tobj _
        | Thash _
        | Tpat _
        | Tlist _
        | Tset _
        | Tfun _
        | Tarray _
        | Tlazy _
        | Tvolatile _
        | Tsafe _ ) ->
        fail "Unsupported literal"
          "Use null, boolean, string, or integer literals."
    | NotOpExpr e | DotExpr (e, _) -> child e
    | NegativeOpExpr (LiteralExpr (Tint _)) -> ()
    | NegativeOpExpr _
    | PlusOpExpr _
    | MinusOpExpr _
    | TimesOpExpr _
    | PowerOpExpr _
    | DivOpExpr _
    | ModOpExpr _ ->
        fail "Unsupported arithmetic"
          "Keep calculations outside the prompt template."
    | AndOpExpr (a, b)
    | OrOpExpr (a, b)
    | NotEqOpExpr (a, b)
    | EqEqOpExpr (a, b)
    | LtOpExpr (a, b)
    | GtOpExpr (a, b)
    | LtEqOpExpr (a, b)
    | GtEqOpExpr (a, b)
    | BracketExpr (a, b)
    | InOpExpr (a, b) ->
        child a;
        child b
    | ApplyExpr _ ->
        let name, args = application [] expr in
        let _, arity = filter name in
        if List.length args <> arity then
          fail
            ("Invalid arity for filter " ^ name)
            "Supply the documented filter arguments.";
        List.iter
          (function
            | None, e -> child e
            | Some _, _ ->
                fail
                  ("Keyword argument for filter " ^ name)
                  "Use positional filter arguments.")
          args
    | ListExpr expressions | SetExpr expressions -> List.iter child expressions
    | ObjExpr entries ->
        let names = List.map fst entries in
        if
          List.length (List.sort_uniq String.compare names) <> List.length names
        then fail "Duplicate template object key" "Use each object key once.";
        List.iter (fun (_, e) -> child e) entries
    | TestOpExpr _ | FunctionExpression _ ->
        fail "Unsupported test/function expression"
          "Use comparisons, conditionals, and documented filters."
    | TernaryOpExpr (a, b, c) ->
        child a;
        child b;
        child c
  and statement level stmt =
    node level;
    let child = statements (level + 1) in
    match stmt with
    | TextStatement _ -> ()
    | ExpandStatement e -> expression (level + 1) e
    | IfStatement branches ->
        List.iter
          (fun (condition, body) ->
            Option.iter (expression (level + 1)) condition;
            child body)
          branches
    | ForStatement (names, iterable, body) ->
        if List.length names > 2 then
          fail "Too many loop bindings"
            "Use one array/key binding or two map bindings.";
        if
          List.length (List.sort_uniq String.compare names) <> List.length names
        then
          fail "Duplicate loop binding"
            "Use distinct names for map key and value.";
        expression (level + 1) iterable;
        child body
    | IncludeStatement _
    | RawIncludeStatement _
    | ExtendsStatement _
    | ImportStatement _
    | FromImportStatement _
    | SetStatement _
    | SetBlockStatement _
    | BlockStatement _
    | MacroStatement _
    | FilterStatement _
    | CallStatement _
    | WithStatement _
    | AutoEscapeStatement _
    | NamespaceStatement _
    | Statements _
    | FunctionStatement _
    | SwitchStatement _ ->
        fail "Unsupported template statement"
          "Use interpolation, if, or for; keep effects outside the template."
  and statements level stmts = List.iter (statement level) stmts in
  statements 1 ast

let compile ~file source =
  let error message remedy =
    Error (Parse_error (diagnostic file message remedy))
  in
  try
    if String.length source > source_limit then exhausted "source bytes";
    ignore (fold_utf8 (fun () _ -> ()) () source);
    let ast = Interp.ast_from_string source in
    validate ast;
    Ok { file; ast }
  with
  | Boundary (message, remedy) -> error message remedy
  | SyntaxError message ->
      error message "Correct the template syntax in WORKFLOW.md."
  | Jingoo.Jg_parser.Error | Failure _ | Invalid_argument _ | Assert_failure _
    ->
      error "Invalid template syntax/literal"
        "Correct the template syntax and use supported literals."
  | Stack_overflow ->
      error "Template parser depth exceeded" "Reduce template nesting."

let exact_number decimal =
  Tpat
    (fun name -> if name = decimal_key then Tstr decimal else raise Not_found)

let number_text = function
  | Tint n -> Some (string_of_int n)
  | Tpat accessor -> (
      match accessor decimal_key with
      | Tstr s -> Some s
      | Tnull
      | Tint _
      | Tbool _
      | Tfloat _
      | Tobj _
      | Thash _
      | Tpat _
      | Tlist _
      | Tset _
      | Tfun _
      | Tarray _
      | Tlazy _
      | Tvolatile _
      | Tsafe _ -> fail "Invalid internal number" "Report this template defect."
      )
  | Tnull
  | Tbool _
  | Tfloat _
  | Tstr _
  | Tobj _
  | Thash _
  | Tlist _
  | Tset _
  | Tfun _
  | Tarray _
  | Tlazy _
  | Tvolatile _
  | Tsafe _ -> None

let numeric_zero decimal =
  let mantissa =
    match String.index_opt decimal 'e' with
    | Some i -> String.sub decimal 0 i
    | None -> (
        match String.index_opt decimal 'E' with
        | Some i -> String.sub decimal 0 i
        | None -> decimal)
  in
  not
    (String.exists
       (function
         | '1' .. '9' -> true
         | _ -> false)
       mantissa)

let truth budget = function
  | Tpat _ as value -> (
      match number_text value with
      | Some s ->
          spend budget (String.length s);
          not (numeric_zero s)
      | None -> false)
  | Tnull -> false
  | Tbool b -> b
  | Tint n -> n <> 0
  | Tstr s -> s <> ""
  | Tobj xs -> xs <> []
  | Tlist xs | Tset xs -> xs <> []
  | Tfloat _ | Thash _ | Tfun _ | Tarray _ | Tlazy _ | Tvolatile _ | Tsafe _ ->
      fail "Unsupported internal value" "Report this template defect."

let checked_input json =
  let nodes = ref value_node_limit and bytes = ref byte_limit in
  let add_bytes text =
    if String.length text > !bytes then exhausted "input bytes";
    bytes := !bytes - String.length text;
    ignore (fold_utf8 (fun () _ -> ()) () text)
  in
  let rec convert level json =
    depth level;
    if !nodes = 0 then exhausted "input nodes";
    decr nodes;
    match Json.view json with
    | Json.Null -> Tnull
    | Json.Bool b -> Tbool b
    | Json.Number s ->
        add_bytes s;
        exact_number s
    | Json.String s ->
        add_bytes s;
        Tstr s
    | Json.Array xs -> Tlist (List.map (convert (level + 1)) xs)
    | Json.Object xs ->
        Tobj
          (List.map
             (fun (key, value) ->
               add_bytes key;
               (key, convert (level + 1) value))
             xs)
  in
  let value = convert 1 json in
  (value, !bytes, !nodes)

let expected_string name = function
  | Tstr s -> s
  | Tnull
  | Tint _
  | Tbool _
  | Tfloat _
  | Tobj _
  | Thash _
  | Tpat _
  | Tlist _
  | Tset _
  | Tfun _
  | Tarray _
  | Tlazy _
  | Tvolatile _
  | Tsafe _ ->
      fail
        ("Filter " ^ name ^ " requires a string")
        "Use a string value or another filter."

let string_json_size text =
  String.fold_left
    (fun size c ->
      add_size size
        (match c with
        | '"' | '\\' | '\b' | '\012' | '\n' | '\r' | '\t' -> 2
        | '\000' .. '\031' -> 6
        | _ -> 1))
    2 text

let rec json_size = function
  | Tnull -> 4
  | Tbool true -> 4
  | Tbool false -> 5
  | Tint n -> String.length (string_of_int n)
  | Tpat _ as value -> (
      match number_text value with
      | Some s -> String.length s
      | None -> 0)
  | Tstr s -> string_json_size s
  | Tlist xs | Tset xs ->
      let _, size =
        List.fold_left
          (fun (first, size) value ->
            let size = if first then size else add_size size 1 in
            (false, add_size size (json_size value)))
          (true, 2) xs
      in
      size
  | Tobj xs ->
      let _, size =
        List.fold_left
          (fun (first, size) (key, value) ->
            let size = if first then size else add_size size 1 in
            let size = add_size (add_size size (string_json_size key)) 1 in
            (false, add_size size (json_size value)))
          (true, 2) xs
      in
      size
  | Tfloat _ | Thash _ | Tfun _ | Tarray _ | Tlazy _ | Tvolatile _ | Tsafe _ ->
      fail "Unsupported internal JSON value" "Report this template defect."

let rec as_json value =
  let view =
    match value with
    | Tnull -> Json.Null
    | Tbool b -> Json.Bool b
    | Tint n -> Json.Number (string_of_int n)
    | Tpat _ -> (
        match number_text value with
        | Some s -> Json.Number s
        | None -> fail "Invalid internal number" "Report this template defect.")
    | Tstr s -> Json.String s
    | Tlist xs | Tset xs -> Json.Array (List.map as_json xs)
    | Tobj xs ->
        Json.Object (List.map (fun (key, value) -> (key, as_json value)) xs)
    | Tfloat _ | Thash _ | Tfun _ | Tarray _ | Tlazy _ | Tvolatile _ | Tsafe _
      -> fail "Unsupported internal JSON value" "Report this template defect."
  in
  match Json.of_view view with
  | Ok json -> json
  | Error _ ->
      fail "Collection exceeds JSON limits" "Reduce collection size/depth."

let display budget = function
  | Tnull -> ""
  | Tstr s ->
      spend budget (String.length s);
      s
  | Tint n -> string_of_int n
  | Tbool b -> string_of_bool b
  | Tpat _ as value -> (
      match number_text value with
      | Some s ->
          spend budget (String.length s);
          s
      | None -> "")
  | (Tobj _ | Tlist _ | Tset _) as value ->
      let size = json_size value in
      spend budget size;
      Json.encode (as_json value)
  | Tfloat _ | Thash _ | Tfun _ | Tarray _ | Tlazy _ | Tvolatile _ | Tsafe _ ->
      fail "Unsupported output value" "Report this template defect."

let lookup budget reference value key =
  spend budget 1;
  match (value, key) with
  | Tobj entries, Tstr name -> (
      spend budget (List.length entries + String.length name);
      match List.assoc_opt name entries with
      | Some value -> value
      | None ->
          fail
            ("Missing property: " ^ reference ^ "." ^ name)
            "Use a field present in the normalized issue/object.")
  | (Tlist values | Tset values), Tint index -> (
      if index < 0 then
        fail
          ("Invalid index: " ^ reference)
          "Use a nonnegative in-range array index.";
      let length = List.length values in
      spend budget length;
      if index >= length then
        fail
          ("Out-of-range index: " ^ reference)
          "Use an index present in the array.";
      spend budget (index + 1);
      match List.nth_opt values index with
      | Some value -> value
      | None ->
          fail
            ("Out-of-range index: " ^ reference)
            "Use an index present in the array.")
  | ( ( Tnull
      | Tint _
      | Tbool _
      | Tfloat _
      | Tstr _
      | Tobj _
      | Thash _
      | Tpat _
      | Tlist _
      | Tset _
      | Tfun _
      | Tarray _
      | Tlazy _
      | Tvolatile _
      | Tsafe _ ),
      ( Tnull
      | Tint _
      | Tbool _
      | Tfloat _
      | Tstr _
      | Tobj _
      | Thash _
      | Tpat _
      | Tlist _
      | Tset _
      | Tfun _
      | Tarray _
      | Tlazy _
      | Tvolatile _
      | Tsafe _ ) ) ->
      fail
        ("Invalid field/index access: " ^ reference)
        "Access object fields or integer array indexes; do not access beneath \
         null/scalars."

let decimal_parts budget text =
  (* Checked JSON/integer literals establish decimal syntax. The nonzero branch
     keeps both offsets in range; Stdlib string indexes carry no bounds proof. *)
  let length = String.length text in
  product budget length length;
  let negative = String.starts_with ~prefix:"-" text in
  let unsigned = if negative then String.sub text 1 (length - 1) else text in
  let mantissa, exponent =
    let split = String.split_on_char 'e' (String.lowercase_ascii unsigned) in
    match split with
    | [ mantissa ] -> (mantissa, Z.zero)
    | [ mantissa; exponent ] -> (mantissa, Z.of_string exponent)
    | [] | _ :: _ ->
        fail "Invalid internal numeral" "Report this template defect."
  in
  let whole, fraction =
    match String.split_on_char '.' mantissa with
    | [ whole ] -> (whole, "")
    | [ whole; fraction ] -> (whole, fraction)
    | [] | _ :: _ ->
        fail "Invalid internal numeral" "Report this template defect."
  in
  let digits = whole ^ fraction in
  let rec leading index =
    if index = String.length digits || String.get digits index <> '0' then index
    else leading (index + 1)
  in
  let first = leading 0 in
  if first = String.length digits then (0, Z.zero, "")
  else
    let rec trailing index =
      if String.get digits index <> '0' then index + 1 else trailing (index - 1)
    in
    let ending = trailing (String.length digits - 1) in
    let place =
      Z.add exponent
        (Z.of_int (String.length digits - first - String.length fraction))
    in
    ( (if negative then -1 else 1),
      place,
      String.sub digits first (ending - first) )

let numeric_compare budget left right =
  let ls, lp, ld = decimal_parts budget left in
  let rs, rp, rd = decimal_parts budget right in
  let sign = Int.compare ls rs in
  if sign <> 0 then sign
  else if ls = 0 then 0
  else
    let place = Z.compare lp rp in
    ls * if place <> 0 then place else String.compare ld rd

let compare_values budget left right =
  match (number_text left, number_text right) with
  | Some a, Some b -> numeric_compare budget a b
  | Some _, None | None, Some _ ->
      fail "Cannot order a number and a non-number"
        "Compare numbers with numeric values; compare strings with strings."
  | None, None -> (
      match (left, right) with
      | Tstr a, Tstr b ->
          spend budget (String.length a + String.length b);
          String.compare a b
      | Tbool a, Tbool b -> Bool.compare a b
      | ( ( Tnull
          | Tint _
          | Tbool _
          | Tfloat _
          | Tstr _
          | Tobj _
          | Thash _
          | Tpat _
          | Tlist _
          | Tset _
          | Tfun _
          | Tarray _
          | Tlazy _
          | Tvolatile _
          | Tsafe _ ),
          ( Tnull
          | Tint _
          | Tbool _
          | Tfloat _
          | Tstr _
          | Tobj _
          | Thash _
          | Tpat _
          | Tlist _
          | Tset _
          | Tfun _
          | Tarray _
          | Tlazy _
          | Tvolatile _
          | Tsafe _ ) ) ->
          fail "Unsupported ordered comparison"
            "Order numbers, strings, or booleans of the same kind.")

let rec equal_values budget left right =
  spend budget 1;
  match (number_text left, number_text right) with
  | Some a, Some b -> numeric_compare budget a b = 0
  | Some _, None | None, Some _ -> false
  | None, None -> (
      match (left, right) with
      | Tnull, Tnull -> true
      | Tbool a, Tbool b -> a = b
      | Tstr a, Tstr b ->
          spend budget (String.length a + String.length b);
          String.equal a b
      | (Tlist a | Tset a), (Tlist b | Tset b) -> equal_lists budget a b
      | Tobj a, Tobj b ->
          List.length a = List.length b
          && List.for_all
               (fun (name, value) ->
                 spend budget (List.length b + String.length name);
                 match List.assoc_opt name b with
                 | Some other -> equal_values budget value other
                 | None -> false)
               a
      | ( ( Tnull
          | Tint _
          | Tbool _
          | Tfloat _
          | Tstr _
          | Tobj _
          | Thash _
          | Tpat _
          | Tlist _
          | Tset _
          | Tfun _
          | Tarray _
          | Tlazy _
          | Tvolatile _
          | Tsafe _ ),
          ( Tnull
          | Tint _
          | Tbool _
          | Tfloat _
          | Tstr _
          | Tobj _
          | Thash _
          | Tpat _
          | Tlist _
          | Tset _
          | Tfun _
          | Tarray _
          | Tlazy _
          | Tvolatile _
          | Tsafe _ ) ) -> false)

and equal_lists budget left right =
  match (left, right) with
  | [], [] -> true
  | x :: xs, y :: ys -> equal_values budget x y && equal_lists budget xs ys
  | [], _ :: _ | _ :: _, [] -> false

let literal_replace budget old replacement text =
  spend budget (String.length replacement);
  if old = "" then (
    let count = fold_utf8 (fun n _ -> n + 1) 1 text in
    if String.length replacement > byte_limit / count then
      exhausted "string/output bytes";
    let size =
      add_size (String.length text) (count * String.length replacement)
    in
    spend budget size;
    let output = Buffer.create size in
    Buffer.add_string output replacement;
    ignore
      (fold_utf8
         (fun () uchar ->
           Buffer.add_utf_8_uchar output uchar;
           Buffer.add_string output replacement)
         () text);
    Buffer.contents output)
  else (
    product budget (String.length text + 1) (String.length old);
    let regexp = Re.compile (Re.str old) in
    let count = Seq.fold_left (fun n _ -> n + 1) 0 (Re.Seq.all regexp text) in
    if count <> 0 && String.length replacement > byte_limit / count then
      exhausted "string/output bytes";
    let size =
      add_size
        (String.length text - (count * String.length old))
        (count * String.length replacement)
    in
    spend budget size;
    Re.replace_string regexp ~by:replacement text)

let map_case budget name mapping engine value =
  let text = expected_string name value in
  spend budget (String.length text);
  let size = mapped_size mapping text in
  spend budget size;
  engine value

let apply_filter budget name args =
  let selected, _ = filter name in
  let invalid () =
    fail
      ("Invalid input for filter " ^ name)
      "Use the documented filter value and argument types."
  in
  let unary fn =
    match args with
    | [ value ] -> fn value
    | [] | _ :: _ -> invalid ()
  in
  let binary fn =
    match args with
    | [ a; b ] -> fn a b
    | [] | _ :: _ -> invalid ()
  in
  let ternary fn =
    match args with
    | [ a; b; c ] -> fn a b c
    | [] | _ :: _ -> invalid ()
  in
  match selected with
  | Length ->
      unary (function
        | Tobj entries ->
            let length = List.length entries in
            spend budget length;
            Tint length
        | Tstr text as value ->
            spend budget (String.length text);
            Runtime.jg_length value
        | Tlist values | Tset values ->
            let length = List.length values in
            spend budget length;
            Tint length
        | Tnull
        | Tint _
        | Tbool _
        | Tfloat _
        | Thash _
        | Tpat _
        | Tfun _
        | Tarray _
        | Tlazy _
        | Tvolatile _
        | Tsafe _ -> invalid ())
  | Join ->
      binary (fun separator value ->
          let values =
            match value with
            | Tlist values | Tset values -> values
            | Tnull
            | Tint _
            | Tbool _
            | Tfloat _
            | Tstr _
            | Tobj _
            | Thash _
            | Tpat _
            | Tfun _
            | Tarray _
            | Tlazy _
            | Tvolatile _
            | Tsafe _ -> invalid ()
          in
          let separator = expected_string name separator in
          let values = List.map (display budget) values in
          let _, size =
            List.fold_left
              (fun (first, size) text ->
                let size =
                  if first then size
                  else add_size size (String.length separator)
                in
                (false, add_size size (String.length text)))
              (true, 0) values
          in
          spend budget size;
          Runtime.jg_join (Tstr separator)
            (Tlist (List.map (fun s -> Tstr s) values)))
  | Lower ->
      unary (map_case budget name Uucp.Case.Map.to_lower Runtime.jg_lower)
  | Upper ->
      unary (map_case budget name Uucp.Case.Map.to_upper Runtime.jg_upper)
  | Trim ->
      unary (fun value ->
          let text = expected_string name value in
          spend budget (String.length text);
          Runtime.jg_trim value)
  | Replace ->
      ternary (fun old replacement value ->
          Tstr
            (literal_replace budget (expected_string name old)
               (expected_string name replacement)
               (expected_string name value)))
  | Default -> binary Runtime.jg_default

let negative_literal = function
  | Tint n -> Tint (-n)
  | Tnull
  | Tbool _
  | Tfloat _
  | Tstr _
  | Tobj _
  | Thash _
  | Tpat _
  | Tlist _
  | Tset _
  | Tfun _
  | Tarray _
  | Tlazy _
  | Tvolatile _
  | Tsafe _ ->
      fail "Invalid compiled negative literal" "Report this template defect."

let call1 fn arg = ApplyExpr (LiteralExpr (func_arg1_no_kw fn), [ (None, arg) ])

let call2 fn left right =
  ApplyExpr (LiteralExpr (func_arg2_no_kw fn), [ (None, left); (None, right) ])

let rec reference = function
  | IdentExpr name -> name
  | DotExpr (value, key) -> reference value ^ "." ^ key
  | BracketExpr (value, _) -> reference value ^ "[index]"
  | LiteralExpr _
  | NotOpExpr _
  | NegativeOpExpr _
  | PlusOpExpr _
  | MinusOpExpr _
  | TimesOpExpr _
  | PowerOpExpr _
  | DivOpExpr _
  | ModOpExpr _
  | AndOpExpr _
  | OrOpExpr _
  | NotEqOpExpr _
  | EqEqOpExpr _
  | LtOpExpr _
  | GtOpExpr _
  | LtEqOpExpr _
  | GtEqOpExpr _
  | ApplyExpr _
  | ListExpr _
  | SetExpr _
  | ObjExpr _
  | TestOpExpr _
  | InOpExpr _
  | FunctionExpression _
  | TernaryOpExpr _ -> "expression"

let rewrite budget roots ast =
  let serial = ref 0 in
  let guard =
    ExpandStatement
      (call1
         (fun _ ->
           spend budget 1;
           Tnull)
         (LiteralExpr Tnull))
  in
  let truth_expr expr = call1 (fun value -> Tbool (truth budget value)) expr in
  let rec expression bindings expr =
    let child = expression bindings in
    let rewritten =
      match expr with
      | IdentExpr name -> (
          match List.assoc_opt name bindings with
          | Some private_name -> IdentExpr private_name
          | None ->
              call1
                (fun _ ->
                  match List.assoc_opt name roots with
                  | Some value -> value
                  | None ->
                      fail
                        ("Missing variable: " ^ name)
                        "Use issue, attempt, or a lexically bound loop \
                         variable.")
                (LiteralExpr Tnull))
      | LiteralExpr value -> LiteralExpr value
      | NegativeOpExpr (LiteralExpr value) ->
          LiteralExpr (negative_literal value)
      | DotExpr (value, key) ->
          call2
            (lookup budget (reference value))
            (child value) (LiteralExpr (Tstr key))
      | BracketExpr (value, key) ->
          let key = child key in
          let key =
            call1
              (fun value ->
                match number_text value with
                | None -> value
                | Some text -> (
                    match int_of_string_opt text with
                    | Some index -> Tint index
                    | None ->
                        fail "Array index is not a bounded integer"
                          "Use a nonnegative in-range integer index."))
              key
          in
          call2 (lookup budget (reference value)) (child value) key
      | NotOpExpr e -> NotOpExpr (truth_expr (child e))
      | AndOpExpr (a, b) ->
          AndOpExpr (truth_expr (child a), truth_expr (child b))
      | OrOpExpr (a, b) -> OrOpExpr (truth_expr (child a), truth_expr (child b))
      | EqEqOpExpr (a, b) ->
          call2 (fun a b -> Tbool (equal_values budget a b)) (child a) (child b)
      | NotEqOpExpr (a, b) ->
          call2
            (fun a b -> Tbool (not (equal_values budget a b)))
            (child a) (child b)
      | LtOpExpr (a, b) -> ordered bindings (fun n -> n < 0) a b
      | GtOpExpr (a, b) -> ordered bindings (fun n -> n > 0) a b
      | LtEqOpExpr (a, b) -> ordered bindings (fun n -> n <= 0) a b
      | GtEqOpExpr (a, b) -> ordered bindings (fun n -> n >= 0) a b
      | InOpExpr (a, b) ->
          call2
            (fun value collection ->
              match collection with
              | Tlist xs | Tset xs ->
                  Tbool (List.exists (equal_values budget value) xs)
              | Tobj xs ->
                  let key = expected_string "membership" value in
                  spend budget (List.length xs + String.length key);
                  Tbool (List.mem_assoc key xs)
              | Tnull
              | Tint _
              | Tbool _
              | Tfloat _
              | Tstr _
              | Thash _
              | Tpat _
              | Tfun _
              | Tarray _
              | Tlazy _
              | Tvolatile _
              | Tsafe _ ->
                  fail "Membership requires an array/map"
                    "Use an array or map on the right of in.")
            (child a) (child b)
      | ApplyExpr _ ->
          let name, args = application [] expr in
          let args = List.map (fun (_, e) -> (None, child e)) args in
          ApplyExpr
            ( LiteralExpr
                (func_no_kw (apply_filter budget name) (List.length args)),
              args )
      | ListExpr xs -> ListExpr (List.map child xs)
      | SetExpr xs -> SetExpr (List.map child xs)
      | ObjExpr xs -> ObjExpr (List.map (fun (key, e) -> (key, child e)) xs)
      | TernaryOpExpr (condition, yes, no) ->
          TernaryOpExpr (truth_expr (child condition), child yes, child no)
      | NegativeOpExpr _
      | PlusOpExpr _
      | MinusOpExpr _
      | TimesOpExpr _
      | PowerOpExpr _
      | DivOpExpr _
      | ModOpExpr _
      | TestOpExpr _
      | FunctionExpression _ ->
          fail "Invalid compiled expression" "Report this template defect."
    in
    call1
      (fun value ->
        spend budget 1;
        value)
      rewritten
  and ordered bindings relation a b =
    call2
      (fun a b -> Tbool (relation (compare_values budget a b)))
      (expression bindings a) (expression bindings b)
  and statements bindings ast = List.concat_map (statement bindings) ast
  and statement bindings stmt =
    let rewritten =
      match stmt with
      | TextStatement text -> TextStatement text
      | ExpandStatement expr -> ExpandStatement (expression bindings expr)
      | IfStatement branches ->
          IfStatement
            (List.map
               (fun (condition, body) ->
                 ( Option.map
                     (fun e -> truth_expr (expression bindings e))
                     condition,
                   statements bindings body ))
               branches)
      | ForStatement (names, iterable, body) ->
          let aliases =
            List.map
              (fun name ->
                let private_name =
                  "__symphony_bound_" ^ string_of_int !serial
                in
                incr serial;
                (name, private_name))
              names
          in
          let arity = List.length names in
          let iterable =
            call1
              (fun value ->
                match (arity, value) with
                | 1, (Tlist _ | Tset _) -> value
                | 1, Tobj xs -> Tlist (List.map (fun (key, _) -> Tstr key) xs)
                | 2, Tobj _ -> value
                | ( _,
                    ( Tnull
                    | Tint _
                    | Tbool _
                    | Tfloat _
                    | Tstr _
                    | Tobj _
                    | Thash _
                    | Tpat _
                    | Tlist _
                    | Tset _
                    | Tfun _
                    | Tarray _
                    | Tlazy _
                    | Tvolatile _
                    | Tsafe _ ) ) ->
                    fail "Invalid loop input/bindings"
                      "Use one binding for arrays/keys, two bindings for map \
                       key/value pairs.")
              (expression bindings iterable)
          in
          ForStatement
            ( List.map snd aliases,
              iterable,
              guard :: statements (aliases @ bindings) body )
      | IncludeStatement _
      | RawIncludeStatement _
      | ExtendsStatement _
      | ImportStatement _
      | FromImportStatement _
      | SetStatement _
      | SetBlockStatement _
      | BlockStatement _
      | MacroStatement _
      | FilterStatement _
      | CallStatement _
      | WithStatement _
      | AutoEscapeStatement _
      | NamespaceStatement _
      | Statements _
      | FunctionStatement _
      | SwitchStatement _ ->
          fail "Invalid compiled statement" "Report this template defect."
    in
    [ guard; rewritten ]
  in
  statements [] ast

let render template ~issue ~attempt =
  let error message remedy =
    Error (Render_error (diagnostic template.file message remedy))
  in
  try
    let budget = { remaining = work_limit } in
    let issue, available_bytes, available_nodes =
      checked_input (Issue.to_json issue)
    in
    if available_nodes = 0 then exhausted "input nodes";
    let attempt =
      match attempt with
      | First -> Tnull
      | Follow_up count -> (
          match
            Count.decimal_bounded ~max_bytes:available_bytes
              (Positive_count.count count)
          with
          | Ok decimal -> exact_number decimal
          | Error _ -> exhausted "input bytes")
    in
    let ast =
      rewrite budget [ ("issue", issue); ("attempt", attempt) ] template.ast
    in
    let buffer = Buffer.create 256 in
    let output value =
      let text = display budget value in
      ignore (add_size (Buffer.length buffer) (String.length text));
      Buffer.add_string buffer text
    in
    (* Construct the context directly: init_context adds open default helpers and
       can load extensions. Validated ASTs cannot reach any loader or callable. *)
    let context =
      {
        frame_stack = [];
        macro_table = Hashtbl.create 0;
        namespace_table = Hashtbl.create 0;
        active_filters = [];
        serialize = false;
        output;
      }
    in
    let environment =
      {
        autoescape = false;
        strict_mode = true;
        template_dirs = [];
        filters = [];
        extensions = [];
      }
    in
    ignore (List.fold_left (Interp.eval_statement environment) context ast);
    Ok (Buffer.contents buffer)
  with
  | Boundary (message, remedy) -> error message remedy
  | Failure _ | Invalid_argument _ | Not_found ->
      error "Template engine rejected a value"
        "Use the documented value/filter types."
  | Stack_overflow ->
      error "Template rendering depth exceeded" "Reduce template/input nesting."
