open Parsetree
open Location
open Ast_iterator
module Names = Map.Make (String)
module Name_set = Set.Make (String)

type origin = Known of string list | Members of origin Names.t | Unknown
type scope = { modules : origin Names.t; values : string list Names.t }
type source = Impl of structure | Intf of signature
type finding = { file : string; line : int; column : int; message : string }
type mode = Scan | Self_test | Limits

type fixture =
  | Paired of string * string
  | Ml_only of string
  | Mli_only of string
  | No_files
  | Missing_root

type expectation = Accept | Reject of string

let empty = { modules = Names.empty; values = Names.empty }
let forbidden = [ "Obj"; "Str"; "Lwt"; "Async" ]
let ignored = [ "_opam"; "_build"; "vendor"; ".git" ]
let directories = [ "lib"; "bin"; "test"; "fuzz"; "tools" ]

let standard = function
  | "Stdlib" :: rest -> rest
  | path -> path

let partials = function
  | [ "List" ] -> [ "hd"; "tl"; "nth"; "assoc"; "assq"; "find" ]
  | [ "Option" ] -> [ "get" ]
  | [ "Map" ] | [ "Set" ] | [ "Hashtbl" ] -> [ "find" ]
  | [ "Queue" ] -> [ "take"; "peek" ]
  | [ "Stack" ] -> [ "pop"; "top" ]
  | _ -> []

let rec parts = function
  | Longident.Lident name -> [ name ]
  | Longident.Ldot (parent, name) -> parts parent.txt @ [ name.txt ]
  | Longident.Lapply (fn, arg) -> parts fn.txt @ parts arg.txt

let rec descend origin = function
  | [] -> origin
  | name :: rest ->
      let next =
        match origin with
        | Known path -> Known (path @ [ name ])
        | Members members ->
            Option.value ~default:Unknown (Names.find_opt name members)
        | Unknown -> Unknown
      in
      descend next rest

let resolve scope = function
  | [] -> Unknown
  | first :: rest ->
      descend
        (Option.value ~default:(Known [ first ])
           (Names.find_opt first scope.modules))
        rest

let bind scope name origin =
  match name with
  | None -> scope
  | Some name -> { scope with modules = Names.add name origin scope.modules }

let shadow scope pattern =
  let bound = ref Name_set.empty in
  let iterator =
    {
      Ast_iterator.default_iterator with
      pat =
        (fun self pattern ->
          (match pattern.ppat_desc with
          | Ppat_var name | Ppat_alias (_, name) ->
              bound := Name_set.add name.txt !bound
          | Ppat_any
          | Ppat_constant _
          | Ppat_interval _
          | Ppat_tuple _
          | Ppat_construct _
          | Ppat_variant _
          | Ppat_record _
          | Ppat_array _
          | Ppat_or _
          | Ppat_constraint _
          | Ppat_type _
          | Ppat_lazy _
          | Ppat_unpack _
          | Ppat_exception _
          | Ppat_effect _
          | Ppat_extension _
          | Ppat_open _ -> ());
          Ast_iterator.default_iterator.pat self pattern);
    }
  in
  iterator.pat iterator pattern;
  { scope with values = Name_set.fold Names.remove !bound scope.values }

let shadow_bindings scope bindings =
  List.fold_left
    (fun scope binding -> shadow scope binding.pvb_pat)
    scope bindings

let opened scope = function
  | Known path ->
      let path = standard path in
      let values =
        List.fold_left
          (fun values name -> Names.add name (path @ [ name ]) values)
          scope.values (partials path)
      in
      { scope with values }
  | Members members ->
      {
        scope with
        modules =
          Names.union (fun _ _ incoming -> Some incoming) scope.modules members;
      }
  | Unknown -> { scope with values = Names.empty }

let exported scope exports name =
  match name with
  | None -> exports
  | Some name -> (
      match Names.find_opt name scope.modules with
      | None -> exports
      | Some origin -> Names.add name origin exports)

