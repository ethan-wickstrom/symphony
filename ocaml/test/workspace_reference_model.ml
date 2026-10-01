type input = {
  root : string;
  after_create : string option;
  before_run : string option;
  after_run : string option;
  before_remove : string option;
  timeout_ms : string;
  environment : (string * string) list;
  scope : string;
  issue_id : string;
  identifier : string;
}

type t = { input : input; key : string }

let make input =
  Result.map
    (fun key -> { input; key })
    (Workspace_key_model.derive input.identifier)

let input reference = reference.input
let key reference = reference.key

let equal_input a b =
  let optional = Option.equal String.equal in
  let binding (name, value) (other_name, other_value) =
    String.equal name other_name && String.equal value other_value
  in
  String.equal a.root b.root
  && optional a.after_create b.after_create
  && optional a.before_run b.before_run
  && optional a.after_run b.after_run
  && optional a.before_remove b.before_remove
  && String.equal a.timeout_ms b.timeout_ms
  && List.equal binding a.environment b.environment
  && String.equal a.scope b.scope
  && String.equal a.issue_id b.issue_id
  && String.equal a.identifier b.identifier
