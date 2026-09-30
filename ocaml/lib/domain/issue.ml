type routing = Dispatchable | Unroutable

type blocker = {
  id : Issue_id.t option;
  identifier : Issue_identifier.t option;
  state : string option;
}

type input = {
  id : string;
  identifier : string;
  title : string;
  description : string option;
  priority : string option;
  state : string;
  branch_name : string option;
  url : string option;
  assignee_id : string option;
  labels : string list;
  blocked_by : blocker list;
  created_at : string option;
  updated_at : string option;
  dispatchable : routing;
  native_ref : Json.t option;
}

type t = {
  id : Issue_id.t;
  identifier : Issue_identifier.t;
  title : string;
  description : string option;
  priority : int option;
  state : string;
  branch_name : string option;
  url : string option;
  assignee_id : string option;
  labels : string list;
  blocked_by : blocker list;
  created_at : Utc.t option;
  updated_at : Utc.t option;
  dispatchable : routing;
  native_ref : Json.t option;
}

let ( let* ) = Result.bind

let render (t : t) =
  let make = Json.of_view in
  let str s = make (Json.String s) in
  let optional f = function
    | None -> make Json.Null
    | Some s -> f s
  in
  let rec sequence = function
    | [] -> Ok []
    | x :: xs ->
        let* x = x in
        let* xs = sequence xs in
        Ok (x :: xs)
  in
  let binding k r = Result.map (fun j -> (k, j)) r in
  let blocker (b : blocker) =
    let* xs =
      sequence
        [
          binding "id" (optional (fun id -> str (Issue_id.text id)) b.id);
          binding "identifier"
            (optional (fun id -> str (Issue_identifier.text id)) b.identifier);
          binding "state" (optional str b.state);
        ]
    in
    make (Json.Object xs)
  in
  let* labels = sequence (List.map str t.labels) in
  let* blockers = sequence (List.map blocker t.blocked_by) in
  let* fields =
    sequence
      [
        binding "id" (str (Issue_id.text t.id));
        binding "identifier" (str (Issue_identifier.text t.identifier));
        binding "title" (str t.title);
        binding "description" (optional str t.description);
        binding "priority"
          (optional (fun n -> make (Json.Number (string_of_int n))) t.priority);
        binding "state" (str t.state);
        binding "branch_name" (optional str t.branch_name);
        binding "url" (optional str t.url);
        binding "assignee_id" (optional str t.assignee_id);
        binding "labels" (make (Json.Array labels));
        binding "blocked_by" (make (Json.Array blockers));
        binding "created_at"
          (optional (fun u -> str (Utc.rfc3339 u)) t.created_at);
        binding "updated_at"
          (optional (fun u -> str (Utc.rfc3339 u)) t.updated_at);
        binding "dispatchable"
          (make (Json.Bool (t.dispatchable = Dispatchable)));
        binding "native_ref"
          (match t.native_ref with
          | Some j -> Ok j
          | None -> make Json.Null);
      ]
  in
  make (Json.Object fields)

let parse (i : input) =
  let required label s =
    if String.trim s = "" || String.contains s '\000' || not (Text.valid_utf8 s)
    then Error (label ^ " must be nonempty valid UTF-8 without NUL")
    else Ok s
  in
  let optional s =
    Option.bind s (fun s ->
        if Text.valid_utf8 s && not (String.contains s '\000') then Some s
        else None)
  in
  let* id = Issue_id.parse i.id in
  let* identifier = Issue_identifier.parse i.identifier in
  let* title = required "title" i.title in
  let* state = required "state" i.state in
  let labels =
    List.filter_map
      (fun s ->
        if (not (Text.valid_utf8 s)) || String.contains s '\000' then None
        else
          let s = Text.normalize s in
          if s = "" then None else Some s)
      i.labels
    |> List.sort_uniq String.compare
  in
  let timestamp s = Option.bind s (fun s -> Result.to_option (Utc.parse s)) in
  let priority = Option.bind i.priority int_of_string_opt in
  let native_ref =
    Option.bind i.native_ref (fun j ->
        match Json.view j with
        | Json.Object _ -> Some j
        | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          -> None)
  in
  let blocked_by =
    List.map
      (fun (b : blocker) -> { b with state = optional b.state })
      i.blocked_by
  in
  let t : t =
    {
      id;
      identifier;
      title;
      state;
      description = optional i.description;
      priority;
      branch_name = optional i.branch_name;
      url = optional i.url;
      assignee_id = optional i.assignee_id;
      labels;
      blocked_by;
      created_at = timestamp i.created_at;
      updated_at = timestamp i.updated_at;
      dispatchable = i.dispatchable;
      native_ref;
    }
  in
  (* OCaml cannot encode dependent JSON size. Check the derived boundary view once;
     immutable checked fields preserve it without retaining a second snapshot. *)
  let* _ = render t in
  Ok t

let id (t : t) = t.id
let identifier (t : t) = t.identifier
let title (t : t) = t.title
let state (t : t) = t.state
let state_key (t : t) = Text.normalize t.state
let labels (t : t) = t.labels
let priority (t : t) = t.priority
let created_at (t : t) = t.created_at
let routing (t : t) = t.dispatchable

let to_json t =
  match render t with
  | Ok j -> j
  | Error e -> invalid_arg ("Issue representation defect: " ^ e)

module type S = sig
  type nonrec t = t

  val id : t -> Issue_id.t
  val identifier : t -> Issue_identifier.t
  val state_key : t -> string
  val labels : t -> string list
  val priority : t -> int option
  val created_at : t -> Utc.t option
  val routing : t -> routing
  val to_json : t -> Json.t
end