let rec module_origin scope expression =
  match expression.pmod_desc with
  | Pmod_ident name -> resolve scope (parts name.txt)
  | Pmod_structure items -> Members (structure_exports scope items)
  | Pmod_apply (fn, _) -> (
      match module_origin scope fn with
      | Known path -> (
          match standard path with
          | [ "Map"; "Make" ] -> Known [ "Map" ]
          | [ "Set"; "Make" ] -> Known [ "Set" ]
          | _ -> Unknown)
      | Members _ as origin -> origin
      | Unknown -> Unknown)
  | Pmod_constraint (body, signature) -> (
      match type_origin scope signature with
      | Known path when partials (standard path) <> [] -> Known path
      | (Known _ | Members _ | Unknown) as declared -> (
          match module_origin scope body with
          | Unknown -> declared
          | (Known _ | Members _) as origin -> origin))
  | Pmod_functor (parameter, body) ->
      module_origin (parameter_scope scope parameter) body
  | Pmod_apply_unit _ | Pmod_unpack _ | Pmod_extension _ -> Unknown

and type_origin scope signature =
  match signature.pmty_desc with
  | Pmty_ident name | Pmty_alias name -> (
      match resolve scope (parts name.txt) with
      | Known path -> (
          match standard path with
          | [ "Map"; "S" ] -> Known [ "Map" ]
          | [ "Set"; "S" ] -> Known [ "Set" ]
          | _ -> Known path)
      | (Members _ | Unknown) as origin -> origin)
  | Pmty_signature items -> Members (signature_exports scope items)
  | Pmty_with (base, _) -> type_origin scope base
  | Pmty_typeof expression -> module_origin scope expression
  | Pmty_functor (parameter, body) ->
      type_origin (parameter_scope scope parameter) body
  | Pmty_extension _ -> Unknown

and parameter_scope scope = function
  | Unit -> scope
  | Named (name, signature) -> bind scope name.txt (type_origin scope signature)

and structure_exports scope items =
  let _, exports =
    List.fold_left
      (fun (scope, exports) item ->
        let next = update scope item in
        let exports =
          match item.pstr_desc with
          | Pstr_module binding -> exported next exports binding.pmb_name.txt
          | Pstr_recmodule bindings ->
              List.fold_left
                (fun exports binding ->
                  exported next exports binding.pmb_name.txt)
                exports bindings
          | Pstr_include declaration -> (
              match module_origin scope declaration.pincl_mod with
              | Members members ->
                  Names.union
                    (fun _ _ incoming -> Some incoming)
                    exports members
              | Known _ | Unknown -> exports)
          | Pstr_eval _
          | Pstr_value _
          | Pstr_primitive _
          | Pstr_type _
          | Pstr_typext _
          | Pstr_exception _
          | Pstr_modtype _
          | Pstr_open _
          | Pstr_class _
          | Pstr_class_type _
          | Pstr_attribute _
          | Pstr_extension _ -> exports
        in
        (next, exports))
      (scope, Names.empty) items
  in
  exports

and signature_exports scope items =
  let _, exports =
    List.fold_left
      (fun (scope, exports) item ->
        let next = update_sig scope item in
        let exports =
          match item.psig_desc with
          | Psig_module declaration ->
              exported next exports declaration.pmd_name.txt
          | Psig_recmodule declarations ->
              List.fold_left
                (fun exports declaration ->
                  exported next exports declaration.pmd_name.txt)
                exports declarations
          | Psig_include declaration -> (
              match type_origin scope declaration.pincl_mod with
              | Members members ->
                  Names.union
                    (fun _ _ incoming -> Some incoming)
                    exports members
              | Known _ | Unknown -> exports)
          | Psig_value _
          | Psig_type _
          | Psig_typesubst _
          | Psig_typext _
          | Psig_exception _
          | Psig_modsubst _
          | Psig_modtype _
          | Psig_modtypesubst _
          | Psig_open _
          | Psig_class _
          | Psig_class_type _
          | Psig_attribute _
          | Psig_extension _ -> exports
        in
        (next, exports))
      (scope, Names.empty) items
  in
  exports

and update scope item =
  match item.pstr_desc with
  | Pstr_module binding ->
      bind scope binding.pmb_name.txt (module_origin scope binding.pmb_expr)
  | Pstr_recmodule bindings ->
      List.fold_left
        (fun scope binding ->
          bind scope binding.pmb_name.txt (module_origin scope binding.pmb_expr))
        scope bindings
  | Pstr_open declaration ->
      opened scope (module_origin scope declaration.popen_expr)
  | Pstr_include declaration ->
      opened scope (module_origin scope declaration.pincl_mod)
  | Pstr_value (_, bindings) -> shadow_bindings scope bindings
  | Pstr_primitive declaration ->
      {
        scope with
        values = Names.remove declaration.pval_name.txt scope.values;
      }
  | Pstr_eval _
  | Pstr_type _
  | Pstr_typext _
  | Pstr_exception _
  | Pstr_modtype _
  | Pstr_class _
  | Pstr_class_type _
  | Pstr_attribute _
  | Pstr_extension _ -> scope

and update_sig scope item =
  match item.psig_desc with
  | Psig_module declaration ->
      bind scope declaration.pmd_name.txt
        (type_origin scope declaration.pmd_type)
  | Psig_recmodule declarations ->
      List.fold_left
        (fun scope declaration ->
          bind scope declaration.pmd_name.txt
            (type_origin scope declaration.pmd_type))
        scope declarations
  | Psig_modsubst declaration ->
      bind scope (Some declaration.pms_name.txt)
        (resolve scope (parts declaration.pms_manifest.txt))
  | Psig_open declaration ->
      opened scope (resolve scope (parts declaration.popen_expr.txt))
  | Psig_include declaration ->
      opened scope (type_origin scope declaration.pincl_mod)
  | Psig_value _
  | Psig_type _
  | Psig_typesubst _
  | Psig_typext _
  | Psig_exception _
  | Psig_modtype _
  | Psig_modtypesubst _
  | Psig_class _
  | Psig_class_type _
  | Psig_attribute _
  | Psig_extension _ -> scope

let lint world file source =
  let findings = ref [] in
  let report location message =
    let position = location.Location.loc_start in
    findings :=
      {
        file;
        line = position.Lexing.pos_lnum;
        column = position.Lexing.pos_cnum - position.Lexing.pos_bol + 1;
        message;
      }
      :: !findings
  in
  let check_modules scope location path =
    let literal = parts path in
    let names =
      match resolve scope literal with
      | Known names -> literal @ names
      | Members _ | Unknown -> literal
    in
    List.iter
      (fun name ->
        if List.mem name forbidden then
          report location ("forbidden module " ^ name))
      (List.sort_uniq String.compare names)
  in
  let check_call scope location path =
    let target =
      match path with
      | Longident.Lident name -> Names.find_opt name scope.values
      | Longident.Ldot (parent, name) -> (
          check_modules scope location parent.txt;
          match resolve scope (parts parent.txt) with
          | Known origin -> Some (standard origin @ [ name.txt ])
          | Members _ | Unknown -> None)
      | Longident.Lapply (fn, arg) ->
          check_modules scope location fn.txt;
          check_modules scope location arg.txt;
          None
    in
    match target with
    | Some target -> (
        match List.rev target with
        | name :: parent ->
            if List.mem name (partials (List.rev parent)) then
              report location
                ("partial operation " ^ String.concat "." target
               ^ "; use a checked/result-valued operation")
        | [] -> ())
    | None -> ()
  in
  let check_member scope location = function
    | Longident.Ldot (parent, _) -> check_modules scope location parent.txt
    | Longident.Lapply (fn, arg) ->
        check_modules scope location fn.txt;
        check_modules scope location arg.txt
    | Longident.Lident _ -> ()
  in
  let rec iterator scope =
    {
      Ast_iterator.default_iterator with
      structure =
        (fun _ items ->
          ignore
            (List.fold_left
               (fun scope item ->
                 let self = iterator scope in
                 self.structure_item self item;
                 update scope item)
               scope items));
      signature =
        (fun _ items ->
          ignore
            (List.fold_left
               (fun scope item ->
                 let self = iterator scope in
                 self.signature_item self item;
                 update_sig scope item)
               scope items));
      structure_item =
        (fun self item ->
          match item.pstr_desc with
          | Pstr_value (Asttypes.Recursive, bindings) ->
              let child = iterator (shadow_bindings scope bindings) in
              Ast_iterator.default_iterator.structure_item child item
          | Pstr_value (Asttypes.Nonrecursive, _)
          | Pstr_eval _
          | Pstr_primitive _
          | Pstr_type _
          | Pstr_typext _
          | Pstr_exception _
          | Pstr_module _
          | Pstr_recmodule _
          | Pstr_modtype _
          | Pstr_open _
          | Pstr_class _
          | Pstr_class_type _
          | Pstr_include _
          | Pstr_attribute _
          | Pstr_extension _ ->
              Ast_iterator.default_iterator.structure_item self item);
      expr =
        (fun self expression ->
          let default () = Ast_iterator.default_iterator.expr self expression in
          match expression.pexp_desc with
          | Pexp_ident name ->
              check_call scope name.loc name.txt;
              default ()
          | Pexp_struct_item (item, body) ->
              self.structure_item self item;
              let child = iterator (update scope item) in
              child.expr child body;
              self.attributes self expression.pexp_attributes
          | Pexp_for (pattern, start, stop, _, body) ->
              self.pat self pattern;
              self.expr self start;
              self.expr self stop;
              let child = iterator (shadow scope pattern) in
              child.expr child body;
              self.attributes self expression.pexp_attributes
          | Pexp_letop operators ->
              let bindings = operators.let_ :: operators.ands in
              List.iter (self.binding_op self) bindings;
              let body_scope =
                List.fold_left
                  (fun scope binding -> shadow scope binding.pbop_pat)
                  scope bindings
              in
              let child = iterator body_scope in
              child.expr child operators.body;
              self.attributes self expression.pexp_attributes
          | Pexp_let (recursive, bindings, body) ->
              let body_scope = shadow_bindings scope bindings in
              let rhs =
                iterator
                  (match recursive with
                  | Asttypes.Recursive -> body_scope
                  | Asttypes.Nonrecursive -> scope)
              in
              List.iter (rhs.value_binding rhs) bindings;
              let child = iterator body_scope in
              child.expr child body;
              self.attributes self expression.pexp_attributes
          | Pexp_function (parameters, constraint_, body) ->
              let body_scope =
                List.fold_left
                  (fun scope parameter ->
                    match parameter.pparam_desc with
                    | Pparam_newtype _ -> scope
                    | Pparam_val (_, default, pattern) ->
                        let self = iterator scope in
                        Option.iter (self.expr self) default;
                        self.pat self pattern;
                        shadow scope pattern)
                  scope parameters
              in
              let child = iterator body_scope in
              Option.iter
                (function
                  | Pconstraint typ -> child.typ child typ
                  | Pcoerce (ground, typ) ->
                      Option.iter (child.typ child) ground;
                      child.typ child typ)
                constraint_;
              (match body with
              | Pfunction_body body -> child.expr child body
              | Pfunction_cases (cases, _, attributes) ->
                  child.cases child cases;
                  child.attributes child attributes);
              self.attributes self expression.pexp_attributes
          | Pexp_object _
          | Pexp_send _
          | Pexp_new _
          | Pexp_override _
          | Pexp_setinstvar _ ->
              report expression.pexp_loc "object/class syntax is forbidden";
              default ()
          | Pexp_construct (name, _)
          | Pexp_field (_, name)
          | Pexp_setfield (_, name, _) ->
              check_member scope name.loc name.txt;
              default ()
          | Pexp_record (fields, _) ->
              List.iter
                (fun (name, _) -> check_member scope name.loc name.txt)
                fields;
              default ()
          | Pexp_constant _
          | Pexp_apply _
          | Pexp_match _
          | Pexp_try _
          | Pexp_tuple _
          | Pexp_variant _
          | Pexp_array _
          | Pexp_ifthenelse _
          | Pexp_sequence _
          | Pexp_while _
          | Pexp_constraint _
          | Pexp_coerce _
          | Pexp_assert _
          | Pexp_lazy _
          | Pexp_poly _
          | Pexp_newtype _
          | Pexp_pack _
          | Pexp_extension _
          | Pexp_unreachable -> default ());
      case =
        (fun self case ->
          self.pat self case.pc_lhs;
          let child = iterator (shadow scope case.pc_lhs) in
          Option.iter (child.expr child) case.pc_guard;
          child.expr child case.pc_rhs);
      pat =
        (fun self pattern ->
          (match pattern.ppat_desc with
          | Ppat_construct (name, _) | Ppat_type name ->
              check_member scope name.loc name.txt
          | Ppat_record (fields, _) ->
              List.iter
                (fun (name, _) -> check_member scope name.loc name.txt)
                fields
          | Ppat_open (name, _) -> check_modules scope name.loc name.txt
          | Ppat_any
          | Ppat_var _
          | Ppat_alias _
          | Ppat_constant _
          | Ppat_interval _
          | Ppat_tuple _
          | Ppat_variant _
          | Ppat_array _
          | Ppat_or _
          | Ppat_constraint _
          | Ppat_lazy _
          | Ppat_unpack _
          | Ppat_exception _
          | Ppat_effect _
          | Ppat_extension _ -> ());
          Ast_iterator.default_iterator.pat self pattern);
      module_expr =
        (fun self expression ->
          match expression.pmod_desc with
          | Pmod_ident name ->
              check_modules scope name.loc name.txt;
              Ast_iterator.default_iterator.module_expr self expression
          | Pmod_functor (parameter, body) ->
              (match parameter with
              | Unit -> ()
              | Named (_, signature) -> self.module_type self signature);
              let child = iterator (parameter_scope scope parameter) in
              child.module_expr child body;
              self.attributes self expression.pmod_attributes
          | Pmod_structure _
          | Pmod_apply _
          | Pmod_apply_unit _
          | Pmod_constraint _
          | Pmod_unpack _
          | Pmod_extension _ ->
              Ast_iterator.default_iterator.module_expr self expression);
      module_type =
        (fun self signature ->
          match signature.pmty_desc with
          | Pmty_ident name | Pmty_alias name ->
              check_modules scope name.loc name.txt;
              Ast_iterator.default_iterator.module_type self signature
          | Pmty_functor (parameter, body) ->
              (match parameter with
              | Unit -> ()
              | Named (_, signature) -> self.module_type self signature);
              let child = iterator (parameter_scope scope parameter) in
              child.module_type child body;
              self.attributes self signature.pmty_attributes
          | Pmty_signature _ | Pmty_with _ | Pmty_typeof _ | Pmty_extension _ ->
              Ast_iterator.default_iterator.module_type self signature);
      module_substitution =
        (fun self substitution ->
          check_modules scope substitution.pms_manifest.loc
            substitution.pms_manifest.txt;
          Ast_iterator.default_iterator.module_substitution self substitution);
      open_description =
        (fun self declaration ->
          check_modules scope declaration.popen_expr.loc
            declaration.popen_expr.txt;
          Ast_iterator.default_iterator.open_description self declaration);
      typ =
        (fun self typ ->
          (match typ.ptyp_desc with
          | Ptyp_object _ | Ptyp_class _ ->
              report typ.ptyp_loc "object/class type is forbidden"
          | Ptyp_constr (name, _) -> check_member scope name.loc name.txt
          | Ptyp_open (name, _) -> check_modules scope name.loc name.txt
          | Ptyp_any
          | Ptyp_var _
          | Ptyp_arrow _
          | Ptyp_tuple _
          | Ptyp_alias _
          | Ptyp_variant _
          | Ptyp_poly _
          | Ptyp_package _
          | Ptyp_extension _
          | Ptyp_functor _ -> ());
          Ast_iterator.default_iterator.typ self typ);
      extension_constructor =
        (fun self constructor ->
          (match constructor.pext_kind with
          | Pext_rebind name -> check_member scope name.loc name.txt
          | Pext_decl _ -> ());
          Ast_iterator.default_iterator.extension_constructor self constructor);
      package_type =
        (fun self package ->
          check_modules scope package.ppt_path.loc package.ppt_path.txt;
          Ast_iterator.default_iterator.package_type self package);
      with_constraint =
        (fun self constraint_ ->
          (match constraint_ with
          | Pwith_module (left, right) | Pwith_modsubst (left, right) ->
              check_modules scope left.loc left.txt;
              check_modules scope right.loc right.txt
          | Pwith_type _
          | Pwith_modtype _
          | Pwith_modtypesubst _
          | Pwith_typesubst _ -> ());
          Ast_iterator.default_iterator.with_constraint self constraint_);
      class_expr =
        (fun _ expression ->
          report expression.pcl_loc "class expression is forbidden");
      class_type =
        (fun _ signature -> report signature.pcty_loc "class type is forbidden");
    }
  in
  let self = iterator world in
  (match source with
  | Impl items -> self.structure self items
  | Intf items -> self.signature self items);
  List.rev !findings

let display finding =
  Printf.sprintf "%s:%d:%d: %s" finding.file finding.line finding.column
    finding.message

let file_error file message = { file; line = 1; column = 1; message }

let parse file =
  try
    In_channel.with_open_bin file (fun channel ->
        let lexer = Lexing.from_channel channel in
        Location.init lexer file;
        Ok
          (if Filename.check_suffix file ".mli" then
             Intf (Parse.interface lexer)
           else Impl (Parse.implementation lexer)))
  with
  | Sys_error message -> Error (file_error file message)
  | (Syntaxerr.Error _ | Lexer.Error _ | Location.Error _) as error ->
      Error
        (file_error file (Format.asprintf "%a" Location.report_exception error))

let rec files root =
  if List.mem (Filename.basename root) ignored then Ok []
  else
    try
      match (Unix.lstat root).Unix.st_kind with
      | Unix.S_DIR ->
          Array.to_list (Sys.readdir root)
          |> List.sort String.compare
          |> List.fold_left
               (fun result name ->
                 Result.bind result (fun previous ->
                     Result.map
                       (fun found -> previous @ found)
                       (files (Filename.concat root name))))
               (Ok [])
      | Unix.S_REG ->
          Ok
            (if
               Filename.check_suffix root ".ml"
               || Filename.check_suffix root ".mli"
             then [ root ]
             else [])
      | Unix.S_LNK ->
          Error
            [
              file_error root
                "source symlink is unsupported; pass its real source path";
            ]
      | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
          Error [ file_error root "unsupported source entry" ]
    with
    | Sys_error message -> Error [ file_error root message ]
    | Unix.Unix_error (error, operation, _) ->
        Error [ file_error root (operation ^ ": " ^ Unix.error_message error) ]

let scope_roots root =
  if Filename.basename root = "ocaml" then
    List.filter Sys.file_exists (List.map (Filename.concat root) directories)
  else [ root ]

let check roots =
  let roots = List.concat_map scope_roots roots in
  let found =
    List.fold_left
      (fun result root ->
        Result.bind result (fun previous ->
            Result.map (fun found -> previous @ found) (files root)))
      (Ok []) roots
  in
  Result.bind found (fun found ->
      let found = List.sort_uniq String.compare found in
      if found = [] then
        Error
          [
            file_error "check_source" "no application OCaml source files found";
          ]
      else
        let parsed, errors =
          List.fold_left
            (fun (parsed, errors) file ->
              match parse file with
              | Ok tree -> ((file, tree) :: parsed, errors)
              | Error error -> (parsed, error :: errors))
            ([], []) found
        in
        let world =
          List.fold_left
            (fun world (file, tree) ->
              match tree with
              | Impl _ -> world
              | Intf items ->
                  let name =
                    String.capitalize_ascii
                      (Filename.remove_extension (Filename.basename file))
                  in
                  bind world (Some name)
                    (Members (List.fold_left update_sig empty items).modules))
            empty parsed
        in
        let errors =
          List.fold_left
            (fun errors file ->
              if
                Filename.check_suffix file ".ml"
                && not
                     (Sys.file_exists (Filename.remove_extension file ^ ".mli"))
              then file_error file "missing sibling .mli" :: errors
              else errors)
            errors found
        in
        let errors =
          List.fold_left
            (fun errors (file, tree) ->
              List.rev_append (lint world file tree) errors)
            errors parsed
        in
        match errors with
        | [] -> Ok (List.length found)
        | errors -> Error (List.rev errors))

let write file text =
  Out_channel.with_open_bin file (fun channel -> output_string channel text)

let controls () =
  let examples =
    [
      ("missing-mli", Ml_only "let x = 1\n", Reject "missing sibling .mli");
      ( "object-alias",
        Paired ("module O = Obj\nlet f = O.magic\n", ""),
        Reject "forbidden module Obj" );
      ( "stdlib-alias",
        Paired ("module S = Stdlib\nmodule O = S.Obj\n", ""),
        Reject "forbidden module Obj" );
      ( "str-alias",
        Paired ("module R = Str\n", ""),
        Reject "forbidden module Str" );
      ( "lwt-type",
        Mli_only "val x : unit Lwt.t\n",
        Reject "forbidden module Lwt" );
      ( "async-exception",
        Paired ("exception E = Async.E\n", ""),
        Reject "forbidden module Async" );
      ( "functor-path",
        Mli_only "type t = F(Obj).t\n",
        Reject "forbidden module Obj" );
      ( "object",
        Paired ("let x = object method x = 1 end\n", ""),
        Reject "object/class syntax" );
      ("class", Paired ("class x = object end\n", ""), Reject "class expression");
      ( "object-type",
        Mli_only "val x : < value : int >\n",
        Reject "object/class type" );
      ( "partial-list",
        Paired ("let f = List.hd\n", ""),
        Reject "partial operation List.hd" );
      ( "partial-alias",
        Paired ("module L = List\nmodule A = L\nlet f = A.nth\n", ""),
        Reject "partial operation List.nth" );
      ( "local-option",
        Paired ("let f = let module O = Option in O.get\n", ""),
        Reject "partial operation Option.get" );
      ( "map-alias",
        Paired
          ( "module Make = Map.Make\n\
             module M = Make(String)\n\
             module N = M\n\
             let f = N.find\n",
            "" ),
        Reject "partial operation Map.find" );
      ( "map-parameter",
        Paired ("module F (M : Map.S) = struct let f = M.find end\n", ""),
        Reject "partial operation Map.find" );
      ( "local-open",
        Paired ("let f = List.(hd)\n", ""),
        Reject "partial operation List.hd" );
      ( "alias-capture",
        Paired
          ( "module L = List\n\
             module A = L\n\
             module L = struct let hd x = Some x end\n\
             let f = A.hd\n",
            "" ),
        Reject "partial operation List.hd" );
      ("parse-error", Paired ("let =\n", ""), Reject "Syntax error");
      ("empty-scan", No_files, Reject "no application OCaml source files");
      ("missing-root", Missing_root, Reject "lstat:");
      ( "pattern-path",
        Paired ("let f = function Lwt.E -> ()\n", ""),
        Reject "forbidden module Lwt" );
      ( "module-substitution",
        Mli_only "module X := Obj\n",
        Reject "forbidden module Obj" );
      ( "constrained-map",
        Paired
          ( "module M : Map.S with type key = string = struct include \
             Map.Make(String) end\n\
             let f = M.find\n",
            "" ),
        Reject "partial operation Map.find" );
      ( "empty-open",
        Paired
          ( "module L = List\n\
             module S = struct end\n\
             let f () = let module L = struct let hd x = Some x end in let \
             open S in L.hd 1\n",
            "" ),
        Accept );
      ( "shadowed-recursion",
        Paired
          ("open List\nlet rec hd n = if n = 0 then 0 else hd (n - 1)\n", ""),
        Accept );
      ( "shadowed-loop",
        Paired ("open List\nlet f () = for hd = 1 to 3 do ignore hd done\n", ""),
        Accept );
      ( "shadowed-letop",
        Paired
          ("open List\nlet ( let* ) x f = f x\nlet f = let* hd = 1 in hd\n", ""),
        Accept );
      ( "safe-options",
        Paired
          ( "module M = Map.Make(String)\n\
             let a = List.nth_opt\n\
             let b = List.assoc_opt\n\
             let c = M.find_opt\n\
             let d = List.(nth_opt)\n",
            "" ),
        Accept );
      ( "safe-find",
        Paired
          ("module M = struct let find x = Some x end\nlet f = M.find\n", ""),
        Accept );
      ( "shadowed-alias",
        Paired
          ( "module L = List\n\
             module L = struct let hd x = Some x end\n\
             let f = L.hd\n",
            "" ),
        Accept );
      ( "shadowed-open",
        Paired ("open List\nlet hd x = Some x\nlet f = hd\nlet g hd = hd\n", ""),
        Accept );
      ( "literal-text",
        Paired
          ( "(* Obj.magic; List.hd; class *)\n\
             let text = \"Lwt Str Async Option.get\"\n",
            "val text : string\n" ),
        Accept );
      ( "documented-defect",
        Paired
          ( "let f () = invalid_arg \"defect\"\n",
            "val f : unit -> unit\n\
             (** Raises Invalid_argument on a caller defect. *)\n" ),
        Accept );
      ("interface-only", Mli_only "module type S = sig type t end\n", Accept);
    ]
  in
  let failures = ref [] in
  let failed message =
    failures := message :: !failures;
    Printf.printf "FAIL %s\n" message
  in
  List.iter
    (fun (name, fixture, expectation) ->
      let root = Filename.temp_dir "symphony-source-gate-" "" in
      Fun.protect
        ~finally:(fun () ->
          Array.iter
            (fun file -> Sys.remove (Filename.concat root file))
            (Sys.readdir root);
          Unix.rmdir root)
        (fun () ->
          (match fixture with
          | Paired (implementation, interface) ->
              write (Filename.concat root "fixture.ml") implementation;
              write (Filename.concat root "fixture.mli") interface
          | Ml_only implementation ->
              write (Filename.concat root "fixture.ml") implementation
          | Mli_only interface ->
              write (Filename.concat root "fixture.mli") interface
          | No_files | Missing_root -> ());
          let scan =
            match fixture with
            | Missing_root -> Filename.concat root "missing"
            | Paired _ | Ml_only _ | Mli_only _ | No_files -> root
          in
          match (expectation, check [ scan ]) with
          | Accept, Ok _ -> Printf.printf "ok %s\n" name
          | Reject expected, Error errors ->
              let contains text =
                let rec loop offset =
                  if offset + String.length expected > String.length text then
                    false
                  else
                    String.sub text offset (String.length expected) = expected
                    || loop (offset + 1)
                in
                loop 0
              in
              if List.exists (fun error -> contains error.message) errors then
                Printf.printf "ok %s\n" name
              else
                failed
                  (name ^ " failed for the wrong reason:\n"
                  ^ String.concat "\n" (List.map display errors))
          | Accept, Error errors ->
              failed
                (name ^ " rejected:\n"
                ^ String.concat "\n" (List.map display errors))
          | Reject _, Ok _ -> failed (name ^ " escaped the source gate")))
    examples;
  if !failures <> [] then failwith (String.concat "\n" (List.rev !failures));
  Printf.printf "source gate controls: %d passed\n" (List.length examples)

let main () =
  let mode = ref Scan and roots = ref [] in
  Arg.parse
    [
      ( "--self-test",
        Arg.Unit (fun () -> mode := Self_test),
        " Run temporary positive/negative fixtures" );
      ( "--limitations",
        Arg.Unit (fun () -> mode := Limits),
        " Explain the syntax gate's limits" );
    ]
    (fun root -> roots := root :: !roots)
    "check_source [--self-test | --limitations] [ROOT ...]\n\
     Default: application sources under ocaml/{lib,bin,test,fuzz,tools}.";
  match !mode with
  | Self_test -> controls ()
  | Limits ->
      print_endline
        "Syntax checks explicit references and known aliases/containers/opens. \
         It does not prove totality, exception-freedom, external/dynamic \
         reexports, PPX expansion, primitive safety, or bounds/preconditions \
         of allowed calls. Interface contracts, warnings, review, model tests, \
         and fuzzing cover those obligations."
  | Scan -> (
      match check (if !roots = [] then [ "ocaml" ] else List.rev !roots) with
      | Ok count -> Printf.printf "source gate: %d source files checked\n" count
      | Error errors ->
          List.iter (fun error -> prerr_endline (display error)) errors;
          exit 1)

let () =
  Printexc.record_backtrace true;
  try main ()
  with error ->
    prerr_endline ("source gate defect: " ^ Printexc.to_string error);
    prerr_endline (Printexc.get_backtrace ());
    exit 2
